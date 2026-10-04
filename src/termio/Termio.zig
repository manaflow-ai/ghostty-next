//! Primary terminal IO ("termio") state. This maintains the terminal state,
//! pty, subprocess, etc. This is flexible enough to be used in environments
//! that don't have a pty and simply provides the input/output using raw
//! bytes.
pub const Termio = @This();

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const EnvMap = std.process.Environ.Map;
const posix = std.posix;
const termio = @import("../termio.zig");
const StreamHandler = @import("stream_handler.zig").StreamHandler;
const terminalpkg = @import("../terminal/main.zig");
const global = @import("../global.zig");
const xev = global.xev;
const renderer = @import("../renderer.zig");
const apprt = @import("../apprt.zig");
const internal_os = @import("../os/main.zig");
const windows = internal_os.windows;
const configpkg = @import("../config.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;
const compat_file = @import("../lib/compat/file.zig");

const log = std.log.scoped(.io_exec);

/// Mutex state argument for queueMessage.
pub const MutexState = enum { locked, unlocked };

/// Allocator
alloc: Allocator,

/// This is the implementation responsible for io.
backend: termio.Backend,

/// The derived configuration for this termio implementation.
config: DerivedConfig,

/// The terminal emulator internal state. This is the abstract "terminal"
/// that manages input, grid updating, etc. and is renderer-agnostic. It
/// just stores internal state about a grid.
terminal: terminalpkg.Terminal,

/// The shared render state
renderer_state: *renderer.State,

/// A handle to wake up the renderer. This hints to the renderer that
/// a repaint should happen.
renderer_wakeup: xev.Async,

/// The mailbox for notifying the renderer of things.
renderer_mailbox: *renderer.Thread.Mailbox,

/// The mailbox for communicating with the surface.
surface_mailbox: apprt.surface.Mailbox,

/// The cached size info
size: renderer.Size,

/// The mailbox implementation to use.
mailbox: termio.Mailbox,

/// The stream parser. This parses the stream of escape codes and so on
/// from the child process and calls callbacks in the stream handler.
terminal_stream: StreamHandler.Stream,

/// See termio.Options.suppress_terminal_responses.
suppress_terminal_responses: bool,

/// The grid the embedder locked with `setGrid`, or null while the grid
/// follows the view (`size.grid()`). Only a manual backend locks it.
/// Read and written under `renderer_state.mutex`.
grid_lock: ?GridLock = null,

/// A snapshot whose history is still arriving after its READY prefix
/// was restored (see `restoreSnapshot`). Only the output queue uses it.
snapshot_restore: ?SnapshotRestore = null,


/// Last time the cursor was reset. This is used to prevent message
/// flooding with cursor resets.
last_cursor_reset: ?std.Io.Timestamp = null,

/// State we have for thread enter. This may be null if we don't need
/// to keep track of any state or if its already been freed.
thread_enter_state: ?*ThreadEnterState = null,

/// A terminal grid set by the terminal core that owns the byte stream.
pub const GridLock = struct {
    cols: terminalpkg.size.CellCountInt,
    rows: terminalpkg.size.CellCountInt,

    /// The owner's grid generation. A lock with an older generation is
    /// refused, so a late grid change cannot undo a newer one.
    generation: u64,
};

/// The largest unfinished escape sequence a snapshot carries, both when a
/// manual backend encodes one and when it restores one.
pub const snapshot_continuation_max_bytes = 1024 * 1024;

/// The history of a restored snapshot that is still arriving.
const SnapshotRestore = struct {
    /// Positioned after the last complete record that was applied. Its
    /// source is set again for every call.
    decoder: terminalpkg.snapshot.Decoder,

    /// Bytes received after that record: the start of an incomplete one.
    pending: std.ArrayListUnmanaged(u8) = .empty,
};

/// The state we need to keep around only until we enter the IO
/// thread. Then we can throw it all away.
const ThreadEnterState = struct {
    arena: ArenaAllocator,

    /// Initial input to send to the subprocess after starting. This
    /// memory is freed once the subprocess start is attempted, even
    /// if it fails, because Exec only starts once.
    input: configpkg.io.RepeatableReadableIO,

    pub fn create(
        alloc: Allocator,
        config: *const configpkg.Config,
    ) !?*ThreadEnterState {
        // If we have no input then we have no thread enter state
        if (config.input.list.items.len == 0) return null;

        // Create our arena allocator
        var arena = ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        // Allocate our ThreadEnterState
        const ptr = try arena_alloc.create(ThreadEnterState);

        // Copy the input from the config
        const input = try config.input.cloneParsed(arena_alloc);

        // Return the initialized state
        ptr.* = .{
            .arena = arena,
            .input = input,
        };
        return ptr;
    }

    pub fn destroy(self: *ThreadEnterState) void {
        self.arena.deinit();
    }

    /// Prepare the inputs for use. Allocations happen on the arena.
    pub fn prepareInput(
        self: *ThreadEnterState,
    ) (Allocator.Error || error{InputNotFound})![]const Input {
        const alloc = self.arena.allocator();

        var inputs: std.ArrayList(Input) = try .initCapacity(
            alloc,
            self.input.list.items.len,
        );
        errdefer for (inputs.items) |item| item.deinit();

        for (self.input.list.items) |item| {
            inputs.appendAssumeCapacity(switch (item) {
                .raw => |v| .{ .string = v },
                .path => |path| file: {
                    const f = std.Io.Dir.cwd().openFile(
                        global.io(),
                        path,
                        .{},
                    ) catch |err| {
                        log.warn("failed to open input file={s} err={}", .{
                            path,
                            err,
                        });
                        return error.InputNotFound;
                    };

                    break :file .{ .file = f };
                },
            });
        }

        return inputs.items;
    }

    const Input = union(enum) {
        string: []const u8,
        file: std.Io.File,

        fn deinit(self: Input) void {
            switch (self) {
                .string => {},
                .file => |f| f.close(global.io()),
            }
        }
    };
};

/// The configuration for this IO that is derived from the main
/// configuration. This must be exported so that we don't need to
/// pass around Config pointers which makes memory management a pain.
pub const DerivedConfig = struct {
    arena: ArenaAllocator,

    palette: terminalpkg.color.Palette,
    image_storage_limit: usize,
    scrollback_limit_bytes: ?usize,
    scrollback_limit_lines: ?usize,
    cursor_style: terminalpkg.CursorStyle,
    cursor_blink: ?bool,
    cursor_color: ?configpkg.Config.TerminalColor,
    foreground: configpkg.Config.Color,
    background: configpkg.Config.Color,
    osc_color_report_format: configpkg.Config.OSCColorReportFormat,
    clipboard_write: configpkg.ClipboardAccess,
    clipboard_write_limit: usize,
    enquiry_response: []const u8,
    conditional_state: configpkg.ConditionalState,

    pub fn init(
        alloc_gpa: Allocator,
        config: *const configpkg.Config,
    ) !DerivedConfig {
        var arena = ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        const palette: terminalpkg.color.Palette = palette: {
            if (config.@"palette-generate") generate: {
                if (config.palette.mask.findFirstSet() == null) {
                    // If the user didn't set any values manually, then
                    // we're using the default palette and we don't need
                    // to apply the generation code to it.
                    break :generate;
                }

                break :palette terminalpkg.color.generate256Color(config.palette.value, config.palette.mask, config.background.toTerminalRGB(), config.foreground.toTerminalRGB(), config.@"palette-harmonious");
            }

            break :palette config.palette.value;
        };

        return .{
            .palette = palette,
            .image_storage_limit = config.@"image-storage-limit",
            .scrollback_limit_bytes = config.@"scrollback-limit-bytes".optional(),
            .scrollback_limit_lines = config.@"scrollback-limit-lines".optional(),
            .cursor_style = config.@"cursor-style",
            .cursor_blink = config.@"cursor-style-blink",
            .cursor_color = config.@"cursor-color",
            .foreground = config.foreground,
            .background = config.background,
            .osc_color_report_format = config.@"osc-color-report-format",
            .clipboard_write = config.@"clipboard-write",
            .clipboard_write_limit = config.@"clipboard-write-limit-bytes".value,
            .enquiry_response = try alloc.dupe(u8, config.@"enquiry-response"),
            .conditional_state = config._conditional_state,

            // This has to be last so that we copy AFTER the arena allocations
            // above happen (Zig assigns in order).
            .arena = arena,
        };
    }

    pub fn deinit(self: *DerivedConfig) void {
        self.arena.deinit();
    }
};

/// Initialize the termio state.
///
/// This will also start the child process if the termio is configured
/// to run a child process.
pub fn init(self: *Termio, alloc: Allocator, opts: termio.Options) !void {
    // The default terminal modes based on our config.
    const default_modes: terminalpkg.ModePacked = modes: {
        var modes: terminalpkg.ModePacked = .{};

        // Setup our initial grapheme cluster support if enabled. We use a
        // switch to ensure we get a compiler error if more cases are added.
        switch (opts.full_config.@"grapheme-width-method") {
            .unicode => modes.grapheme_cluster = true,
            .legacy => {},
        }

        // Set default cursor blink settings
        modes.cursor_blinking = opts.config.cursor_blink orelse true;

        break :modes modes;
    };

    // Create our terminal
    var term = try terminalpkg.Terminal.init(global.io(), alloc, opts: {
        const grid_size = opts.size.grid();
        break :opts .{
            .cols = grid_size.columns,
            .rows = grid_size.rows,
            .max_scrollback_bytes = opts.full_config.@"scrollback-limit-bytes".optional(),
            .max_scrollback_lines = opts.full_config.@"scrollback-limit-lines".optional(),
            .default_modes = default_modes,
            .default_cursor_style = opts.config.cursor_style,
            .default_cursor_blink = opts.config.cursor_blink,
            .colors = .{
                .background = .init(opts.config.background.toTerminalRGB()),
                .foreground = .init(opts.config.foreground.toTerminalRGB()),
                .cursor = cursor: {
                    const color = opts.config.cursor_color orelse break :cursor .unset;
                    const rgb = color.toTerminalRGB() orelse break :cursor .unset;
                    break :cursor .init(rgb);
                },
                .palette = .default,
            },
            .kitty_image_storage_limit = opts.config.image_storage_limit,
            .kitty_image_loading_limits = kittyLoadingLimits(opts.backend),
        };
    });
    errdefer term.deinit(alloc);

    // The default palette may be an allocator-owned copy, so it is set
    // once the terminal owns its memory and can release it on deinit.
    try term.colors.palette.changeDefault(alloc, opts.config.palette);

    // Setup our terminal size in pixels for certain requests.
    term.width_px = term.cols * opts.size.cell.width;
    term.height_px = term.rows * opts.size.cell.height;

    // Setup our backend.
    var backend = opts.backend;
    backend.initTerminal(&term);

    // Create our stream handler. This points to memory in self so it
    // isn't safe to use until self.* is set.
    const handler: StreamHandler = .{
        .alloc = alloc,
        .termio_mailbox = &self.mailbox,
        .surface_mailbox = opts.surface_mailbox,
        .renderer_state = opts.renderer_state,
        .renderer_wakeup = opts.renderer_wakeup,
        .renderer_mailbox = opts.renderer_mailbox,
        .size = &self.size,
        .terminal = &self.terminal,
        .osc_color_report_format = opts.config.osc_color_report_format,
        .clipboard_write = opts.config.clipboard_write,
        .clipboard_write_limit = opts.config.clipboard_write_limit,
        .enquiry_response = opts.config.enquiry_response,
        .suppress_terminal_responses = opts.suppress_terminal_responses,
        .pwd_raw_url = opts.backend == .manual,
    };

    const thread_enter_state = try ThreadEnterState.create(
        alloc,
        opts.full_config,
    );

    self.* = .{
        .alloc = alloc,
        .terminal = term,
        .config = opts.config,
        .renderer_state = opts.renderer_state,
        .renderer_wakeup = opts.renderer_wakeup,
        .renderer_mailbox = opts.renderer_mailbox,
        .surface_mailbox = opts.surface_mailbox,
        .size = opts.size,
        .backend = backend,
        .mailbox = opts.mailbox,
        .terminal_stream = .init(.{
            .allocator = alloc,
            .handler = handler,
            // A manual backend encodes snapshots, which carry the bytes
            // of an unfinished escape sequence.
            .continuation_max_bytes = if (opts.backend == .manual)
                snapshot_continuation_max_bytes
            else
                null,
        }),
        .suppress_terminal_responses = opts.suppress_terminal_responses,
        .thread_enter_state = thread_enter_state,
    };
}

pub fn deinit(self: *Termio) void {
    self.backend.deinit();
    self.terminal.deinit(self.alloc);
    self.config.deinit();
    self.mailbox.deinit(self.alloc);

    // Clear any StreamHandler state
    self.terminal_stream.deinit();

    self.abandonSnapshotRestore();

    // Clear any initial state if we have it
    if (self.thread_enter_state) |v| v.destroy();
}

pub fn threadEnter(
    self: *Termio,
    thread: *termio.Thread,
    data: *ThreadData,
) !void {
    // Always free our thread enter state when we're done.
    defer if (self.thread_enter_state) |v| {
        v.destroy();
        self.thread_enter_state = null;
    };

    // If we have thread enter state then we're going to validate
    // and set that all up now so that we can error before we actually
    // start the command and pty.
    const inputs: ?[]const ThreadEnterState.Input = if (self.thread_enter_state) |v|
        try v.prepareInput()
    else
        null;
    defer if (inputs) |items| {
        for (items) |input| input.deinit();
    };

    data.* = .{
        .alloc = self.alloc,
        .loop = &thread.loop,
        .renderer_state = self.renderer_state,
        .surface_mailbox = self.surface_mailbox,
        .mailbox = &self.mailbox,
        .backend = undefined, // Backend must replace this on threadEnter
    };

    // Setup our backend
    try self.backend.threadEnter(self.alloc, self, data);
    errdefer self.backend.threadExit(data);

    // If we have inputs, then queue them all up.
    for (inputs orelse &.{}) |input| switch (input) {
        .string => |v| self.queueWrite(data, v, false) catch |err| {
            log.warn("failed to queue input string err={}", .{err});
            return error.InputFailed;
        },
        .file => |f| {
            const contents = compat_file.readToEndAlloc(
                f,
                self.alloc,
                10 * 1024 * 1024, // 10 MiB max
            ) catch |err| {
                log.warn("failed to read input file err={}", .{err});
                return error.InputFailed;
            };
            defer self.alloc.free(contents);

            self.queueWrite(data, contents, false) catch |err| {
                log.warn("failed to queue input file err={}", .{err});
                return error.InputFailed;
            };
        },
    };
}

pub fn threadExit(self: *Termio, data: *ThreadData) void {
    self.backend.threadExit(data);
}

/// Send a message to the mailbox. Depending on the mailbox type in use
/// this may process now or it may just enqueue and process later.
///
/// This will also notify the mailbox thread to process the message. If
/// you're sending a lot of messages, it may be more efficient to use
/// the mailbox directly and then call notify separately.
pub fn queueMessage(
    self: *Termio,
    msg: termio.Message,
    mutex: MutexState,
) void {
    switch (self.backend) {
        .manual => if (self.queueMessageManual(msg, mutex)) return,
        .exec => {},
    }

    self.mailbox.send(msg, switch (mutex) {
        .locked => self.renderer_state.mutex,
        .unlocked => null,
    });
    self.mailbox.notify();
}

/// Handle a message for a manual backend on the calling thread. Returns
/// false if the message must go through the mailbox instead.
///
/// A manual backend has no PTY to service, so the termio thread adds
/// nothing for input: the embedder gets encoded writes, focus reports and
/// the clear screen form feed synchronously, in call order, on the thread that produced them. A
/// resize applies to the terminal before the call returns, so an embedder
/// that orders resizes and processOutput calls on one thread knows which
/// bytes were parsed at which grid size.
///
/// Handlers that take the renderer state lock themselves (focus, resize,
/// clear screen) only run inline when the caller does not hold it; otherwise the
/// message takes the normal mailbox path.
fn queueMessageManual(
    self: *Termio,
    msg: termio.Message,
    mutex: MutexState,
) bool {
    var td = self.manualThreadData();
    switch (msg) {
        .write_small => |v| self.queueWriteManual(&td, v.data[0..v.len], mutex),
        .write_stable => |v| self.queueWriteManual(&td, v, mutex),
        .write_alloc => |v| {
            defer v.alloc.free(v.data);
            self.queueWriteManual(&td, v.data, mutex);
        },
        .focused => |v| {
            if (mutex == .locked) return false;
            self.focusGained(&td, v) catch |err| {
                log.warn("manual focus report failed err={}", .{err});
            };
        },
        .resize => |v| {
            if (mutex == .locked) return false;
            self.resize(&td, v) catch |err| {
                log.warn("manual resize failed err={}", .{err});
            };
        },
        // At a prompt this writes a form feed, which must stay in order
        // with the user input around it.
        .clear_screen => |v| {
            if (mutex == .locked) return false;
            self.clearScreen(&td, v.history) catch |err| {
                log.warn("manual clear screen failed err={}", .{err});
            };
        },
        else => return false,
    }

    return true;
}

/// Thread data for work a manual backend does outside the termio thread.
/// The manual backend never reads the event loop.
fn manualThreadData(self: *Termio) ThreadData {
    return .{
        .alloc = self.alloc,
        .loop = undefined,
        .renderer_state = self.renderer_state,
        .surface_mailbox = self.surface_mailbox,
        .backend = .{ .manual = .{} },
        .mailbox = &self.mailbox,
    };
}

fn queueWriteManual(
    self: *Termio,
    td: *ThreadData,
    data: []const u8,
    mutex: MutexState,
) void {
    // The termio thread tracks linefeed mode (LNM) from mailbox messages.
    // Inline writes read it from the terminal, which the parser updates
    // under the renderer state lock.
    const linefeed = linefeed: {
        if (mutex == .unlocked) self.renderer_state.mutex.lockUncancelable(global.io());
        defer if (mutex == .unlocked) self.renderer_state.mutex.unlock(global.io());
        break :linefeed self.terminal.modes.get(.linefeed);
    };

    self.queueWrite(td, data, linefeed) catch |err| {
        log.warn("manual write failed err={}", .{err});
    };
}

/// Queue a write directly to the pty.
///
/// If you're using termio.Thread, this must ONLY be called from the
/// mailbox thread. If you're not on the thread, use queueMessage with
/// mailbox messages instead.
///
/// If you're not using termio.Thread, this is not threadsafe.
pub inline fn queueWrite(
    self: *Termio,
    td: *ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    try self.backend.queueWrite(self.alloc, td, data, linefeed);
}

/// Update the configuration.
pub fn changeConfig(self: *Termio, td: *ThreadData, config: *DerivedConfig) !void {
    // The remainder of this function is modifying terminal state or
    // the read thread data, all of which requires holding the renderer
    // state lock.
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());

    // Deinit our old config. We do this in the lock because the
    // stream handler may be referencing the old config (i.e. enquiry resp)
    self.config.deinit();
    self.config = config.*;

    // Update our stream handler. The stream handler uses the same
    // renderer mutex so this is safe to do despite being executed
    // from another thread.
    self.terminal_stream.handler.changeConfig(&self.config);
    td.backend.changeConfig(&self.config);

    // Update the configuration that we know about.
    //
    // Specific things we don't update:
    //   - command, working-directory: we never restart the underlying
    //   process so we don't care or need to know about these.

    // Update the default palette. A config change must not fail here, so
    // if we can't allocate the copy of the configured palette we fall back
    // to the built-in default, which never allocates.
    self.terminal.colors.palette.changeDefault(
        self.alloc,
        config.palette,
    ) catch |err| {
        log.warn("error changing default palette, using built-in default err={}", .{err});
        self.terminal.colors.palette.resetDefault(self.alloc);
    };
    self.terminal.flags.dirty.palette = true;

    // Update all our other colors
    self.terminal.colors.background.default = config.background.toTerminalRGB();
    self.terminal.colors.foreground.default = config.foreground.toTerminalRGB();
    self.terminal.colors.cursor.default = cursor: {
        const color = config.cursor_color orelse break :cursor null;
        break :cursor color.toTerminalRGB() orelse break :cursor null;
    };

    // Set the image limits
    self.terminal.setKittyGraphicsSizeLimit(self.alloc, config.image_storage_limit);
    self.terminal.setKittyGraphicsLoadingLimits(kittyLoadingLimits(self.backend));

    // A manual backend applies the scrollback limits at runtime too: its
    // terminal is replaced by every snapshot restore, which takes these
    // limits rather than the owner's, so a new limit must hold for the
    // live terminal as well. (Exec surfaces keep upstream behavior: the
    // limits apply to new surfaces only.)
    if (self.backend == .manual) {
        self.terminal.setScrollbackMaxBytes(config.scrollback_limit_bytes);
        self.terminal.setScrollbackMaxLines(config.scrollback_limit_lines);
    }
}

