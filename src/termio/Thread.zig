//! Represents the "writer" thread for terminal IO. The reader side is
//! handled by the Termio struct itself and dependent on the underlying
//! implementation (i.e. if its a pty, manual, etc.).
//!
//! The writer thread does handle writing bytes to the pty but also handles
//! different events such as starting synchronized output, changing some
//! modes (like linefeed), etc. The goal is to offload as much from the
//! reader thread as possible since it is the hot path in parsing VT
//! sequences and updating terminal state.
//!
//! This thread state can only be used by one thread at a time.
//!
//! A manual backend has no PTY to service, so its surface spawns no thread
//! for this: the handlers run on the surface's renderer thread loop
//! (`Mode.hosted`, `loopGuest`). Chromium does the same with sequences:
//! work that needs ordering, not a thread of its own, posts to a
//! SequencedTaskRunner on a shared thread (base/task/sequenced_task_runner.h).
pub const Thread = @This();

const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const builtin = @import("builtin");
const global = @import("../global.zig");
const xev = global.xev;
const crash = @import("../crash/main.zig");
const internal_os = @import("../os/main.zig");
const termio = @import("../termio.zig");
const renderer = @import("../renderer.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.io_thread);

/// This stores the information that is coalesced.
const Coalesce = struct {
    /// The number of milliseconds to coalesce certain messages like resize for.
    /// Not all message types are coalesced.
    const min_ms = 25;

    resize: ?renderer.Size = null,
};

/// The number of milliseconds before we reset the synchronized output flag
/// if the running program hasn't already.
const sync_reset_ms = 1000;

/// The number of milliseconds between each movement during selection scrolling.
const selection_scroll_ms = 15;

/// Where the handlers of a Thread run.
pub const Mode = enum {
    /// `threadMain` runs an event loop of its own on a thread the caller
    /// spawns.
    own,

    /// Another thread's event loop runs the handlers between `attach` and
    /// `detach`; no thread is spawned. For backends with no PTY (manual).
    hosted,
};

/// Allocator used for some state
alloc: std.mem.Allocator,

/// The event loop the handlers run on. For `.own` this thread owns the
/// loop. For `.hosted` it is the host's loop, null until `attach`.
loop: union(Mode) {
    own: xev.Loop,
    hosted: ?*xev.Loop,
},

/// The completion to use for the wakeup async handle that is present
/// on the termio.Writer.
wakeup_c: xev.Completion = .{},

/// This can be used to stop the thread on the next loop iteration.
/// Null for `.hosted`: the host stops its own loop.
stop: ?xev.Async,
stop_c: xev.Completion = .{},

/// The callback data of a hosted thread, which has no stack frame of its
/// own to keep it in. Set by `loopGuest`.
hosted_cb: ?CallbackData = null,

/// A hosted thread's backend started (`attach`), so `detach` stops it.
hosted_entered: bool = false,

/// This is used for timer-based selection scrolling.
scroll: xev.Timer,
scroll_c: xev.Completion = .{},
scroll_active: bool = false,

/// This is used to coalesce resize events.
coalesce: xev.Timer,
coalesce_c: xev.Completion = .{},
coalesce_cancel_c: xev.Completion = .{},
coalesce_data: Coalesce = .{},

/// This timer is used to reset synchronized output modes so that
/// the terminal doesn't freeze with a bad actor.
sync_reset: xev.Timer,
sync_reset_c: xev.Completion = .{},
sync_reset_cancel_c: xev.Completion = .{},

flags: packed struct {
    /// This is set to true only when an abnormal exit is detected. It
    /// tells our mailbox system to drain and ignore all messages.
    drain: bool = false,

    /// True if linefeed mode is enabled. This is duplicated here so that the
    /// write thread doesn't need to grab a lock to check this on every write.
    linefeed_mode: bool = false,

    /// This is true when the inspector is active.
    has_inspector: bool = false,
} = .{},

/// Initialize the thread. This does not START the thread. This only sets
/// up all the internal state necessary prior to starting the thread. For
/// `.own` the caller starts the thread with the threadMain entrypoint; for
/// `.hosted` a host loop runs the handlers (`loopGuest`).
pub fn init(
    alloc: Allocator,
    mode: Mode,
) !Thread {
    // Create our event loop, and the async handle used to stop it and
    // force the thread to end. A hosted thread has neither.
    var loop: @FieldType(Thread, "loop") = switch (mode) {
        .own => .{ .own = try xev.Loop.init(.{}) },
        .hosted => .{ .hosted = null },
    };
    errdefer switch (loop) {
        .own => |*l| l.deinit(),
        .hosted => {},
    };

    var stop_h: ?xev.Async = switch (mode) {
        .own => try xev.Async.init(),
        .hosted => null,
    };
    errdefer if (stop_h) |*h| h.deinit();

    // This timer is used for selection scrolling.
    var scroll_h = try xev.Timer.init();
    errdefer scroll_h.deinit();

    // This timer is used to coalesce resize events.
    var coalesce_h = try xev.Timer.init();
    errdefer coalesce_h.deinit();

    // This timer is used to reset synchronized output modes.
    var sync_reset_h = try xev.Timer.init();
    errdefer sync_reset_h.deinit();

    return Thread{
        .alloc = alloc,
        .loop = loop,
        .stop = stop_h,
        .scroll = scroll_h,
        .coalesce = coalesce_h,
        .sync_reset = sync_reset_h,
    };
}

/// Clean up the thread. This is only safe to call once the thread
/// completes executing; the caller must join prior to this (for
/// `.hosted`, the host has called `detach`).
pub fn deinit(self: *Thread) void {
    self.scroll.deinit();
    self.coalesce.deinit();
    self.sync_reset.deinit();
    if (self.stop) |*h| h.deinit();
    switch (self.loop) {
        .own => |*l| l.deinit(),
        .hosted => {},
    }
}

/// The event loop the handlers run on.
pub fn eventLoop(self: *Thread) *xev.Loop {
    return switch (self.loop) {
        .own => |*l| l,
        .hosted => |l| l.?,
    };
}

/// The hook that runs a `.hosted` thread's handlers on the renderer
/// thread's loop for the surface's lifetime. `self` and `io` must not move
/// until the renderer thread has exited.
pub fn loopGuest(self: *Thread, io: *termio.Termio) renderer.Thread.LoopGuest {
    std.debug.assert(self.loop == .hosted);
    self.hosted_cb = .{ .self = self, .io = io };
    return .{
        .ctx = self,
        .enter = guestEnter,
        .exit = guestExit,
    };
}

fn guestEnter(ctx: *anyopaque, loop: *xev.Loop) void {
    const self: *Thread = @ptrCast(@alignCast(ctx));
    self.attach(loop);
}

fn guestExit(ctx: *anyopaque) void {
    const self: *Thread = @ptrCast(@alignCast(ctx));
    self.detach();
}

/// Start the handlers of a `.hosted` thread on `loop`, on the thread that
/// runs that loop. If the backend fails to start, the terminal shows the
/// error and the mailbox is only drained, as `threadMain` does.
pub fn attach(self: *Thread, loop: *xev.Loop) void {
    const cb = &self.hosted_cb.?;
    self.loop = .{ .hosted = loop };
    if (cb.io.threadEnter(self, &cb.data)) {
        self.hosted_entered = true;
    } else |err| {
        log.warn("error in hosted io err={}", .{err});
        showStartError(self.alloc, cb.io, err);
        self.flags.drain = true;
    }

    cb.io.mailbox.spsc.wakeup.wait(loop, &self.wakeup_c, CallbackData, cb, wakeupCallback);
}

/// Stop the handlers of a `.hosted` thread. Called on the host thread once
/// its loop has stopped; timers still armed on it never fire again.
pub fn detach(self: *Thread) void {
    const cb = &self.hosted_cb.?;
    if (self.hosted_entered) {
        cb.io.threadExit(&cb.data);
        cb.data.deinit();
        self.hosted_entered = false;
    }
}

/// The main entrypoint for the thread.
pub fn threadMain(self: *Thread, io: *termio.Termio) void {
    // Call child function so we can use errors...
    self.threadMain_(io) catch |err| {
        log.warn("error in io thread err={}", .{err});
        showStartError(self.alloc, io, err);
    };

    // If our loop is not stopped, then we need to keep running so that
    // messages are drained and we can wait for the surface to send a stop
    // message.
    const loop = &self.loop.own;
    if (!loop.stopped()) {
        log.warn("abrupt io thread exit detected, starting xev to drain mailbox", .{});
        defer log.debug("io thread fully exiting after abnormal failure", .{});
        self.flags.drain = true;
        loop.run(.until_done) catch |err| {
            log.err("failed to start xev loop for draining err={}", .{err});
        };
    }
}

/// Replace the terminal screen with the error that stopped the IO
/// handlers from starting. It might be better in the future to send the
/// error to the surface thread and let the apprt deal with it in some way
/// but this works for now. Without this, the user would just see a blank
/// terminal window.
fn showStartError(gpa: Allocator, io: *termio.Termio, err: anyerror) void {
    // Use an arena to simplify memory management below
    var arena = ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    io.renderer_state.mutex.lockUncancelable(global.io());
    defer io.renderer_state.mutex.unlock(global.io());
    const t = io.renderer_state.terminal;

    // Hide the cursor
    t.modes.set(.cursor_visible, false);

    switch (err) {
        error.OpenptyFailed => {
            const str =
                \\Your system cannot allocate any more pty devices.
                \\
                \\Ghostty requires a pty device to launch a new terminal.
                \\This error is usually due to having too many terminal
                \\windows open or having another program that is using too
                \\many pty devices.
                \\
                \\Please free up some pty devices and try again.
            ;

            t.eraseDisplay(.complete, false);
            t.printString(str) catch {};
        },

        error.InputNotFound,
        error.InputFailed,
        => {
            const str =
                \\A configured `input` path was not found, was not readable,
                \\was too large, or the underlying pty failed to accept
                \\the write.
                \\
                \\Ghostty can't continue since it can't guarantee that
                \\initial terminal state will be as desired. Please review
                \\the value of `input` in your configuration file and
                \\ensure that all the path values exist and are readable.
            ;

            t.eraseDisplay(.complete, false);
            t.printString(str) catch {};
        },

        else => {
            const str = std.fmt.allocPrint(
                alloc,
                \\error starting IO thread: {}
                \\
                \\The underlying shell or command was unable to be started.
                \\This error is usually due to exhausting a system resource.
                \\If this looks like a bug, please report it.
                \\
                \\This terminal is non-functional. Please close it and try again.
            ,
                .{err},
            ) catch
                \\Out of memory. This terminal is non-functional. Please close it and try again.
            ;

            t.eraseDisplay(.complete, false);
            t.printString(str) catch {};
        },
    }
}

fn threadMain_(self: *Thread, io: *termio.Termio) !void {
    defer log.debug("IO thread exited", .{});

    // Right now, on Darwin, `std.Thread.setName` can only name the current
    // thread, and we have no way to get the current thread from within it,
    // so instead we use this code to name the thread instead.
    if (builtin.os.tag.isDarwin()) {
        internal_os.macos.pthread_setname_np(&"io".*);
    }

    // Setup our crash metadata
    crash.sentry.thread_state = .{
        .type = .io,
        .surface = io.surface_mailbox.surface,
    };
    defer crash.sentry.thread_state = null;

    // Get the mailbox. This must be an SPSC mailbox for threading.
    const mailbox = switch (io.mailbox) {
        .spsc => |*v| v,
        // else => return error.TermioUnsupportedMailbox,
    };

    // This is the data sent to xev callbacks. We want a pointer to both
    // ourselves and the thread data so we can thread that through (pun intended).
    var cb: CallbackData = .{ .self = self, .io = io };

    // Run our thread start/end callbacks. This allows the implementation
    // to hook into the event loop as needed. The thread data is created
    // on the stack here so that it has a stable pointer throughout the
    // lifetime of the thread.
    try io.threadEnter(self, &cb.data);
    defer cb.data.deinit();
    defer io.threadExit(&cb.data);

    // Start the async handlers.
    mailbox.wakeup.wait(&self.loop.own, &self.wakeup_c, CallbackData, &cb, wakeupCallback);
    self.stop.?.wait(&self.loop.own, &self.stop_c, CallbackData, &cb, stopCallback);

    // Run
    log.debug("starting IO thread", .{});
    defer log.debug("starting IO thread shutdown", .{});
    try self.loop.own.run(.until_done);
}

/// This is the data passed to xev callbacks on the thread.
const CallbackData = struct {
    self: *Thread,
    io: *termio.Termio,
    data: termio.Termio.ThreadData = undefined,
};

/// Drain the mailbox, handling all the messages in our terminal implementation.
fn drainMailbox(
    self: *Thread,
    cb: *CallbackData,
) !void {
    // We assert when starting the thread that this is the state
    const mailbox = cb.io.mailbox.spsc.queue;
    const io = cb.io;
    const data = &cb.data;

    // If we're draining, we just drain the mailbox and return.
    if (self.flags.drain) {
        while (mailbox.pop(global.io())) |msg| msg.deinit();
        return;
    }

    // This holds the mailbox lock for the duration of the drain. The
    // expectation is that all our message handlers will be non-blocking
    // ENOUGH to not mess up throughput on producers.
    var redraw: bool = false;
    while (mailbox.pop(global.io())) |message| {
        // If we have a message we always redraw
        redraw = true;

        log.debug("mailbox message={s}", .{@tagName(message)});
        switch (message) {
            .color_scheme_report => |v| try io.colorSchemeReport(data, v.force),
            .visibility_report => |v| try io.visibilityReport(
                data,
                v.visible,
                v.force,
            ),
            .crash => @panic("crash request, crashing intentionally"),
            .change_config => |config| {
                defer config.alloc.destroy(config.ptr);
                try io.changeConfig(data, config.ptr);
            },
            .inspector => |v| self.flags.has_inspector = v,
            .resize => |v| self.handleResize(cb, v),
            .size_report => |v| try io.sizeReport(data, v),
            .clear_screen => |v| try io.clearScreen(data, v.history),
            .scroll_viewport => |v| io.scrollViewport(v),
            .scroll_wheel => |v| io.scrollWheel(data, v),
            .selection_scroll => |v| {
                if (v) {
                    self.startScrollTimer(cb);
                } else {
                    self.stopScrollTimer();
                }
            },
            .jump_to_prompt => |v| try io.jumpToPrompt(v),
            .kitty_clipboard_grant_read => |v| {
                defer v.alloc.free(v.pw);
                try io.kittyClipboardGrant(v.pw, .read);
            },
            .kitty_clipboard_grant_write => |v| {
                defer v.alloc.free(v.pw);
                try io.kittyClipboardGrant(v.pw, .write);
            },
            .start_synchronized_output => self.startSynchronizedOutput(cb),
            .linefeed_mode => |v| self.flags.linefeed_mode = v,
            .focused => |v| try io.focusGained(data, v),
            .write_small => |v| try io.queueWrite(
                data,
                v.data[0..v.len],
                self.flags.linefeed_mode,
            ),
            .write_stable => |v| try io.queueWrite(
                data,
                v,
                self.flags.linefeed_mode,
            ),
            .write_alloc => |v| {
                defer v.alloc.free(v.data);
                try io.queueWrite(
                    data,
                    v.data,
                    self.flags.linefeed_mode,
                );
            },
        }
    }

    // Trigger a redraw after we've drained so we don't waste cyces
    // messaging a redraw.
    if (redraw) {
        try io.renderer_wakeup.notify();
    }
}

fn startSynchronizedOutput(self: *Thread, cb: *CallbackData) void {
    self.sync_reset.reset(
        self.eventLoop(),
        &self.sync_reset_c,
        &self.sync_reset_cancel_c,
        sync_reset_ms,
        CallbackData,
        cb,
        syncResetCallback,
    );
}

fn handleResize(self: *Thread, cb: *CallbackData, resize: renderer.Size) void {
    self.coalesce_data.resize = resize;

    // If the timer is already active we just return. In the future we want
    // to reset the timer up to a maximum wait time but for now this ensures
    // relatively smooth resizing.
    if (self.coalesce_c.state() == .active) return;

    self.coalesce.reset(
        self.eventLoop(),
        &self.coalesce_c,
        &self.coalesce_cancel_c,
        Coalesce.min_ms,
        CallbackData,
        cb,
        coalesceCallback,
    );
}

fn syncResetCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        error.Canceled => {},
        else => {
            log.warn("error during sync reset callback err={}", .{err});
            return .disarm;
        },
    };

    const cb = cb_ orelse return .disarm;
    cb.io.resetSynchronizedOutput();
    return .disarm;
}

