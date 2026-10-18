//! A render-only reflow of a host-locked terminal to the grid that fits
//! the view (`ghostty_surface_set_reflow_preview`).
//!
//! A MANUAL_MIRROR surface never reflows by itself: its grid follows the
//! owner's (`ghostty_surface_set_grid`) and the owner's snapshot after
//! each resize. While the view is resized faster than the owner answers,
//! the renderer draws this preview instead of the live terminal: a copy
//! of the live terminal's renderable state and newest history, reflowed
//! with the same `Terminal.resize` that the owner runs. The live terminal
//! is never changed. When the owner's grid reaches the view's grid, the
//! live terminal shows the same rows and the preview ends.
//!
//! The preview is rebuilt at most once per frame, only when the view's
//! grid or the live terminal changed. The live terminal's dirty state is
//! read by a second render state (`watch`), so the work under the
//! terminal lock grows with the screen and the copied rows, never with
//! the history. The reflow runs without the lock.
//!
//! No preview (the live terminal is drawn, clipped or padded): the
//! alternate screen (a full-screen program redraws itself), Kitty images
//! on the screen, a viewport scrolled into history, and a grid that
//! already fits.
const ReflowPreview = @This();

const std = @import("std");
const global = @import("../global.zig");
const renderer = @import("../renderer.zig");
const terminalpkg = @import("../terminal/main.zig");
const Allocator = std.mem.Allocator;
const Terminal = terminalpkg.Terminal;

const log = std.log.scoped(.reflow_preview);

/// History rows copied above the screen, beyond what a reflow to the
/// target grid can pull into the screen: covers a logical line cut at
/// the top of the copy.
const margin_rows = 64;

/// The reflowed copy, owned by the renderer thread. Null while the live
/// terminal is drawn.
terminal: ?Terminal = null,

/// The grid `terminal` was reflowed to.
grid: renderer.GridSize = .{},

/// The live terminal's dirty state since the preview was built.
watch: terminalpkg.RenderState = .empty,

/// True when the last frame drew the preview.
drawn: bool = false,

/// The grid of the terminal the last frame drew (the preview's or the live
/// terminal's), `cols << 16 | rows`; 0 before the first frame. Any thread
/// reads it (`ghostty_surface_drawn_grid`).
drawn_grid: std.atomic.Value(u32) = .init(0),

pub fn deinit(self: *ReflowPreview, alloc: Allocator) void {
    if (self.terminal) |*t| t.deinit(alloc);
    self.watch.deinit(alloc);
    self.* = undefined;
}

/// Whether `live` needs a preview to fill `fit`. Caller holds the
/// terminal lock.
pub fn wanted(live: *const Terminal, fit: renderer.GridSize) bool {
    if (fit.columns == 0 or fit.rows == 0) return false;
    if (live.cols == fit.columns and live.rows == fit.rows) return false;
    if (live.screens.active_key != .primary) return false;
    const screen = live.screens.active;
    if (screen.pages.viewport != .active) return false;
    if (screen.kitty_images.images.count() != 0) return false;
    return true;
}

/// Bring the preview up to date for this frame. Takes the terminal lock
/// for the change check and the copy only. On any failure the preview
/// ends and the live terminal is drawn.
pub fn update(
    self: *ReflowPreview,
    alloc: Allocator,
    state: *renderer.State,
    enabled: bool,
    fit: renderer.GridSize,
) void {
    if (!enabled and self.terminal == null) return;
    var copy: Terminal = copy: {
        state.mutex.lockUncancelable(global.io());
        defer state.mutex.unlock(global.io());

        if (!enabled or !wanted(state.terminal, fit)) {
            self.end(alloc);
            return;
        }

        const grid_changed = self.terminal == null or
            self.grid.columns != fit.columns or
            self.grid.rows != fit.rows;

        // The watch consumes the live terminal's dirty flags while the
        // preview is drawn; `end` makes the live render state rebuild.
        self.watch.beginUpdate(alloc, state.terminal) catch {
            self.end(alloc);
            return;
        };
        const live_changed = self.watch.dirty != .false;
        self.watch.endUpdate();
        if (!grid_changed and !live_changed) return;

        break :copy snapshot(alloc, state.terminal, fit) catch |err| {
            log.warn("reflow preview copy failed err={}", .{err});
            self.end(alloc);
            return;
        };
    };

    // The owner's prompt redraw comes as output after its own resize;
    // the preview keeps the prompt it has instead of clearing it.
    copy.flags.shell_redraws_prompt = .false;
    copy.resize(alloc, .{
        .cols = fit.columns,
        .rows = fit.rows,
        .reflow = true,
    }) catch |err| {
        log.warn("reflow preview resize failed err={}", .{err});
        copy.deinit(alloc);
        state.mutex.lockUncancelable(global.io());
        defer state.mutex.unlock(global.io());
        self.end(alloc);
        return;
    };
    copy.flags.dirty.clear = true;

    if (self.terminal) |*old| old.deinit(alloc);
    self.terminal = copy;
    self.grid = fit;
}