/// The Kitty graphics transmission mediums the terminal may load from.
/// The output of a manual backend comes from a terminal on another
/// machine, so a file name, temporary file or shared memory object in it
/// does not name anything on this machine. Loading it would read local
/// files, unlink temporary files and leak which paths exist. A manual
/// backend loads only in-band (direct) image data.
fn kittyLoadingLimits(
    backend: termio.backend.Kind,
) terminalpkg.kitty.graphics.LoadingImage.Limits {
    return switch (backend) {
        .exec => .allWithTempDir(global.tmpDirPath()),
        .manual => .direct,
    };
}

/// Resize the terminal.
///
/// With a grid lock (see `setGrid`) only the pixel size changes: the
/// terminal keeps the locked grid and the renderer pads or crops it.
pub fn resize(
    self: *Termio,
    td: *ThreadData,
    size: renderer.Size,
) !void {
    // Update the size of our pty. A manual backend has none.
    try self.backend.resize(size.grid(), size.terminal());

    // Enter the critical area that we want to keep small
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());

        // The stream handler and size reports read this under the lock,
        // and a manual backend resizes from the caller's thread.
        self.size = size;

        // Update the size of our terminal state
        const grid_size = self.gridSizeLocked();
        try self.terminal.resize(
            self.alloc,
            .{
                .cols = grid_size.columns,
                .rows = grid_size.rows,
                .cell_size_px = .{
                    .width = self.size.cell.width,
                    .height = self.size.cell.height,
                },
                .reflow = !self.suppress_terminal_responses,
            },
        );

        // If we have size reporting enabled we need to send a report.
        if (self.terminal.modes.get(.in_band_size_reports)) {
            try self.sizeReportLocked(td, .mode_2048);
        }
    }

    // Mail the renderer so that it can update the GPU and re-render
    _ = self.renderer_mailbox.push(global.io(), .{ .resize = size }, .{ .forever = {} });
    self.renderer_wakeup.notify() catch {};
}

/// The grid the terminal has: the locked grid, or what fits the view.
/// Caller must hold `renderer_state.mutex`.
fn gridSizeLocked(self: *const Termio) renderer.GridSize {
    if (self.grid_lock) |lock| return .{
        .columns = lock.cols,
        .rows = lock.rows,
    };
    return self.size.grid();
}

/// Lock the terminal grid to `cols` x `rows`, the grid of the terminal
/// core that owns the byte stream, independent of the view's pixel size.
/// Later resizes change only the pixel size. A mirror
/// (`suppress_terminal_responses`) never reflows: its owner reflows and
/// sends a snapshot. A manual (not mirror) terminal reflows like any
/// resize and sends the mode 2048 size report when it is enabled.
///
/// Returns false and changes nothing for an exec backend, a zero
/// dimension, a generation older than the current lock, or a failed
/// resize. The same grid with a newer generation only stores the
/// generation.
pub fn setGrid(
    self: *Termio,
    cols: terminalpkg.size.CellCountInt,
    rows: terminalpkg.size.CellCountInt,
    generation: u64,
) bool {
    if (self.backend != .manual) return false;
    if (cols == 0 or rows == 0) return false;

    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());

        if (self.grid_lock) |current| {
            if (generation < current.generation) return false;
        }

        if (self.terminal.cols != cols or self.terminal.rows != rows) {
            self.terminal.resize(self.alloc, .{
                .cols = cols,
                .rows = rows,
                .cell_size_px = .{
                    .width = self.size.cell.width,
                    .height = self.size.cell.height,
                },
                .reflow = !self.suppress_terminal_responses,
            }) catch |err| {
                log.warn("set grid failed err={}", .{err});
                return false;
            };
        }

        self.grid_lock = .{
            .cols = cols,
            .rows = rows,
            .generation = generation,
        };

        if (self.terminal.modes.get(.in_band_size_reports)) {
            var td = self.manualThreadData();
            self.sizeReportLocked(&td, .mode_2048) catch |err| {
                log.warn("set grid size report failed err={}", .{err});
            };
        }
    }

    self.renderer_wakeup.notify() catch {};
    return true;
}