fn coalesceCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        error.Canceled => {},
        else => {
            log.warn("error during coalesce callback err={}", .{err});
            return .disarm;
        },
    };

    const cb = cb_ orelse return .disarm;

    if (cb.self.coalesce_data.resize) |v| {
        cb.self.coalesce_data.resize = null;
        cb.io.resize(&cb.data, v) catch |err| {
            log.warn("error during resize err={}", .{err});
        };
    }

    return .disarm;
}

fn wakeupCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.err("error in wakeup err={}", .{err});
        return .rearm;
    };

    // When we wake up, we check the mailbox. Mailbox producers should
    // wake up our thread after publishing.
    const cb = cb_ orelse return .rearm;
    cb.self.drainMailbox(cb) catch |err|
        log.err("error draining mailbox err={}", .{err});

    return .rearm;
}

fn stopCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    cb_.?.self.loop.own.stop();
    return .disarm;
}

fn startScrollTimer(self: *Thread, cb: *CallbackData) void {
    self.scroll_active = true;

    switch (self.scroll_c.state()) {
        // If it is already active, e.g. startScrollTimer is called multiple
        // times, then we just return. We can't simply check `scroll_active`
        // because its possible that `stopScrollTimer` was called but there
        // was no loop tick between then and now to halt out completion.
        .active => return,

        // If the completion is not active then we need to start it.
        .dead => self.scroll.run(
            self.eventLoop(),
            &self.scroll_c,
            selection_scroll_ms,
            CallbackData,
            cb,
            selectionScrollCallback,
        ),
    }
}

fn stopScrollTimer(self: *Thread) void {
    // This will stop the scrolling on the next iteration.
    self.scroll_active = false;
}

fn selectionScrollCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        error.Canceled => {},
        else => {
            log.warn("error during selection scroll callback err={}", .{err});
            return .disarm;
        },
    };

    const cb = cb_ orelse return .disarm;
    const self = cb.self;

    // Send the tick to the main surface
    _ = cb.io.surface_mailbox.push(
        .{ .selection_scroll_tick = self.scroll_active },
        .{ .instant = {} },
    );

    if (self.scroll_active) self.scroll.run(
        self.eventLoop(),
        &self.scroll_c,
        selection_scroll_ms,
        CallbackData,
        cb,
        selectionScrollCallback,
    );

    return .disarm;
}