/// The terminal to draw this frame: the preview while it is current for
/// `live` and `fit`, else `live`. Caller holds the terminal lock. A
/// change of source makes the drawn terminal fully dirty.
pub fn source(
    self: *ReflowPreview,
    live: *Terminal,
    fit: renderer.GridSize,
) *Terminal {
    const use = self.terminal != null and
        self.grid.columns == fit.columns and
        self.grid.rows == fit.rows and
        wanted(live, fit);
    defer self.drawn = use;
    const t: *Terminal = if (use) &self.terminal.? else live;
    if (use != self.drawn) t.flags.dirty.clear = true;
    self.drawn_grid.store(@as(u32, t.cols) << 16 | t.rows, .release);
    return t;
}

/// Drop the preview. Caller holds the terminal lock.
fn end(self: *ReflowPreview, alloc: Allocator) void {
    if (self.terminal) |*t| t.deinit(alloc);
    self.terminal = null;
    self.grid = .{};
    // The next preview starts from a full watch update.
    self.watch.deinit(alloc);
    self.watch = .empty;
}

/// A copy of `live` that a reflow to `fit` can fill: the READY state
/// (both screens, modes, colors, cursor) and the newest history rows the
/// reflow needs. Caller holds the terminal lock.
fn snapshot(alloc: Allocator, live: *const Terminal, fit: renderer.GridSize) !Terminal {
    const snap = terminalpkg.snapshot;

    var bytes: std.Io.Writer.Allocating = .init(alloc);
    defer bytes.deinit();
    {
        var stream: snap.record.Writer = .init(alloc, &bytes.writer);
        defer stream.deinit();
        try snap.envelope.encode(stream.writer());
        try snap.terminal.encode(live, &stream);
        try snap.screen.encode(live.screens.get(.primary).?, .primary, &stream);
        if (live.screens.get(.alternate)) |alternate| {
            try snap.screen.encode(alternate, .alternate, &stream);
        }
        try snap.continuation.encode(.ground, &stream);
        try snap.checkpoint.encode(.ready, &stream);
    }

    var reader: std.Io.Reader = .fixed(bytes.written());
    var decoder: snap.Decoder = .init(&reader);
    var decoded = try decoder.ready(alloc, global.io(), .{ .max_continuation_bytes = 0 });
    defer decoded.deinit(alloc);
    var copy = decoded.toOwned();
    errdefer copy.deinit(alloc);

    // Rows of the new screen come from at most ceil(new cols / old cols)
    // old rows each (one logical line), so this many old rows above the
    // screen fill any reflow to `fit`, including rows a taller grid pulls
    // from history.
    const widen = std.math.divCeil(usize, fit.columns, live.cols) catch 1;
    const need = @as(usize, fit.rows) * @max(widen, 1) + margin_rows;
    copy.setScrollbackMaxLines(need);
    const primary = copy.screens.get(.primary).?;
    const seam = primary.pages.total_rows - primary.pages.rows;
    _ = try primary.pages.prependHistoryFrom(
        alloc,
        &live.screens.get(.primary).?.pages,
        seam,
    );
    return copy;
}