/// The terminal's grid and its lock, read under the terminal lock.
pub const GridState = struct {
    /// True after a successful `setGrid`.
    locked: bool,
    cols: terminalpkg.size.CellCountInt,
    rows: terminalpkg.size.CellCountInt,

    /// The generation of the last accepted `setGrid`, 0 when unlocked.
    generation: u64,
};

pub fn gridState(self: *Termio) GridState {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    return .{
        .locked = self.grid_lock != null,
        .cols = self.terminal.cols,
        .rows = self.terminal.rows,
        .generation = if (self.grid_lock) |lock| lock.generation else 0,
    };
}

/// Replace the terminal state from a GHOSTSNP snapshot (upstream
/// libghostty-vt `snapshot`) that the terminal core owning the byte
/// stream encoded. Only a manual backend restores snapshots, on the
/// thread that calls `processOutput`.
///
/// `.ready` (and `.complete`): `bytes` start at the snapshot envelope and
/// hold at least the READY prefix. The prefix is decoded off the terminal
/// lock, then swapped in under it in one step: the renderer sees the old
/// terminal or the new one, never a mix. History bytes that follow READY
/// in the same buffer are applied like `.history`. A restore abandons the
/// history of an earlier snapshot that is still arriving.
///
/// `.history`: `bytes` continue the stream after READY, cut anywhere.
/// Complete history pages are prepended to their screens; an incomplete
/// record waits for the next call. FINISH ends the snapshot.
///
/// The restore writes nothing to the pty callback: the snapshot carries
/// no replies, and the unfinished sequence it carries (its continuation)
/// is replayed into the parser, which produces no actions for it.
///
/// The restored terminal keeps the snapshot's grid, modes and the
/// program's color overrides; a locked grid takes the snapshot's size and
/// keeps its generation. Local policy from this surface's config replaces
/// the owner's: the scrollback limits (`scrollback-limit-bytes`,
/// `scrollback-limit-lines`), so history beyond them is dropped from the
/// oldest end, the Kitty image storage limit, in-band (direct) image
/// loading only, the default palette (OSC 4 overrides stay), the default
/// background, foreground and cursor colors (OSC 10/11/12 overrides stay),
/// and the default cursor style and blink (a program's explicit DECSCUSR
/// stays until it selects the default again). While the cursor follows its
/// default, mode 12 (cursor blinking) follows the local default blink, and
/// every screen takes the local cursor style.
pub fn restoreSnapshot(
    self: *Termio,
    bytes: []const u8,
    phase: apprt.SurfaceSnapshotPhase,
) !void {
    if (self.backend != .manual) return error.NotManual;
    switch (phase) {
        .ready, .complete => {
            self.abandonSnapshotRestore();

            var reader: std.Io.Reader = .fixed(bytes);
            var decoder: terminalpkg.snapshot.Decoder = .init(&reader);
            var decoded = try decoder.ready(self.alloc, global.io(), .{
                .max_continuation_bytes = snapshot_continuation_max_bytes,
            });
            defer decoded.deinit(self.alloc);

            self.replaceTerminal(&decoded, &decoder);
            self.snapshot_restore = .{ .decoder = decoder };
            try self.applySnapshotHistory(bytes[reader.seek..]);
        },

        .history => {
            if (self.snapshot_restore == null) return error.NoSnapshotInProgress;
            try self.applySnapshotHistory(bytes);
        },
    }
}

/// Swap in a decoded terminal under the terminal lock.
fn replaceTerminal(
    self: *Termio,
    decoded: *terminalpkg.snapshot.Decoded,
    decoder: *terminalpkg.snapshot.Decoder,
) void {
    var new = decoded.toOwned();

    var old: terminalpkg.Terminal = undefined;
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());

        self.prepareRestoredTerminalLocked(&new);
        switch (decoder.state) {
            .history => |*history| {
                var it = history.generations.iterator();
                while (it.next()) |entry| {
                    entry.value.* = new.screens.generation(entry.key);
                }
            },
            else => {},
        }

        old = self.swapTerminalLocked(new, decoded.continuation);
    }

    // The old terminal is unreachable now; free it off the lock.
    old.deinit(self.alloc);
}

/// Prepare a terminal restored from the owner's snapshot to replace the
/// live one. Caller must hold `renderer_state.mutex`.
fn prepareRestoredTerminalLocked(self: *Termio, new: *terminalpkg.Terminal) void {
    // Local policy, from this surface's config (which the lock guards):
    // Kitty image limits, and the scrollback limits instead of the
    // owner's, so history that arrives later stops at the local limit
    // (the decoder drops a page that does not fit and every older page
    // after it). An alternate screen made later copies these from the
    // primary screen. Default colors and cursor style are this surface's
    // too, not the owner's.
    self.applyLocalPolicyLocked(new);

    // Every screen is new storage. Advance each generation past the old
    // terminal's, as a screen removal does, so references into the old
    // pages (selection gesture pins, search) are seen as stale. The
    // decoder applies history only to the generations it saw at READY,
    // so the caller updates those to the new values.
    const ScreenKey = @TypeOf(new.screens.active_key);
    for (std.enums.values(ScreenKey)) |key| {
        new.screens.generations.put(
            key,
            self.terminal.screens.generation(key) +% 1,
        );
    }
}

/// Make `new` the live terminal and return the old one, which the caller
/// frees after it releases the lock. Caller must hold
/// `renderer_state.mutex`.
fn swapTerminalLocked(
    self: *Termio,
    new: terminalpkg.Terminal,
    continuation: terminalpkg.snapshot.Continuation,
) terminalpkg.Terminal {
    const old = self.terminal;
    self.terminal = new;

    // The parser state belonged to the old byte stream. The snapshot's
    // continuation is the unfinished sequence of the new one; replaying it
    // also restarts continuation tracking.
    self.resetStreamLocked();
    switch (continuation) {
        .ground => {},
        .bytes => |bytes| self.terminal_stream.nextSlice(bytes),
    }

    if (self.grid_lock) |*lock| {
        lock.cols = self.terminal.cols;
        lock.rows = self.terminal.rows;
    }

    // A snapshot cut inside a synchronized update (mode 2026) holds frames
    // until the owner's output ends it. The parser starts the safety timer
    // when it sees the mode set; a restored mode needs the same timer, or a
    // lost end would stop drawing for good.
    if (self.terminal.modes.get(.synchronized_output)) {
        self.queueMessage(.{ .start_synchronized_output = {} }, .locked);
    }

    // Redraw everything, images included.
    self.terminal.flags.dirty.clear = true;
    if (comptime terminalpkg.options.kitty_graphics) {
        var it = self.terminal.screens.all.iterator();
        while (it.next()) |entry| entry.value.*.kitty_images.dirty = true;
    }
    self.terminal_stream.handler.queueRender() catch {};
    return old;
}

/// The result of `restoreSnapshotLocalHistory`.
pub const LocalHistoryResult = enum {
    /// The READY terminal with this surface's reflowed history.
    restored,

    /// The READY terminal without history: the local history did not
    /// match the owner's.
    mismatch,
};

/// Restore the READY prefix that the owner encoded directly after it
/// resized, and keep this surface's own primary history instead of
/// receiving the owner's: resize the old terminal to the snapshot's grid
/// the way the owner resized (Terminal.resize, which reflows the primary
/// screen), compare its history digest with the owner's
/// (`terminalpkg.history_digest.matches`: equal digests, and equal row
/// counts or a local history that its own smaller scrollback limit cut),
/// and on a match put the old primary history above the new primary
/// screen. The caller contract is in ghostty.h
/// (ghostty_surface_restore_snapshot_local_history).
///
/// `bytes` hold exactly the READY prefix; bytes after READY are an error.
/// Errors leave the terminal unchanged (an earlier snapshot whose history
/// is still arriving is abandoned). After a result the snapshot is
/// complete: a later `.history` restore fails with NoSnapshotInProgress.
pub fn restoreSnapshotLocalHistory(
    self: *Termio,
    bytes: []const u8,
    expected: terminalpkg.history_digest.Digest,
) !LocalHistoryResult {
    _ = bytes;
    _ = expected;
    if (self.backend != .manual) return error.NotManual;
    return error.Unimplemented; // red: not implemented
}

/// The history digest of the live terminal's primary screen
/// (`terminalpkg.history_digest`). Takes the terminal lock.
pub fn historyDigest(self: *Termio) !terminalpkg.history_digest.Digest {
    if (self.backend != .manual) return error.NotManual;
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    return terminalpkg.history_digest.terminal(&self.terminal);
}

/// Apply the surface's config as local policy to a terminal of a manual
/// backend restored from the owner's snapshot: Kitty image storage and
/// in-band loading, the scrollback byte and line limits, the default
/// palette and default background, foreground and cursor colors, and the
/// default cursor style and blink. Lowering a scrollback limit frees the
/// oldest complete history pages, never a page of the active area. The
/// program's state stays: palette entries it set (the palette mask),
/// OSC 10/11/12 overrides, and an explicit DECSCUSR shape. Caller must
/// hold `renderer_state.mutex` when `t` is the live terminal.
fn applyLocalPolicyLocked(self: *Termio, t: *terminalpkg.Terminal) void {
    t.setKittyGraphicsSizeLimit(self.alloc, self.config.image_storage_limit);
    t.setKittyGraphicsLoadingLimits(kittyLoadingLimits(self.backend));
    t.setScrollbackMaxBytes(self.config.scrollback_limit_bytes);
    t.setScrollbackMaxLines(self.config.scrollback_limit_lines);

    // Colors, as changeConfig applies them. A restore must not fail
    // here, so an allocation failure falls back to the built-in palette.
    t.colors.palette.changeDefault(self.alloc, self.config.palette) catch |err| {
        log.warn("error applying the default palette after a snapshot restore, using built-in default err={}", .{err});
        t.colors.palette.resetDefault(self.alloc);
    };
    t.flags.dirty.palette = true;
    t.colors.background.default = self.config.background.toTerminalRGB();
    t.colors.foreground.default = self.config.foreground.toTerminalRGB();
    t.colors.cursor.default = cursor: {
        const color = self.config.cursor_color orelse break :cursor null;
        break :cursor color.toTerminalRGB() orelse break :cursor null;
    };

    // Cursor defaults, as the stream handler's changeConfig applies them:
    // a cursor that follows its default takes this surface's style, and
    // mode 12 (cursor blinking) takes this surface's default blink.
    t.setDefaultCursorStyle(self.config.cursor_style);
    t.setDefaultCursorBlink(self.config.cursor_blink);

    // setCursorStyle changes only the active screen. A snapshot taken on
    // the alternate screen keeps the owner's shape on the primary one,
    // and leaving the alternate screen (DECRC) does not restore the
    // shape, so a cursor that follows its default takes the local shape
    // on every screen.
    if (t.cursor.is_default) {
        var it = t.screens.all.iterator();
        while (it.next()) |entry| entry.value.*.cursor.cursor_style = t.cursor.default_style;
    }
}

/// Return the parser to ground and drop unfinished sequence state.
/// Caller must hold `renderer_state.mutex`.
fn resetStreamLocked(self: *Termio) void {
    const stream = &self.terminal_stream;
    const osc_alloc = stream.parser.osc_parser.alloc;
    const osc_unknown_max_bytes = stream.parser.osc_parser.unknown_max_bytes;
    stream.parser.deinit();
    stream.parser = .init();
    stream.parser.osc_parser.alloc = osc_alloc;
    stream.parser.osc_parser.unknown_max_bytes = osc_unknown_max_bytes;
    stream.utf8decoder = .{};
    if (stream.continuation) |*tracker| tracker.reset();
    stream.handler.resetSequenceState();
}

/// Apply the complete history records in `bytes` (after any pending
/// bytes) and keep the start of an incomplete record for the next call.
fn applySnapshotHistory(self: *Termio, bytes: []const u8) !void {
    const restore: *SnapshotRestore = if (self.snapshot_restore) |*v| v else return;
    errdefer self.abandonSnapshotRestore();

    try restore.pending.appendSlice(self.alloc, bytes);
    var reader: std.Io.Reader = .fixed(restore.pending.items);
    restore.decoder.source = &reader;

    var applied = false;
    defer if (applied) self.renderer_wakeup.notify() catch {};

    while (true) {
        // A truncated record fails with EndOfStream before it changes
        // the terminal (a page is decoded into its own allocation and
        // joined only when complete), so rewinding the decoder and the
        // reader to this point is exact.
        const saved = restore.decoder;
        const start = reader.seek;

        // The bytes come from another machine: refuse a record that
        // claims more than any history record holds, and tell a record
        // that is still arriving from one that is malformed (below).
        const complete_records = try completeSnapshotRecords(
            restore.pending.items[start..],
        );

        const progress = progress: {
            self.renderer_state.mutex.lockUncancelable(global.io());
            defer self.renderer_state.mutex.unlock(global.io());
            break :progress restore.decoder.next(self.alloc, &self.terminal);
        } catch |err| switch (err) {
            error.EndOfStream => {
                // One step reads at most two HISTORY manifests and a
                // PAGE or FINISH record. With that many complete records
                // buffered, running out of bytes means a record's
                // payload is shorter than its contents: malformed.
                if (complete_records >= max_records_per_history_step) {
                    return error.MalformedSnapshot;
                }
                restore.decoder = saved;
                reader.seek = start;
                break;
            },
            else => return err,
        };

        // FINISH: the snapshot is complete.
        const page = progress orelse {
            self.abandonSnapshotRestore();
            return;
        };
        if (page.rows > 0) applied = true;
    }

    // Keep only the incomplete record.
    const consumed = reader.seek;
    const rest = restore.pending.items.len - consumed;
    @memmove(
        restore.pending.items[0..rest],
        restore.pending.items[consumed..],
    );
    restore.pending.shrinkRetainingCapacity(rest);
}

/// The most records one `Decoder.next` call reads: the HISTORY manifests
/// of both screens (when the first has no pages) and one PAGE or FINISH.
const max_records_per_history_step = 3;

/// The largest snapshot record payload a restore accepts. PAGE records
/// are the largest (one terminal page); this bounds the bytes a restore
/// buffers for an incomplete record.
const max_snapshot_record_payload = 64 * 1024 * 1024;

/// Count the complete records at the start of `bytes`, up to
/// `max_records_per_history_step`, from their headers (u16 tag, u32
/// payload length, u32 CRC32C, little-endian). Fails for a payload length
/// over `max_snapshot_record_payload`.
fn completeSnapshotRecords(bytes: []const u8) error{SnapshotRecordTooLarge}!usize {
    const header_len = 10;
    var rest = bytes;
    var count: usize = 0;
    while (count < max_records_per_history_step and rest.len >= header_len) {
        const payload_len = std.mem.readInt(u32, rest[2..6], .little);
        if (payload_len > max_snapshot_record_payload) return error.SnapshotRecordTooLarge;
        const record_len = header_len + @as(usize, payload_len);
        if (rest.len < record_len) break;
        rest = rest[record_len..];
        count += 1;
    }
    return count;
}

/// Forget a snapshot whose history is still arriving.
fn abandonSnapshotRestore(self: *Termio) void {
    var restore = self.snapshot_restore orelse return;
    restore.pending.deinit(self.alloc);
    self.snapshot_restore = null;
}

/// Encode the terminal as a GHOSTSNP snapshot (upstream libghostty-vt
/// `snapshot`) into `writer`: the READY prefix, the history after it, or
/// both (`.complete`, the same bytes as `snapshot.encode`). Only a manual
/// backend encodes snapshots, on the thread that calls `processOutput`,
/// so the encoding matches the bytes parsed so far. Holds the terminal
/// lock for the whole encoding.
pub fn encodeSnapshot(
    self: *Termio,
    writer: *std.Io.Writer,
    phase: apprt.SurfaceSnapshotPhase,
) !void {
    if (self.backend != .manual) return error.NotManual;
    const snapshot = terminalpkg.snapshot;

    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());

    // The unfinished escape sequence at the end of the parsed output.
    var continuation_bytes: std.Io.Writer.Allocating = .init(self.alloc);
    defer continuation_bytes.deinit();
    self.terminal_stream.writeContinuation(&continuation_bytes.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    const continuation: snapshot.Continuation = if (continuation_bytes.written().len == 0)
        .ground
    else
        .{ .bytes = continuation_bytes.written() };

    const t = &self.terminal;
    var stream: snapshot.record.Writer = .init(self.alloc, writer);
    defer stream.deinit();

    if (phase != .history) {
        try snapshot.continuation.validate(continuation);
        try snapshot.envelope.encode(stream.writer());
        try snapshot.terminal.encode(t, &stream);
        try snapshot.screen.encode(t.screens.get(.primary).?, .primary, &stream);
        if (t.screens.get(.alternate)) |alternate| {
            try snapshot.screen.encode(alternate, .alternate, &stream);
        }
        try snapshot.continuation.encode(continuation, &stream);
        try snapshot.checkpoint.encode(.ready, &stream);
    }

    if (phase != .ready) {
        try snapshot.history.encode(t.screens.get(.primary).?, .primary, &stream);
        if (t.screens.get(.alternate)) |alternate| {
            try snapshot.history.encode(alternate, .alternate, &stream);
        }
        try snapshot.checkpoint.encode(.finish, &stream);
    }
}

/// Make a size report.
pub fn sizeReport(self: *Termio, td: *ThreadData, style: termio.Message.SizeReport) !void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    try self.sizeReportLocked(td, style);
}

fn sizeReportLocked(self: *Termio, td: *ThreadData, style: termio.Message.SizeReport) !void {
    if (self.suppress_terminal_responses) return;
    const grid_size = self.gridSizeLocked();
    const report_size: terminalpkg.size_report.Size = .{
        .rows = grid_size.rows,
        .columns = grid_size.columns,
        .cell_width = self.size.cell.width,
        .cell_height = self.size.cell.height,
    };

    // 1024 bytes should be enough for size report since report
    // in columns and pixels.
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try terminalpkg.size_report.encode(
        &writer,
        style,
        report_size,
    );

    try self.queueWrite(td, writer.buffered(), false);
}

/// Reset the synchronized output mode. This is usually called by timer
/// expiration from the termio thread.
pub fn resetSynchronizedOutput(self: *Termio) void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    self.terminal.modes.set(.synchronized_output, false);
    self.renderer_wakeup.notify() catch {};
}

/// Clear the screen.
pub fn clearScreen(self: *Termio, td: *ThreadData, history: bool) !void {
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());

        // If we're on the alternate screen, we do not clear. Since this is an
        // emulator-level screen clear, this messes up the running programs
        // knowledge of where the cursor is and causes rendering issues. So,
        // for alt screen, we do nothing.
        if (self.terminal.screens.active_key == .alternate) return;

        // Clear our selection
        self.terminal.screens.active.clearSelection();

        // Clear our scrollback
        if (history) self.terminal.eraseDisplay(.scrollback, false);

        // If we're not at a prompt, we just delete above the cursor.
        if (!self.terminal.cursorIsAtPrompt()) {
            if (self.terminal.screens.active.cursor.y > 0) {
                self.terminal.screens.active.eraseActive(
                    self.terminal.screens.active.cursor.y - 1,
                );
            }

            // Clear all Kitty graphics state for this screen. This copies
            // Kitty's behavior when Cmd+K deletes all Kitty graphics. I
            // didn't spend time researching whether it only deletes Kitty
            // graphics that are placed above the cursor or if it deletes
            // all of them. We delete all of them for now but if this behavior
            // isn't fully correct we should fix this later.
            self.terminal.screens.active.kitty_images.delete(
                self.terminal.io(),
                self.terminal.screens.active.alloc,
                &self.terminal,
                .{ .all = true },
            );

            return;
        }

        // At a prompt, we want to first fully clear the screen, and then after
        // send a FF (0x0C) to the shell so that it can repaint the screen.
        // Mark the current row as a not a prompt so we can properly
        // clear the full screen in the next eraseDisplay call.
        // TODO: fix this
        // self.terminal.markSemanticPrompt(.command);
        // assert(!self.terminal.cursorIsAtPrompt());
        self.terminal.eraseDisplay(.complete, false);
    }

    // If we reached here it means we're at a prompt, so we send a form-feed.
    try self.queueWrite(td, &[_]u8{0x0C}, false);
}

/// Scroll the viewport
pub fn scrollViewport(
    self: *Termio,
    scroll: terminalpkg.Terminal.ScrollViewport,
) void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    self.terminal.scrollViewport(scroll);
}

/// Jump the viewport to the prompt.
pub fn jumpToPrompt(self: *Termio, delta: isize) !void {
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        self.terminal.screens.active.scroll(.{ .delta_prompt = delta });
    }

    try self.renderer_wakeup.notify();
}

/// Called when focus is gained or lost (when focus events are enabled)
pub fn focusGained(self: *Termio, td: *ThreadData, focused: bool) !void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    const focus_event = self.renderer_state.terminal.modes.get(.focus_event);
    self.renderer_state.mutex.unlock(global.io());

    // If we have focus events enabled, we send the focus event.
    if (focus_event) {
        var buf: [terminalpkg.focus.max_encode_size]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        terminalpkg.focus.encode(&writer, if (focused) .gained else .lost) catch |err| {
            log.err("error encoding focus event err={}", .{err});
            return;
        };
        try self.queueWrite(td, writer.buffered(), false);
    }

    // We always notify our backend of focus changes.
    try self.backend.focusGained(td, focused);
}

/// Process output from the pty. This is the manual API that users can
/// call with pty data but it is also called by the read thread when using
/// an exec subprocess.
pub fn processOutput(self: *Termio, buf: []const u8) void {
    // We are modifying terminal state from here on out and we need
    // the lock to grab our read data.
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    self.processOutputLocked(buf);
}

/// Process output from readdata but the lock is already held.
fn processOutputLocked(self: *Termio, buf: []const u8) void {
    // Schedule a render. We can call this first because we have the lock.
    self.terminal_stream.handler.queueRender() catch unreachable;

    // Whenever a character is typed, we ensure the cursor is in the
    // non-blink state so it is rendered if visible. If we're under
    // HEAVY read load, we don't want to send a ton of these so we
    // use a timer under the covers
    const now = std.Io.Timestamp.now(global.io(), .awake);
    cursor_reset: {
        if (self.last_cursor_reset) |last| {
            if (last.durationTo(now).toMilliseconds() <= 500) {
                break :cursor_reset;
            }
        }

        self.last_cursor_reset = now;
        _ = self.renderer_mailbox.push(global.io(), .{
            .reset_cursor_blink = {},
        }, .{ .instant = {} });
    }

    // If we have an inspector, we enter SLOW MODE because we need to
    // process a byte at a time alternating between the inspector handler
    // and the termio handler. This is very slow compared to our optimizations
    // below but at least users only pay for it if they're using the inspector.
    if (self.renderer_state.inspector) |insp| {
        for (buf, 0..) |byte, i| {
            insp.recordPtyRead(
                self.alloc,
                &self.terminal,
                buf[i .. i + 1],
            ) catch |err| {
                log.err("error recording pty read in inspector err={}", .{err});
            };

            self.terminal_stream.next(byte);
        }
    } else {
        self.terminal_stream.nextSlice(buf);
    }

    // If our stream handling caused messages to be sent to the mailbox
    // thread, then we need to wake it up so that it processes them.
    if (self.terminal_stream.handler.termio_messaged) {
        self.terminal_stream.handler.termio_messaged = false;
        self.mailbox.notify();
    }
}

/// Sends a DSR response for the current color scheme to the pty.
/// Record a Kitty clipboard protocol session grant so future requests
/// carrying the password skip the permission prompt.
pub fn kittyClipboardGrant(
    self: *Termio,
    pw: []const u8,
    dir: terminalpkg.kitty.clipboard.Grants.Direction,
) error{OutOfMemory}!void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());

    try self.terminal_stream.handler.kittyClipboardGrant(pw, dir);
}

pub fn colorSchemeReport(self: *Termio, td: *ThreadData, force: bool) !void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());

    try self.colorSchemeReportLocked(td, force);
}

pub fn colorSchemeReportLocked(self: *Termio, td: *ThreadData, force: bool) !void {
    if (self.suppress_terminal_responses) return;
    if (!force and !self.renderer_state.terminal.modes.get(.report_color_scheme)) {
        return;
    }
    const scheme: terminalpkg.device_status.ColorScheme = switch (self.config.conditional_state.theme) {
        .light => .light,
        .dark => .dark,
    };

    var buf: [terminalpkg.device_status.max_color_scheme_report_encode_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try terminalpkg.device_status.encodeColorSchemeReport(&writer, scheme);
    try self.queueWrite(td, writer.buffered(), false);
}

/// Sends a visibility report to the pty. Unforced reports are only sent while
/// DEC mode 2033 is enabled.
pub fn visibilityReport(
    self: *Termio,
    td: *ThreadData,
    visible: bool,
    force: bool,
) !void {
    if (self.suppress_terminal_responses) return;

    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());

    if (!force and !self.renderer_state.terminal.modes.get(.report_visibility)) {
        return;
    }

    var buf: [terminalpkg.device_status.max_visibility_report_encode_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try terminalpkg.device_status.encodeVisibilityReport(
        &writer,
        if (visible) .potentially_visible else .not_visible,
    );
    try self.queueWrite(td, writer.buffered(), false);
}

/// ThreadData is the data created and stored in the termio thread
/// when the thread is started and destroyed when the thread is
/// stopped.
///
/// All of the fields in this struct should only be read/written by
/// the termio thread. As such, a lock is not necessary.
pub const ThreadData = struct {
    /// Allocator used for the event data
    alloc: Allocator,

    /// The event loop associated with this thread. This is owned by
    /// the Thread but we have a pointer so we can queue new work to it.
    loop: *xev.Loop,

    /// The shared render state
    renderer_state: *renderer.State,

    /// Mailboxes for different threads
    surface_mailbox: apprt.surface.Mailbox,

    /// Data associated with the backend implementation (i.e. pty/exec state)
    backend: termio.backend.ThreadData,
    mailbox: *termio.Mailbox,

    pub fn deinit(self: *ThreadData) void {
        self.backend.deinit(self.alloc);
        self.* = undefined;
    }
};

/// Get information about the process(es) attached to the backend. Returns
/// `null` if there was an error getting the information or the information is
/// not available on a particular platform.
pub fn getProcessInfo(self: *Termio, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    return self.backend.getProcessInfo(info);
}

/// Collects io_write_cb bytes for the manual backend tests.
const TestSink = struct {
    out: std.ArrayList(u8) = .empty,

    fn cb(ud: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) void {
        const self: *TestSink = @ptrCast(@alignCast(ud.?));
        self.out.appendSlice(std.testing.allocator, ptr[0..len]) catch
            @panic("OOM");
    }

    /// Check the bytes written since the last check, then forget them.
    /// (Clearing the list invalidates its old contents, so the check
    /// happens first.)
    fn expect(self: *TestSink, expected: []const u8) !void {
        defer self.out.clearRetainingCapacity();
        try std.testing.expectEqualStrings(expected, self.out.items);
    }
};

/// Pop and free every message queued for the termio thread.
fn testDrainMailbox(mailbox: *termio.Mailbox) usize {
    var n: usize = 0;
    while (mailbox.spsc.queue.pop(global.io())) |msg| {
        msg.deinit();
        n += 1;
    }
    return n;
}

/// Run `body` against a Termio with a manual backend. The surface
/// mailbox is not set up: nothing in these tests sends to it.
fn testManualTermio(
    mirror: bool,
    comptime body: anytype,
) !void {
    const testing = std.testing;
    const alloc = testing.allocator;

    var config: configpkg.Config = try .default(alloc);
    defer config.deinit();

    var sink: TestSink = .{};
    defer sink.out.deinit(alloc);

    var mutex: std.Io.Mutex = .init;
    var renderer_state: renderer.State = .{ .mutex = &mutex, .terminal = undefined };
    const renderer_mailbox = try renderer.Thread.Mailbox.create(alloc);
    defer renderer_mailbox.destroy(alloc);
    var renderer_wakeup = try xev.Async.init();
    defer renderer_wakeup.deinit();

    var io: Termio = undefined;
    try Termio.init(&io, alloc, .{
        .size = .{
            .screen = .{ .width = 800, .height = 480 },
            .cell = .{ .width = 10, .height = 20 },
            .padding = .{},
        },
        .full_config = &config,
        .config = try .init(alloc, &config),
        .backend = .{ .manual = try termio.Manual.init(alloc, .{
            .write_cb = TestSink.cb,
            .write_userdata = &sink,
            .mirror = mirror,
        }) },
        .suppress_terminal_responses = mirror,
        .mailbox = try termio.Mailbox.initSPSC(alloc),
        .renderer_state = &renderer_state,
        .renderer_wakeup = renderer_wakeup,
        .renderer_mailbox = renderer_mailbox,
        .surface_mailbox = undefined,
    });
    defer io.deinit();
    renderer_state.terminal = &io.terminal;

    try body(&io, &sink, mirror);
    while (renderer_mailbox.pop(global.io())) |_| {}
}

test "manual: queueMessage delivers input on the calling thread" {
    const body = struct {
        fn run(io: *Termio, sink: *TestSink, _: bool) !void {
            const testing = std.testing;
            const alloc = testing.allocator;

            io.queueMessage(.{ .write_stable = "a" }, .unlocked);
            try sink.expect("a");

            // A caller that holds the renderer state lock.
            {
                io.renderer_state.mutex.lockUncancelable(global.io());
                defer io.renderer_state.mutex.unlock(global.io());
                io.queueMessage(try termio.Message.writeReq(alloc, @as([]const u8, "b")), .locked);
            }
            try sink.expect("b");

            // An allocated write is delivered and freed (the testing
            // allocator checks for leaks).
            const long: []const u8 = "0123456789" ** 8;
            io.queueMessage(try termio.Message.writeReq(alloc, long), .unlocked);
            try sink.expect(long);

            // Linefeed mode (LNM) from the output applies to input.
            io.terminal.modes.set(.linefeed, true);
            io.queueMessage(.{ .write_stable = "\r" }, .unlocked);
            try sink.expect("\r\n");
            io.terminal.modes.set(.linefeed, false);

            // Nothing went through the termio thread.
            try testing.expectEqual(@as(usize, 0), testDrainMailbox(&io.mailbox));
        }
    }.run;

    try testManualTermio(false, body);
    try testManualTermio(true, body);
}

test "manual: focus reports follow mode 1004" {
    const body = struct {
        fn run(io: *Termio, sink: *TestSink, _: bool) !void {
            const testing = std.testing;

            io.queueMessage(.{ .focused = true }, .unlocked);
            try sink.expect("");

            io.terminal.modes.set(.focus_event, true);
            io.queueMessage(.{ .focused = true }, .unlocked);
            try sink.expect("\x1b[I");
            io.queueMessage(.{ .focused = false }, .unlocked);
            try sink.expect("\x1b[O");

            // With the lock held the focus report takes the mailbox.
            {
                io.renderer_state.mutex.lockUncancelable(global.io());
                defer io.renderer_state.mutex.unlock(global.io());
                io.queueMessage(.{ .focused = true }, .locked);
            }
            try sink.expect("");
            try testing.expectEqual(@as(usize, 1), testDrainMailbox(&io.mailbox));
        }
    }.run;

    // User focus reports are input, so a mirror sends them too.
    try testManualTermio(false, body);
    try testManualTermio(true, body);
}

test "manual: resize applies before queueMessage returns" {
    const body = struct {
        fn run(io: *Termio, sink: *TestSink, mirror: bool) !void {
            const testing = std.testing;

            try testing.expectEqual(@as(usize, 80), io.terminal.cols);
            io.terminal.modes.set(.in_band_size_reports, true);
            io.queueMessage(.{ .resize = .{
                .screen = .{ .width = 400, .height = 480 },
                .cell = .{ .width = 10, .height = 20 },
                .padding = .{},
            } }, .unlocked);
            try testing.expectEqual(@as(usize, 40), io.terminal.cols);

            // The mode 2048 size report is a report: only MANUAL sends it.
            if (mirror) {
                try sink.expect("");
            } else {
                try sink.expect("\x1b[48;24;40;480;400t");
            }
            try testing.expectEqual(@as(usize, 0), testDrainMailbox(&io.mailbox));
        }
    }.run;

    try testManualTermio(false, body);
    try testManualTermio(true, body);
}

test "manual: set_grid locks the grid and resizes change only pixels" {
    const body = struct {
        fn run(io: *Termio, sink: *TestSink, mirror: bool) !void {
            const testing = std.testing;

            try testing.expect(!io.gridState().locked);
            try testing.expect(io.setGrid(20, 5, 7));
            try testing.expectEqual(GridState{
                .locked = true,
                .cols = 20,
                .rows = 5,
                .generation = 7,
            }, io.gridState());

            // A view resize keeps the locked grid and stores the pixels.
            io.queueMessage(.{ .resize = .{
                .screen = .{ .width = 400, .height = 480 },
                .cell = .{ .width = 10, .height = 20 },
                .padding = .{},
            } }, .unlocked);
            try testing.expectEqual(@as(usize, 20), io.terminal.cols);
            try testing.expectEqual(@as(usize, 5), io.terminal.rows);
            try testing.expectEqual(@as(u32, 400), io.size.screen.width);

            // Older generations and zero sizes are refused.
            try testing.expect(!io.setGrid(30, 6, 6));
            try testing.expect(!io.setGrid(0, 6, 8));
            try testing.expectEqual(@as(usize, 20), io.terminal.cols);
            try testing.expectEqual(@as(u64, 7), io.gridState().generation);

            // A newer generation with the same grid stores the generation.
            try testing.expect(io.setGrid(20, 5, 8));
            try testing.expectEqual(@as(u64, 8), io.gridState().generation);

            // The mode 2048 size report follows the grid: MANUAL only.
            io.terminal.modes.set(.in_band_size_reports, true);
            try testing.expect(io.setGrid(30, 6, 9));
            if (mirror) {
                try sink.expect("");
            } else {
                try sink.expect("\x1b[48;6;30;120;300t");
            }
            try testing.expectEqual(@as(usize, 0), testDrainMailbox(&io.mailbox));
        }
    }.run;

    try testManualTermio(false, body);
    try testManualTermio(true, body);
}

test "manual: a mirror never reflows" {
    const body = struct {
        fn run(io: *Termio, _: *TestSink, mirror: bool) !void {
            const testing = std.testing;
            const alloc = testing.allocator;

            try testing.expect(io.setGrid(10, 3, 1));
            io.processOutput("0123456789AB");
            try testing.expect(io.setGrid(5, 3, 2));

            const str = try io.terminal.plainString(alloc);
            defer alloc.free(str);
            // MANUAL reflows the soft-wrapped line; a mirror clips it and
            // waits for the owner's snapshot.
            try testing.expectEqual(!mirror, std.mem.indexOf(u8, str, "56789") != null);
            try testing.expect(std.mem.startsWith(u8, str, "01234"));
        }
    }.run;

    try testManualTermio(false, body);
    try testManualTermio(true, body);
}

test "manual: the shell is not assumed to redraw the prompt" {
    const body = struct {
        fn run(io: *Termio, _: *TestSink, _: bool) !void {
            const testing = std.testing;

            // Both MANUAL and MANUAL_MIRROR match libghostty-vt's C API
            // default. EXEC surfaces keep Terminal's default of true.
            try testing.expectEqual(.false, io.terminal.flags.shell_redraws_prompt);

            // A shell can still opt in, as it can with libghostty-vt.
            io.processOutput("\x1b]133;A;redraw=1\x1b\\");
            try testing.expectEqual(.true, io.terminal.flags.shell_redraws_prompt);
        }
    }.run;

    try testManualTermio(false, body);
    try testManualTermio(true, body);

    // EXEC keeps upstream behavior: a new Terminal assumes the shell
    // redraws its prompt.
    const flags: @FieldType(terminalpkg.Terminal, "flags") = .{};
    try std.testing.expectEqual(.true, flags.shell_redraws_prompt);
}

test "manual: snapshot restore and encode round trip" {
    const S = struct {
        var complete: std.ArrayListUnmanaged(u8) = .empty;
        var ready: std.ArrayListUnmanaged(u8) = .empty;
        var history: std.ArrayListUnmanaged(u8) = .empty;

        fn encode(io: *Termio, phase: apprt.SurfaceSnapshotPhase) ![]u8 {
            const alloc = std.testing.allocator;
            var out: std.Io.Writer.Allocating = .init(alloc);
            errdefer out.deinit();
            try io.encodeSnapshot(&out.writer, phase);
            return try out.toOwnedSlice();
        }

        /// A terminal with styled text, scrollback over several pages,
        /// and an unfinished escape sequence at the cut.
        fn source(io: *Termio, _: *TestSink, _: bool) !void {
            const alloc = std.testing.allocator;
            io.processOutput("\x1b[1;38;2;255;0;0mbold red\x1b[0m plain " ++
                "\x1b[4;48;5;33munderlined\x1b[m\r\n");
            var buf: [64]u8 = undefined;
            for (0..3000) |i| {
                io.processOutput(try std.fmt.bufPrint(&buf, "\x1b[3{d}mline {d}\x1b[m\r\n", .{ i % 8, i }));
            }
            // Output that messages the surface (title, bell) is left out:
            // these tests have no surface mailbox.
            io.processOutput("tail \x1b[");
            try std.testing.expect(io.terminal.screens.get(.primary).?.pages.totalPages() > 2);

            const c = try encode(io, .complete);
            defer alloc.free(c);
            const r = try encode(io, .ready);
            defer alloc.free(r);
            const h = try encode(io, .history);
            defer alloc.free(h);
            try complete.appendSlice(alloc, c);
            try ready.appendSlice(alloc, r);
            try history.appendSlice(alloc, h);
        }

        /// Restore READY, then the history in uneven slices, into a
        /// mirror that has other content, and encode it again.
        fn restore(io: *Termio, sink: *TestSink, _: bool) !void {
            const testing = std.testing;
            const alloc = testing.allocator;

            io.processOutput("\x1b[2Jother content\x1b[5");
            try io.restoreSnapshot(ready.items, .ready);
            var rest = history.items;
            while (rest.len > 0) {
                const n = @min(rest.len, 997);
                try io.restoreSnapshot(rest[0..n], .history);
                rest = rest[n..];
            }
            try testing.expect(io.snapshot_restore == null);

            const again = try encode(io, .complete);
            defer alloc.free(again);
            try testing.expectEqualSlices(u8, complete.items, again);

            // The continuation was replayed: the cut SGR sequence
            // completes with the next output.
            io.processOutput("1mX");
            try testing.expect(io.terminal.screens.active.cursor.style.flags.bold);

            // A restore writes nothing to the pty callback.
            try sink.expect("");

            // A complete snapshot restores in one call too.
            try io.restoreSnapshot(complete.items, .complete);
            try testing.expect(io.snapshot_restore == null);
            const third = try encode(io, .complete);
            defer alloc.free(third);
            try testing.expectEqualSlices(u8, complete.items, third);
            try testing.expectEqual(@as(usize, 0), testDrainMailbox(&io.mailbox));
        }
    };
    const alloc = std.testing.allocator;
    defer S.complete.deinit(alloc);
    defer S.ready.deinit(alloc);
    defer S.history.deinit(alloc);

    try testManualTermio(true, S.source);
    const joined = try std.mem.concat(alloc, u8, &.{ S.ready.items, S.history.items });
    defer alloc.free(joined);
    try std.testing.expectEqualSlices(u8, S.complete.items, joined);
    try testManualTermio(true, S.restore);
}

/// Change the surface config's scrollback byte limit the way
/// ghostty_surface_update_config does (null: unlimited).
fn testSetScrollbackLimit(io: *Termio, bytes: ?usize) !void {
    const alloc = std.testing.allocator;
    var config: configpkg.Config = try .default(alloc);
    defer config.deinit();
    config.@"scrollback-limit-bytes" = .{ .value = bytes orelse std.math.maxInt(usize) };
    var derived: DerivedConfig = try .init(alloc, &config);
    var td = io.manualThreadData();
    try io.changeConfig(&td, &derived);
}

/// The active screen as VT (contents, styles, cursor, modes), for tests
/// that compare what is on screen.
fn testActiveVt(io: *Termio) ![]u8 {
    const alloc = std.testing.allocator;
    const t = &io.terminal;
    const pages = &t.screens.active.pages;
    const top = pages.pin(.{ .active = .{} }).?;
    const bottom = pages.pin(.{ .active = .{ .x = t.cols - 1, .y = t.rows - 1 } }).?;
    var formatter: terminalpkg.formatter.TerminalFormatter = .init(t, .vt);
    formatter.content = .{ .selection = terminalpkg.Selection.init(top, bottom, false) };
    formatter.extra = .all;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try formatter.format(&out.writer);
    return try out.toOwnedSlice();
}

/// Change the surface config's scrollback line limit the way
/// ghostty_surface_update_config does (null: unlimited).
fn testSetScrollbackLines(io: *Termio, lines: ?usize) !void {
    const alloc = std.testing.allocator;
    var config: configpkg.Config = try .default(alloc);
    defer config.deinit();
    config.@"scrollback-limit-lines" = .{ .value = lines orelse std.math.maxInt(usize) };
    var derived: DerivedConfig = try .init(alloc, &config);
    var td = io.manualThreadData();
    try io.changeConfig(&td, &derived);
}

/// The terminal core that owns the byte stream in the local history
/// tests: a libghostty-vt Terminal with the viewer's parsing modes and
/// scrollback limits (the same defaults as a MANUAL surface).
const TestOwner = struct {
    t: terminalpkg.Terminal,
    stream: terminalpkg.TerminalStream,

    /// The owner starts at the viewer's view grid and then takes the
    /// locked grid without reflow, as the viewer did (setGrid on a
    /// mirror), so both have the same pages from the start.
    fn init(self: *TestOwner, io: *Termio, cols: u16, rows: u16, max_lines: ?usize) !void {
        const alloc = std.testing.allocator;
        const view = io.size.grid();
        self.t = try .init(global.io(), alloc, .{
            .cols = view.columns,
            .rows = view.rows,
            .max_scrollback_bytes = io.config.scrollback_limit_bytes,
            .max_scrollback_lines = max_lines,
        });
        errdefer self.t.deinit(alloc);
        try self.t.resize(alloc, .{ .cols = cols, .rows = rows, .reflow = false });
        self.t.flags.shell_redraws_prompt = io.terminal.flags.shell_redraws_prompt;
        self.t.modes.set(.grapheme_cluster, io.terminal.modes.get(.grapheme_cluster));
        self.t.modes.set(.wraparound, io.terminal.modes.get(.wraparound));
        self.stream = self.t.vtStream();
    }

    fn deinit(self: *TestOwner) void {
        self.stream.deinit();
        self.t.deinit(std.testing.allocator);
    }

    /// The owner's resize, then its READY prefix and history digest, as
    /// the host encodes them under its lock at the resize.
    fn resizeAndEncode(self: *TestOwner, cols: u16, rows: u16) !struct { []u8, terminalpkg.history_digest.Digest } {
        const alloc = std.testing.allocator;
        try self.t.resize(alloc, .{ .cols = cols, .rows = rows });
        const snapshot = terminalpkg.snapshot;
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        {
            var stream: snapshot.record.Writer = .init(alloc, &out.writer);
            defer stream.deinit();
            try snapshot.envelope.encode(stream.writer());
            try snapshot.terminal.encode(&self.t, &stream);
            try snapshot.screen.encode(self.t.screens.get(.primary).?, .primary, &stream);
            if (self.t.screens.get(.alternate)) |alternate| {
                try snapshot.screen.encode(alternate, .alternate, &stream);
            }
            try snapshot.continuation.encode(.ground, &stream);
            try snapshot.checkpoint.encode(.ready, &stream);
        }
        return .{ try out.toOwnedSlice(), terminalpkg.history_digest.terminal(&self.t) };
    }
};

/// Feed the same bytes to the viewer and the owner.
fn testFeedBoth(io: *Termio, owner: *TestOwner, bytes: []const u8) void {
    io.processOutput(bytes);
    owner.stream.nextSlice(bytes);
}

/// 300 numbered lines (from `first`): every third one a 70-character line
/// that soft-wraps at 40 columns, some bold or colored.
fn testFeedLines(io: *Termio, owner: *TestOwner, first: usize, count: usize) !void {
    var buf: [160]u8 = undefined;
    for (first..first + count) |i| {
        const line = if (i % 3 == 0)
            try std.fmt.bufPrint(&buf, "\x1b[1mline {d:0>4}\x1b[m " ++ ("abcdefghij" ** 6) ++ "\r\n", .{i})
        else
            try std.fmt.bufPrint(&buf, "\x1b[3{d}mline {d:0>4}\x1b[m short\r\n", .{ i % 8, i });
        testFeedBoth(io, owner, line);
    }
}

/// The primary screen as plain text, history and active area, one row
/// per line, from history row `from` (0: the oldest row).
fn testPrimaryText(t: *terminalpkg.Terminal, from: usize) ![]const u8 {
    const alloc = std.testing.allocator;
    const primary = t.screens.get(.primary).?;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try primary.dumpString(&out.writer, .{
        .tl = primary.pages.pin(.{ .screen = .{ .y = @intCast(from) } }).?,
        .unwrap = false,
    });
    return try out.toOwnedSlice();
}

fn testExpectSamePrimary(io: *Termio, owner: *TestOwner) !void {
    const alloc = std.testing.allocator;
    const want = try testPrimaryText(&owner.t, 0);
    defer alloc.free(want);
    const got = try testPrimaryText(&io.terminal, 0);
    defer alloc.free(got);
    try std.testing.expectEqualStrings(want, got);
    try std.testing.expect(terminalpkg.history_digest.terminal(&io.terminal)
        .eql(terminalpkg.history_digest.terminal(&owner.t)));
}

fn testHistoryRows(t: *terminalpkg.Terminal) usize {
    const pages = &t.screens.get(.primary).?.pages;
    return pages.total_rows - pages.rows;
}

/// The primary history rows a READY prefix itself carries: the rows
/// above the active area in the active area's first page. A restore that
/// has more history rows took the rest from the local terminal.
fn testReadyHistoryRows(ready: []const u8) !usize {
    const alloc = std.testing.allocator;
    var reader: std.Io.Reader = .fixed(ready);
    var decoder: terminalpkg.snapshot.Decoder = .init(&reader);
    var decoded = try decoder.ready(alloc, global.io(), .{
        .max_continuation_bytes = snapshot_continuation_max_bytes,
    });
    defer decoded.deinit(alloc);
    return testHistoryRows(&decoded.terminal.?);
}

test "manual: snapshot local history restore keeps the reflowed scrollback" {
    const body = struct {
        fn run(io: *Termio, sink: *TestSink, _: bool) !void {
            const testing = std.testing;
            const alloc = testing.allocator;

            try testing.expect(io.setGrid(40, 10, 7));
            var owner: TestOwner = undefined;
            try owner.init(io, 40, 10, null);
            defer owner.deinit();

            // Enough history for several pages at 25 columns, so most of
            // it is older than the READY's first page.
            testFeedBoth(io, &owner, "\x1b[1;31mfirst styled line\x1b[m\r\n");
            try testFeedLines(io, &owner, 0, 3000);
            testFeedBoth(io, &owner, "prompt$ ");

            const ready, const digest = try owner.resizeAndEncode(25, 10);
            defer alloc.free(ready);
            try testing.expect(digest.history_rows > 2 * try testReadyHistoryRows(ready));

            try testing.expectEqual(
                LocalHistoryResult.restored,
                try io.restoreSnapshotLocalHistory(ready, digest),
            );

            // The grid takes the snapshot's size and keeps its generation.
            try testing.expectEqual(@as(u16, 25), io.terminal.cols);
            try testing.expectEqual(@as(u16, 25), io.grid_lock.?.cols);
            try testing.expectEqual(@as(u64, 7), io.grid_lock.?.generation);

            // History and screen equal the owner's, from the earliest line,
            // with its style.
            try testExpectSamePrimary(io, &owner);
            {
                const text = try testPrimaryText(&io.terminal, 0);
                defer alloc.free(text);
                try testing.expect(std.mem.startsWith(u8, text, "first styled line"));
                const primary = io.terminal.screens.get(.primary).?;
                const pin = primary.pages.pin(.{ .screen = .{} }).?;
                try testing.expect(pin.style(pin.rowAndCell().cell).flags.bold);
            }

            // The snapshot is complete.
            try testing.expectError(error.NoSnapshotInProgress, io.restoreSnapshot(&.{}, .history));

            // Later output keeps both sides equal.
            try testFeedLines(io, &owner, 3000, 120);
            testFeedBoth(io, &owner, "done$ ");
            try testExpectSamePrimary(io, &owner);

            try sink.expect("");
        }
    }.run;
    try testManualTermio(true, body);
}

test "manual: snapshot local history restore with the alternate screen active" {
    const body = struct {
        fn run(io: *Termio, sink: *TestSink, _: bool) !void {
            const testing = std.testing;
            const alloc = testing.allocator;

            try testing.expect(io.setGrid(40, 10, 1));
            var owner: TestOwner = undefined;
            try owner.init(io, 40, 10, null);
            defer owner.deinit();

            try testFeedLines(io, &owner, 0, 3000);
            // vim: alternate screen with a full-width status line.
            testFeedBoth(io, &owner, "\x1b[?1049h\x1b[H\x1b[2J~\r\n~\r\n\x1b[10;1H\x1b[7m" ++
                ("-- INSERT --" ++ " " ** 28) ++ "\x1b[m\x1b[1;1H");

            const ready, const digest = try owner.resizeAndEncode(25, 12);
            defer alloc.free(ready);
            try testing.expect(digest.history_rows > 2 * try testReadyHistoryRows(ready));
            try testing.expectEqual(
                LocalHistoryResult.restored,
                try io.restoreSnapshotLocalHistory(ready, digest),
            );
            try testing.expectEqual(terminalpkg.ScreenSet.Key.alternate, io.terminal.screens.active_key);
            {
                const want = try owner.t.plainString(alloc);
                defer alloc.free(want);
                const got = try io.terminal.plainString(alloc);
                defer alloc.free(got);
                try testing.expectEqualStrings(want, got);
            }
            try testExpectSamePrimary(io, &owner);

            // Leaving vim shows the same primary screen and history.
            testFeedBoth(io, &owner, "\x1b[?1049l");
            try testing.expectEqual(terminalpkg.ScreenSet.Key.primary, io.terminal.screens.active_key);
            try testExpectSamePrimary(io, &owner);
            try testFeedLines(io, &owner, 3000, 40);
            try testExpectSamePrimary(io, &owner);

            try sink.expect("");
        }
    }.run;
    try testManualTermio(true, body);
}

test "manual: snapshot local history restore under a scrollback limit" {
    const body = struct {
        fn run(io: *Termio, _: *TestSink, _: bool) !void {
            const testing = std.testing;
            const alloc = testing.allocator;

            // Both sides keep at most 2500 history lines, fewer than the
            // output: both dropped their oldest pages the same way.
            try testSetScrollbackLines(io, 2500);
            try testing.expect(io.setGrid(40, 10, 1));
            var owner: TestOwner = undefined;
            try owner.init(io, 40, 10, 2500);
            defer owner.deinit();

            try testFeedLines(io, &owner, 0, 4000);
            const ready, const digest = try owner.resizeAndEncode(25, 10);
            defer alloc.free(ready);

            try testing.expectEqual(
                LocalHistoryResult.restored,
                try io.restoreSnapshotLocalHistory(ready, digest),
            );
            try testExpectSamePrimary(io, &owner);
            const text = try testPrimaryText(&io.terminal, 0);
            defer alloc.free(text);
            try testing.expect(std.mem.indexOf(u8, text, "line 0000") == null);
            try testing.expect(std.mem.indexOf(u8, text, "line 3999") != null);
            const pages = &io.terminal.screens.get(.primary).?.pages;
            try testing.expect(testHistoryRows(&io.terminal) <= pages.limits.max(.lines));
        }
    }.run;
    try testManualTermio(true, body);
}

test "manual: snapshot local history restore with a smaller viewer scrollback limit" {
    const body = struct {
        fn run(io: *Termio, _: *TestSink, _: bool) !void {
            const testing = std.testing;
            const alloc = testing.allocator;

            // The viewer keeps at most 4000 history lines, the owner all
            // of them: 2000 soft-wrapped lines (6000 rows at 25 columns).
            try testSetScrollbackLines(io, 4000);
            try testing.expect(io.setGrid(40, 10, 1));
            var owner: TestOwner = undefined;
            try owner.init(io, 40, 10, null);
            defer owner.deinit();

            var buf: [160]u8 = undefined;
            for (0..2000) |i| {
                testFeedBoth(io, &owner, try std.fmt.bufPrint(
                    &buf,
                    "\x1b[3{d}mline {d:0>4}\x1b[m " ++ ("abcdefghij" ** 6) ++ "\r\n",
                    .{ i % 8, i },
                ));
            }
            const ready, const digest = try owner.resizeAndEncode(25, 10);
            defer alloc.free(ready);

            try testing.expectEqual(
                LocalHistoryResult.restored,
                try io.restoreSnapshotLocalHistory(ready, digest),
            );

            // The viewer's history is the owner's newest history, from
            // the viewer's first complete line (the oldest line can be a
            // fragment that reflowed differently).
            const kept = testHistoryRows(&io.terminal);
            const owner_rows = testHistoryRows(&owner.t);
            try testing.expect(kept < owner_rows);
            try testing.expect(kept > try testReadyHistoryRows(ready));
            const got_all = try testPrimaryText(&io.terminal, 0);
            defer alloc.free(got_all);
            const first_line = std.mem.indexOf(u8, got_all, "line ").?;
            const got = got_all[first_line..];
            const want = try testPrimaryText(&owner.t, 0);
            defer alloc.free(want);
            try testing.expect(got.len > 64 * 25);
            try testing.expect(std.mem.endsWith(u8, want, got));
            try testing.expect(std.mem.indexOf(u8, got, "line 1999") != null);
        }
    }.run;
    try testManualTermio(true, body);
}

test "manual: snapshot local history restore refuses a diverged history" {
    const S = struct {
        /// The viewer misses one output frame before the resize.
        fn missedFrame(io: *Termio, _: *TestSink, _: bool) !void {
            const testing = std.testing;
            const alloc = testing.allocator;

            try testing.expect(io.setGrid(40, 10, 1));
            var owner: TestOwner = undefined;
            try owner.init(io, 40, 10, null);
            defer owner.deinit();

            try testFeedLines(io, &owner, 0, 2000);
            owner.stream.nextSlice("a frame the viewer never got\r\n");
            try testFeedLines(io, &owner, 2000, 1000);

            const ready, const digest = try owner.resizeAndEncode(25, 10);
            defer alloc.free(ready);
            try expectReadyOnly(io, &owner, ready, digest);
            // The local history was discarded, not only the frame.
            try testing.expect(testHistoryRows(&io.terminal) < digest.history_rows / 2);
        }

        /// The owner parses graphemes as legacy codepoints; the viewer
        /// uses grapheme clusters (mode 2027).
        fn graphemeMode(io: *Termio, _: *TestSink, _: bool) !void {
            const testing = std.testing;
            const alloc = testing.allocator;

            try testing.expect(io.setGrid(40, 10, 1));
            try testing.expect(io.terminal.modes.get(.grapheme_cluster));
            var owner: TestOwner = undefined;
            try owner.init(io, 40, 10, null);
            defer owner.deinit();
            owner.t.modes.set(.grapheme_cluster, false);

            for (0..100) |_| {
                testFeedBoth(io, &owner, "family \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} " ++
                    ("abcdefghij" ** 4) ++ "\r\n");
            }

            const ready, const digest = try owner.resizeAndEncode(25, 10);
            defer alloc.free(ready);
            try expectReadyOnly(io, &owner, ready, digest);
        }

        /// A mismatch restores the READY terminal without the local
        /// history: the screen and the rows the READY carries above it
        /// equal the owner's, and nothing older is kept.
        fn expectReadyOnly(
            io: *Termio,
            owner: *TestOwner,
            ready: []const u8,
            digest: terminalpkg.history_digest.Digest,
        ) !void {
            const testing = std.testing;
            const alloc = testing.allocator;
            try testing.expectEqual(
                LocalHistoryResult.mismatch,
                try io.restoreSnapshotLocalHistory(ready, digest),
            );
            try testing.expectEqual(@as(u16, 25), io.terminal.cols);

            const kept = testHistoryRows(&io.terminal);
            const owner_rows = testHistoryRows(&owner.t);
            try testing.expectEqual(try testReadyHistoryRows(ready), kept);
            const want = try testPrimaryText(&owner.t, owner_rows - kept);
            defer alloc.free(want);
            const got = try testPrimaryText(&io.terminal, 0);
            defer alloc.free(got);
            try testing.expectEqualStrings(want, got);

            // A plain READY restore keeps exactly the same rows.
            try io.restoreSnapshot(ready, .ready);
            try testing.expectEqual(kept, testHistoryRows(&io.terminal));
            io.abandonSnapshotRestore();

            // The caller then applies the owner's history.
            try testing.expectError(error.NoSnapshotInProgress, io.restoreSnapshot(&.{}, .history));
        }
    };
    try testManualTermio(true, S.missedFrame);
    try testManualTermio(true, S.graphemeMode);
}

test "manual: snapshot local history restore errors leave the terminal unchanged" {
    const body = struct {
        fn run(io: *Termio, _: *TestSink, _: bool) !void {
            const testing = std.testing;
            const alloc = testing.allocator;

            try testing.expect(io.setGrid(40, 10, 1));
            var owner: TestOwner = undefined;
            try owner.init(io, 40, 10, null);
            defer owner.deinit();
            try testFeedLines(io, &owner, 0, 100);

            const ready, const digest = try owner.resizeAndEncode(25, 10);
            defer alloc.free(ready);
            const before = try testPrimaryText(&io.terminal, 0);
            defer alloc.free(before);

            // Bytes after READY.
            const trailing = try std.mem.concat(alloc, u8, &.{ ready, "x" });
            defer alloc.free(trailing);
            try testing.expectError(
                error.TrailingSnapshotBytes,
                io.restoreSnapshotLocalHistory(trailing, digest),
            );
            // A truncated READY.
            if (io.restoreSnapshotLocalHistory(ready[0 .. ready.len - 1], digest)) |_| {
                return error.TestUnexpectedResult;
            } else |_| {}

            try testing.expectEqual(@as(u16, 40), io.terminal.cols);
            const after = try testPrimaryText(&io.terminal, 0);
            defer alloc.free(after);
            try testing.expectEqualStrings(before, after);
        }
    }.run;
    try testManualTermio(true, body);
}

test "manual: the config scrollback limit holds across snapshot restores" {
    const S = struct {
        var ready: std.ArrayListUnmanaged(u8) = .empty;
        var history: std.ArrayListUnmanaged(u8) = .empty;
        var screen: []u8 = &.{};
        var host_pages: usize = 0;

        /// The phone's limit: a third of the host's history bytes, so
        /// some history stays and the oldest pages go.
        var cap: usize = 0;

        fn encode(io: *Termio, phase: apprt.SurfaceSnapshotPhase, out: *std.ArrayListUnmanaged(u8)) !void {
            const alloc = std.testing.allocator;
            var w: std.Io.Writer.Allocating = .init(alloc);
            defer w.deinit();
            try io.encodeSnapshot(&w.writer, phase);
            try out.appendSlice(alloc, w.written());
        }

        /// The host: unlimited scrollback, many pages of history.
        fn host(io: *Termio, _: *TestSink, _: bool) !void {
            io.terminal.setScrollbackMaxBytes(null);
            var buf: [64]u8 = undefined;
            for (0..6000) |i| {
                io.processOutput(try std.fmt.bufPrint(&buf, "\x1b[3{d}mline {d}\x1b[m\r\n", .{ i % 8, i }));
            }
            io.processOutput("\x1b[41mbottom\x1b[m");
            const pages = &io.terminal.screens.get(.primary).?.pages;
            host_pages = pages.totalPages();
            cap = pages.page_size / 3;
            screen = try testActiveVt(io);
            try encode(io, .ready, &ready);
            try encode(io, .history, &history);
        }

        fn phone(io: *Termio, sink: *TestSink, _: bool) !void {
            const testing = std.testing;
            const alloc = testing.allocator;
            try testSetScrollbackLimit(io, cap);

            try io.restoreSnapshot(ready.items, .ready);
            try io.restoreSnapshot(history.items, .history);
            try testing.expect(io.snapshot_restore == null);

            // The restored terminal has the surface config's limit, not
            // the host's (unlimited), and history stopped at it: the
            // oldest pages were dropped.
            const pages = &io.terminal.screens.get(.primary).?.pages;
            try testing.expectEqual(cap, pages.limits.bytes.explicit);
            try testing.expect(pages.totalPages() < host_pages);
            try testing.expect(pages.totalPages() > 1);
            try testing.expect(pages.page_size <= pages.limits.max(.bytes));

            // What is on screen equals the host's screen.
            {
                const vt = try testActiveVt(io);
                defer alloc.free(vt);
                try testing.expectEqualStrings(screen, vt);
            }

            // A later READY restore keeps the local limit too.
            try io.restoreSnapshot(ready.items, .ready);
            try testing.expectEqual(cap, io.terminal.screens.get(.primary).?.pages.limits.bytes.explicit);
            {
                const vt = try testActiveVt(io);
                defer alloc.free(vt);
                try testing.expectEqualStrings(screen, vt);
            }

            // A config change applies to the live terminal and to the
            // next restore.
            try testSetScrollbackLimit(io, 2 * cap);
            try testing.expectEqual(2 * cap, io.terminal.screens.get(.primary).?.pages.limits.bytes.explicit);
            try io.restoreSnapshot(ready.items, .ready);
            try testing.expectEqual(2 * cap, io.terminal.screens.get(.primary).?.pages.limits.bytes.explicit);

            try sink.expect("");
        }
    };
    const alloc = std.testing.allocator;
    defer S.ready.deinit(alloc);
    defer S.history.deinit(alloc);
    defer alloc.free(S.screen);

    try testManualTermio(true, S.host);
    try testManualTermio(true, S.phone);
}

test "manual: snapshot restores take this surface's colors and cursor defaults" {
    const S = struct {
        const host_red: terminalpkg.color.RGB = .{ .r = 0xaa, .g = 0x01, .b = 0x01 };
        const host_bg: terminalpkg.color.RGB = .{ .r = 0x10, .g = 0x20, .b = 0x30 };
        const host_fg: terminalpkg.color.RGB = .{ .r = 0x70, .g = 0x71, .b = 0x72 };
        const local_red: terminalpkg.color.RGB = .{ .r = 0xcc, .g = 0x02, .b = 0x02 };
        const local_bg: terminalpkg.color.RGB = .{ .r = 0x40, .g = 0x50, .b = 0x60 };
        const local_fg: terminalpkg.color.RGB = .{ .r = 0xe0, .g = 0xe1, .b = 0xe2 };
        const osc_green: terminalpkg.color.RGB = .{ .r = 0x11, .g = 0x22, .b = 0x33 };
        const osc_bg: terminalpkg.color.RGB = .{ .r = 0x05, .g = 0x06, .b = 0x07 };

        /// READY with the program's cursor at its default (taken on the
        /// alternate screen), then READY after an explicit DECSCUSR bar.
        var follows_default: std.ArrayListUnmanaged(u8) = .empty;
        var explicit: std.ArrayListUnmanaged(u8) = .empty;

        fn encode(io: *Termio, out: *std.ArrayListUnmanaged(u8)) !void {
            const alloc = std.testing.allocator;
            var w: std.Io.Writer.Allocating = .init(alloc);
            defer w.deinit();
            try io.encodeSnapshot(&w.writer, .ready);
            try out.appendSlice(alloc, w.written());
        }

        /// The owner: its own default palette, colors and cursor style
        /// (block_hollow, blinking), plus a program's overrides of palette
        /// index 2 and of the background (applied directly: these tests
        /// have no surface mailbox for the color_change message).
        fn host(io: *Termio, _: *TestSink, _: bool) !void {
            const alloc = std.testing.allocator;
            const t = &io.terminal;
            var palette = terminalpkg.color.default;
            palette[1] = host_red;
            try t.colors.palette.changeDefault(alloc, palette);
            t.colors.background.default = host_bg;
            t.colors.foreground.default = host_fg;
            t.setDefaultCursorStyle(.block_hollow);
            t.setDefaultCursorBlink(true);
            t.colors.palette.set(2, osc_green);
            t.colors.background.override = osc_bg;
            io.processOutput("prompt$ \x1b[?1049h");
            try std.testing.expect(t.cursor.is_default);
            try encode(io, &follows_default);
            io.processOutput("\x1b[6 q");
            try std.testing.expect(!t.cursor.is_default);
            try encode(io, &explicit);
        }

        /// This surface: palette 1, colors and a steady underline cursor
        /// from its own config.
        fn viewer(io: *Termio, _: *TestSink, _: bool) !void {
            const testing = std.testing;
            const alloc = testing.allocator;
            var config: configpkg.Config = try .default(alloc);
            defer config.deinit();
            config.palette.value[1] = local_red;
            config.palette.mask.set(1);
            config.background = .{ .r = local_bg.r, .g = local_bg.g, .b = local_bg.b };
            config.foreground = .{ .r = local_fg.r, .g = local_fg.g, .b = local_fg.b };
            config.@"cursor-style" = .underline;
            config.@"cursor-style-blink" = false;
            var derived: DerivedConfig = try .init(alloc, &config);
            var td = io.manualThreadData();
            try io.changeConfig(&td, &derived);

            try io.restoreSnapshot(follows_default.items, .ready);
            const t = &io.terminal;
            try testing.expectEqual(local_red, t.colors.palette.original[1]);
            try testing.expectEqual(local_red, t.colors.palette.current[1]);
            // The program's overrides survive the restore.
            try testing.expectEqual(osc_green, t.colors.palette.current[2]);
            try testing.expectEqual(osc_bg, t.colors.background.override.?);
            try testing.expectEqual(local_bg, t.colors.background.default.?);
            try testing.expectEqual(local_fg, t.colors.foreground.default.?);
            try testing.expectEqual(terminalpkg.CursorStyle.underline, t.cursor.default_style);
            try testing.expectEqual(terminalpkg.CursorStyle.underline, t.screens.active.cursor.cursor_style);
            try testing.expect(!t.modes.get(.cursor_blinking));

            // Back on the primary screen the cursor still follows this
            // surface's default (DECRC does not restore the shape).
            io.processOutput("\x1b[?1049l");
            try testing.expectEqual(terminalpkg.CursorStyle.underline, io.terminal.screens.active.cursor.cursor_style);

            // A program's explicit cursor shape stays; the default is ours.
            try io.restoreSnapshot(explicit.items, .ready);
            try testing.expectEqual(terminalpkg.CursorStyle.bar, io.terminal.screens.active.cursor.cursor_style);
            try testing.expectEqual(terminalpkg.CursorStyle.underline, io.terminal.cursor.default_style);
            try testing.expectEqual(local_bg, io.terminal.colors.background.default.?);

            // DECSCUSR 0 then selects this surface's default.
            io.processOutput("\x1b[0 q");
            try testing.expectEqual(terminalpkg.CursorStyle.underline, io.terminal.screens.active.cursor.cursor_style);
            try testing.expect(!io.terminal.modes.get(.cursor_blinking));
        }
    };
    const alloc = std.testing.allocator;
    defer S.follows_default.deinit(alloc);
    defer S.explicit.deinit(alloc);

    try testManualTermio(true, S.host);
    try testManualTermio(true, S.viewer);
}

test "manual: a config scrollback limit change trims the live terminal" {
    const body = struct {
        fn run(io: *Termio, _: *TestSink, _: bool) !void {
            const testing = std.testing;
            io.terminal.setScrollbackMaxBytes(null);
            var buf: [64]u8 = undefined;
            for (0..6000) |i| {
                io.processOutput(try std.fmt.bufPrint(&buf, "line {d}\r\n", .{i}));
            }
            // A Kitty image placed on screen (in-band, 1x1 RGB).
            io.processOutput("\x1b_Ga=T,f=24,s=1,v=1,i=7;AAAA\x1b\\");
            const kitty = terminalpkg.options.kitty_graphics;
            const images = &io.terminal.screens.active.kitty_images;
            if (comptime kitty) {
                try testing.expectEqual(@as(usize, 1), images.images.count());
                try testing.expectEqual(@as(usize, 1), images.placements.count());
            }

            const pages = &io.terminal.screens.get(.primary).?.pages;
            const before = pages.totalPages();
            try testSetScrollbackLimit(io, pages.page_size / 3);
            try testing.expect(pages.totalPages() < before);

            // The on-screen image and its placement stay.
            if (comptime kitty) {
                try testing.expectEqual(@as(usize, 1), images.images.count());
                try testing.expectEqual(@as(usize, 1), images.placements.count());
            }

            // The active area is intact.
            const alloc = testing.allocator;
            const str = try io.terminal.plainString(alloc);
            defer alloc.free(str);
            try testing.expect(std.mem.indexOf(u8, str, "line 5999") != null);
        }
    }.run;

    try testManualTermio(true, body);
}

test "manual: snapshot history refuses malformed and oversized records" {
    const body = struct {
        fn run(io: *Termio, _: *TestSink, _: bool) !void {
            const testing = std.testing;
            const alloc = testing.allocator;

            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            try io.encodeSnapshot(&out.writer, .ready);

            // A record header that claims a 4 GiB payload is refused at
            // once instead of buffering toward it.
            try io.restoreSnapshot(out.written(), .ready);
            try testing.expect(io.snapshot_restore != null);
            const huge = [_]u8{ 4, 0, 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0 };
            try testing.expectError(
                error.SnapshotRecordTooLarge,
                io.restoreSnapshot(&huge, .history),
            );
            try testing.expect(io.snapshot_restore == null);

            // Complete records whose payloads are too short for their
            // contents: malformed, not "still arriving".
            try io.restoreSnapshot(out.written(), .ready);
            const short = [_]u8{ 4, 0, 0, 0, 0, 0, 0, 0, 0, 0 } ** 3;
            if (io.restoreSnapshot(&short, .history)) |_| {
                return error.TestExpectedError;
            } else |_| {}
            try testing.expect(io.snapshot_restore == null);
        }
    }.run;

    try testManualTermio(true, body);
}

test "manual: processOutput parses output and routes replies by mode" {
    const body = struct {
        fn run(io: *Termio, sink: *TestSink, mirror: bool) !void {
            const testing = std.testing;
            const alloc = testing.allocator;

            io.processOutput("hello\x1b[c");
            const str = try io.terminal.plainString(alloc);
            defer alloc.free(str);
            try testing.expectEqualStrings("hello", str);

            // Parser replies never run on the calling thread. MANUAL
            // queues the DA reply for the termio thread; a mirror drops it.
            try sink.expect("");
            try testing.expectEqual(
                @as(usize, if (mirror) 0 else 1),
                testDrainMailbox(&io.mailbox),
            );
        }
    }.run;

    try testManualTermio(false, body);
    try testManualTermio(true, body);
}

test "manual: Kitty graphics load in-band data only" {
    const body = struct {
        fn run(io: *Termio, _: *TestSink, _: bool) !void {
            const testing = std.testing;
            const alloc = testing.allocator;

            // A file that a t=t load would read and then unlink.
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();
            const name = "tty-graphics-protocol-image.data";
            try tmp_dir.dir.writeFile(testing.io, .{ .sub_path = name, .data = "\x00\x00\x00" });
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = path_buf[0..try tmp_dir.dir.realPathFile(testing.io, name, &path_buf)];

            try expectRejected(io, path);

            // A config change keeps the manual limits.
            var td = io.manualThreadData();
            var config: configpkg.Config = try .default(alloc);
            defer config.deinit();
            var derived: DerivedConfig = try .init(alloc, &config);
            try io.changeConfig(&td, &derived);
            try expectRejected(io, path);

            // The file was neither read away nor unlinked.
            try tmp_dir.dir.access(testing.io, path, .{});
        }

        fn expectRejected(io: *Termio, path: []const u8) !void {
            const testing = std.testing;
            const alloc = testing.allocator;

            var b64: [std.fs.max_path_bytes * 2]u8 = undefined;
            const shm_name = "/ghostty-next-manual-test";
            const inputs = [_]struct { medium: []const u8, data: []const u8 }{
                .{ .medium = "t", .data = path },
                .{ .medium = "f", .data = path },
                .{ .medium = "s", .data = shm_name },
            };
            for (inputs) |input| {
                const cmd_str = try std.fmt.allocPrint(
                    alloc,
                    "a=t,t={s},f=24,s=1,v=1,i=5;{s}",
                    .{ input.medium, std.base64.standard.Encoder.encode(&b64, input.data) },
                );
                defer alloc.free(cmd_str);
                var cmd = try terminalpkg.kitty.graphics.CommandParser.parseString(alloc, cmd_str);
                defer cmd.deinit(alloc);
                const resp = io.terminal.kittyGraphics(global.io(), alloc, &cmd) orelse
                    return error.TestExpectedResponse;
                try testing.expect(!resp.ok());
            }
        }
    }.run;

    try testManualTermio(false, body);
}
