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
//! live terminal is drawn again.
//!
//! The preview is rebuilt at most once per frame, only when the view's
//! grid or the live terminal changed. The live terminal's dirty state is
//! read by a second render state (`watch`). The live terminal is copied
//! under the terminal lock only when it changed (`base`, not reflowed):
//! a frame whose only change is the grid (each frame of a resize
//! gesture) re-wraps a copy of `base`, with no lock held. Under the lock
//! the work grows with the screen and the copied rows, never with the
//! history.
//!
//! What the preview cannot predict: the owner clears a prompt that its
//! shell redraws after the resize, while the preview keeps and reflows
//! it, so prompt rows can differ until the shell's redraw arrives.
//! Selection, search highlights and Kitty images are not drawn on the
//! preview; mouse hit tests use the live grid.
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

/// History rows copied beyond what a reflow to the target grid can pull
/// into the screen: covers a logical line that starts above the copy.
const margin_rows = 64;

/// The reflowed copy, owned by the renderer thread. Null while the live
/// terminal is drawn.
terminal: ?Terminal = null,

/// The grid `terminal` was reflowed to.
grid: renderer.GridSize = .{},

/// A copy of the live terminal as it was at its last change, not
/// reflowed, owned by the renderer thread: each new grid re-wraps a copy
/// of it off the lock. Null while no preview is drawn.
base: ?Terminal = null,

/// The history rows `base` holds enough of (`historyNeed`).
base_need: usize = 0,

/// The live terminal's dirty state since the preview was built.
watch: terminalpkg.RenderState = .empty,

/// The `State.color_config_epoch` of the last copy: a config color change
/// copies the live terminal again.
color_config_epoch: u32 = 0,

/// The watch consumed the live terminal's dirty flags since the live
/// terminal was last drawn: drawing it again needs a full rebuild.
live_flags_consumed: bool = false,

/// The last frame's `wanted` result and fit grid: a frame with the same
/// fit grid, no preview and no want skips the terminal lock.
wanted_last: bool = false,
fit_last: renderer.GridSize = .{},

/// The fit grid of the last failed build in `source`: not retried under
/// the lock until the fit grid changes (`update` retries off the lock).
failed_fit: renderer.GridSize = .{},

/// The grid of the terminal the last frame drew (the preview's or the live
/// terminal's), `cols << 16 | rows`; 0 before the first frame. Any thread
/// reads it (`ghostty_surface_drawn_grid`).
drawn_grid: std.atomic.Value(u32) = .init(0),

/// Copies of the live terminal taken under the terminal lock (tests,
/// `ghostty-bench +reflow-preview`). Renderer thread only.
locked_copies: u64 = 0,

pub fn deinit(self: *ReflowPreview, alloc: Allocator) void {
    if (self.terminal) |*t| t.deinit(alloc);
    if (self.base) |*t| t.deinit(alloc);
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
/// (demand-aware, like the frame update) for the change check, and for a
/// copy of the live terminal only when it changed since `base` was
/// taken. The re-wrap at a new grid runs off the lock. On any failure
/// the preview ends and the live terminal is drawn.
pub fn update(
    self: *ReflowPreview,
    alloc: Allocator,
    state: *renderer.State,
    enabled: bool,
    fit: renderer.GridSize,
) void {
    if (self.terminal == null) {
        if (!enabled) return;
        if (!self.wanted_last and
            self.fit_last.columns == fit.columns and
            self.fit_last.rows == fit.rows) return;
    }

    {
        state.lockDemand(global.io());
        defer state.unlockDemand(global.io());

        // Frames are held (synchronized output, a restore between its
        // swaps): the terminal is not in a state to copy.
        if (!state.renderable()) return;

        if (!enabled or !wanted(state.terminal, fit)) {
            self.end(alloc);
            return;
        }

        const grid_changed = self.terminal == null or
            self.grid.columns != fit.columns or
            self.grid.rows != fit.rows;

        // The watch consumes the live terminal's dirty flags while the
        // preview is drawn; `source` makes the live render state rebuild
        // when the live terminal is drawn again.
        self.live_flags_consumed = true;
        self.watch.beginUpdate(alloc, state.terminal) catch {
            self.end(alloc);
            return;
        };
        // A config color change sets no dirty flag (the live cells keep
        // color references, ColorBlend): copy again so the preview has
        // the new colors.
        const colors_changed = state.color_config_epoch != self.color_config_epoch;
        self.color_config_epoch = state.color_config_epoch;
        const live_changed = self.watch.dirty != .false or colors_changed;
        self.watch.endUpdate();
        // The caller resets the dirty state it handled (RenderState.dirty):
        // without this, every frame after the first saw a change and
        // copied the live terminal under the lock again.
        self.watch.dirty = .false;
        if (!grid_changed and !live_changed) return;

        // `base` still holds the live terminal: the new grid is re-wrapped
        // from it after the lock is released.
        const live = state.terminal;
        const need = historyNeed(live.cols, fit);
        const base_current = if (self.base) |*b|
            !live_changed and b.cols == live.cols and b.rows == live.rows and self.base_need >= need
        else
            false;
        if (!base_current) {
            self.locked_copies += 1;
            const fresh = snapshot(alloc, live, need) catch |err| {
                log.warn("reflow preview copy failed err={}", .{err});
                self.end(alloc);
                return;
            };
            if (self.base) |*old| old.deinit(alloc);
            self.base = fresh;
            self.base_need = need;
        }
    }

    // Off the lock: `base` belongs to this thread.
    var copy = snapshot(alloc, &self.base.?, historyNeed(self.base.?.cols, fit)) catch |err| {
        log.warn("reflow preview copy failed err={}", .{err});
        self.dropDrawn(alloc);
        return;
    };

    reflow(alloc, &copy, fit) catch |err| {
        log.warn("reflow preview resize failed err={}", .{err});
        copy.deinit(alloc);
        self.dropDrawn(alloc);
        return;
    };

    if (self.terminal) |*old| old.deinit(alloc);
    self.terminal = copy;
    self.grid = fit;
}

/// The terminal to draw this frame: the preview while it is current for
/// `live` and `fit`, else `live`. Caller holds the terminal lock. Drawing
/// the live terminal after the watch consumed its dirty flags rebuilds
/// it fully.
///
/// `update` builds the preview off the lock when the fit grid changed.
/// A want that starts with the same fit grid (back at the bottom, the
/// last image gone, the alternate screen left, the owner moved the grid)
/// is built here under the lock, so no frame waits for the next one.
pub fn source(
    self: *ReflowPreview,
    alloc: Allocator,
    enabled: bool,
    live: *Terminal,
    fit: renderer.GridSize,
) *Terminal {
    const want = enabled and wanted(live, fit);
    self.wanted_last = want;
    self.fit_last = fit;
    var current = self.terminal != null and
        self.grid.columns == fit.columns and
        self.grid.rows == fit.rows;
    if (want and !current and
        !(self.failed_fit.columns == fit.columns and self.failed_fit.rows == fit.rows))
    {
        current = self.buildLocked(alloc, live, fit);
        if (!current) self.failed_fit = fit;
    }
    const use = want and current;
    const t: *Terminal = if (use) &self.terminal.? else live;
    if (!use and self.live_flags_consumed) {
        live.flags.dirty.clear = true;
        self.live_flags_consumed = false;
    }
    self.drawn_grid.store(@as(u32, t.cols) << 16 | t.rows, .release);
    return t;
}

/// Build the preview under the terminal lock. False on a failure.
fn buildLocked(self: *ReflowPreview, alloc: Allocator, live: *const Terminal, fit: renderer.GridSize) bool {
    self.locked_copies += 1;
    var copy = snapshot(alloc, live, historyNeed(live.cols, fit)) catch |err| {
        log.warn("reflow preview copy failed err={}", .{err});
        return false;
    };
    reflow(alloc, &copy, fit) catch |err| {
        log.warn("reflow preview resize failed err={}", .{err});
        copy.deinit(alloc);
        return false;
    };
    if (self.terminal) |*old| old.deinit(alloc);
    self.terminal = copy;
    self.grid = fit;
    return true;
}

/// Reflow `copy` to `fit` as the owner's resize does, keeping the prompt:
/// the owner's prompt redraw comes as output after its own resize.
/// Public for the benchmark (`ghostty-bench +reflow-preview`).
pub fn reflow(alloc: Allocator, copy: *Terminal, fit: renderer.GridSize) !void {
    copy.flags.shell_redraws_prompt = .false;
    try copy.resize(alloc, .{
        .cols = fit.columns,
        .rows = fit.rows,
        .reflow = true,
    });
    copy.flags.dirty.clear = true;
}

/// Drop the drawn preview after a failed build off the lock. Only the
/// renderer thread uses the preview terminals; the watch is reset at the
/// next `end` under the lock.
fn dropDrawn(self: *ReflowPreview, alloc: Allocator) void {
    if (self.terminal) |*old| old.deinit(alloc);
    self.terminal = null;
    self.grid = .{};
    if (self.base) |*old| old.deinit(alloc);
    self.base = null;
    self.base_need = 0;
}

/// Drop the preview. Caller holds the terminal lock.
fn end(self: *ReflowPreview, alloc: Allocator) void {
    if (self.terminal) |*t| t.deinit(alloc);
    self.terminal = null;
    self.grid = .{};
    if (self.base) |*t| t.deinit(alloc);
    self.base = null;
    self.base_need = 0;
    // The next preview starts from a full watch update.
    self.watch.deinit(alloc);
    self.watch = .empty;
}

/// The history rows above the screen that fill any reflow of a terminal
/// of `cols` columns to `fit`, including rows a taller grid pulls from
/// history. A new row starts anywhere in an old row and spans at most
/// ceil(new cols / old cols) + 1 old rows of one logical line. At least
/// a widening to twice the columns is covered, so the copy a preview
/// keeps (`base`) serves the grids of a whole gesture.
pub fn historyNeed(cols: u16, fit: renderer.GridSize) usize {
    const widen = @max(2, std.math.divCeil(usize, fit.columns, cols) catch 1);
    return @as(usize, fit.rows) * (widen + 1) + margin_rows;
}

/// A copy of `live`: the READY state (both screens, modes, colors,
/// cursor) and its newest `need` history rows (`historyNeed`). Caller
/// holds the terminal lock when `live` is the live terminal. Public for
/// the benchmark (`ghostty-bench +reflow-preview`).
pub fn snapshot(alloc: Allocator, live: *const Terminal, need: usize) !Terminal {
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
    // Not in GHOSTSNP v1; the reflow must pull history as the owner does.
    copy.flags.resize_pull_scrollback = live.flags.resize_pull_scrollback;

    // prependHistoryFrom copies whole source pages, newest first, and
    // stops at the first page over the line limit: the limit is the
    // history that the newest pages reaching `need` rows hold.
    const src = &live.screens.get(.primary).?.pages;
    const primary = copy.screens.get(.primary).?;
    const seam = primary.pages.total_rows - primary.pages.rows;
    const src_history = src.total_rows - src.rows;
    var rows: usize = 0;
    if (src_history > seam) {
        var it = src.pageIterator(
            .left_up,
            .{ .screen = .{} },
            .{ .screen = .{ .y = @intCast(src_history - seam - 1) } },
        );
        while (it.next()) |chunk| {
            rows += chunk.end - chunk.start;
            if (rows >= need) break;
        }
    }
    copy.setScrollbackMaxBytes(null);
    copy.setScrollbackMaxLines(seam + rows);
    _ = try primary.pages.prependHistoryFrom(alloc, src, seam);
    return copy;
}

const testing = std.testing;
const builtin = @import("builtin");

/// One renderer frame of the preview, as `generic.updateFrame` runs it:
/// `update` before the lock, then `source` under it. Returns the drawn
/// terminal (valid until the next frame).
fn testFrame(
    preview: *ReflowPreview,
    alloc: Allocator,
    state: *renderer.State,
    fit: renderer.GridSize,
) *Terminal {
    preview.update(alloc, state, true, fit);
    state.lockDemand(global.io());
    defer state.unlockDemand(global.io());
    return preview.source(alloc, true, state.terminal, fit);
}

/// The rows the frame draws, as text (soft wraps kept as row breaks).
fn testRows(alloc: Allocator, t: *Terminal) ![]const u8 {
    return t.plainString(alloc);
}

test "reflow preview: a preview size per frame re-wraps the drawn rows and leaves the live grid unchanged" {
    const alloc = testing.allocator;
    var live = try Terminal.init(global.io(), alloc, .{ .cols = 10, .rows = 4 });
    defer live.deinit(alloc);
    // One logical line of 20 cells: two rows at 10 columns.
    try live.printString("0123456789ABCDEFGHIJ");
    const live_before = try live.plainString(alloc);
    defer alloc.free(live_before);
    try testing.expectEqualStrings("0123456789\nABCDEFGHIJ", live_before);
    const live_total_rows = live.screens.active.pages.total_rows;

    var mutex: std.Io.Mutex = .init;
    var state: renderer.State = .{ .mutex = &mutex, .terminal = &live };
    var preview: ReflowPreview = .{};
    defer preview.deinit(alloc);

    // The frames of one resize gesture: a new pane size in each frame.
    const Frame = struct { cols: u16, rows: u16, drawn: []const u8 };
    const frames = [_]Frame{
        .{ .cols = 8, .rows = 4, .drawn = "01234567\n89ABCDEF\nGHIJ" },
        .{ .cols = 5, .rows = 4, .drawn = "01234\n56789\nABCDE\nFGHIJ" },
        .{ .cols = 7, .rows = 5, .drawn = "0123456\n789ABCD\nEFGHIJ" },
        .{ .cols = 20, .rows = 3, .drawn = "0123456789ABCDEFGHIJ" },
        .{ .cols = 12, .rows = 4, .drawn = "0123456789AB\nCDEFGHIJ" },
    };
    for (frames) |f| {
        const fit: renderer.GridSize = .{ .columns = f.cols, .rows = f.rows };
        const drawn = testFrame(&preview, alloc, &state, fit);

        // The frame draws the text re-wrapped at the frame's grid.
        try testing.expect(drawn != &live);
        try testing.expectEqual(f.cols, drawn.cols);
        try testing.expectEqual(f.rows, drawn.rows);
        const rows = try testRows(alloc, drawn);
        defer alloc.free(rows);
        try testing.expectEqualStrings(f.drawn, rows);
        // ghostty_surface_drawn_grid reports the frame's grid.
        const packed_grid = preview.drawn_grid.load(.acquire);
        try testing.expectEqual(@as(u32, f.cols) << 16 | f.rows, packed_grid);

        // The live terminal (the grid the PTY owner set, its rows and its
        // history) does not change: no resize reaches it.
        try testing.expectEqual(@as(u16, 10), live.cols);
        try testing.expectEqual(@as(u16, 4), live.rows);
        try testing.expectEqual(live_total_rows, live.screens.active.pages.total_rows);
        const live_now = try live.plainString(alloc);
        defer alloc.free(live_now);
        try testing.expectEqualStrings(live_before, live_now);
    }
}

test "reflow preview: a frame whose only change is the grid copies nothing under the terminal lock" {
    const alloc = testing.allocator;
    var live = try Terminal.init(global.io(), alloc, .{ .cols = 10, .rows = 4 });
    defer live.deinit(alloc);
    try live.printString("0123456789ABCDEFGHIJ");

    var mutex: std.Io.Mutex = .init;
    var state: renderer.State = .{ .mutex = &mutex, .terminal = &live };
    var preview: ReflowPreview = .{};
    defer preview.deinit(alloc);

    // The first frame of the gesture copies the live terminal once.
    _ = testFrame(&preview, alloc, &state, .{ .columns = 9, .rows = 4 });
    try testing.expectEqual(@as(u64, 1), preview.locked_copies);

    // Each later frame has a new grid and the same live terminal: the
    // re-wrap comes from the copy the preview holds, off the lock.
    for ([_]u16{ 8, 7, 6, 5, 6, 7 }) |c| {
        const drawn = testFrame(&preview, alloc, &state, .{ .columns = c, .rows = 4 });
        try testing.expectEqual(c, drawn.cols);
    }
    try testing.expectEqual(@as(u64, 1), preview.locked_copies);

    // Output changes the live terminal: the next frame copies it again.
    try live.printString("KL");
    {
        const drawn = testFrame(&preview, alloc, &state, .{ .columns = 8, .rows = 4 });
        const rows = try testRows(alloc, drawn);
        defer alloc.free(rows);
        try testing.expectEqualStrings("01234567\n89ABCDEF\nGHIJKL", rows);
    }
    try testing.expectEqual(@as(u64, 2), preview.locked_copies);
}

test "reflow preview: a real resize of the live terminal during a preview takes a fresh copy at the next frame" {
    const alloc = testing.allocator;
    var live = try Terminal.init(global.io(), alloc, .{ .cols = 10, .rows = 4 });
    defer live.deinit(alloc);
    try live.printString("0123456789ABCDEFGHIJ");

    var mutex: std.Io.Mutex = .init;
    var state: renderer.State = .{ .mutex = &mutex, .terminal = &live };
    var preview: ReflowPreview = .{};
    defer preview.deinit(alloc);

    // Frames of a drag: one copy, then re-wraps of the kept copy.
    _ = testFrame(&preview, alloc, &state, .{ .columns = 6, .rows = 4 });
    _ = testFrame(&preview, alloc, &state, .{ .columns = 7, .rows = 4 });
    try testing.expectEqual(@as(u64, 1), preview.locked_copies);

    // Mouse-up: the PTY owner applies a grid (set_grid resizes the live
    // terminal) that is not the next frame's grid, and the shell then
    // prints at that grid.
    try live.resize(alloc, .{ .cols = 8, .rows = 4, .reflow = true });
    try live.printString("KL");
    try testing.expectEqual(@as(u16, 8), live.cols);

    // The next frame (a grid that still differs from the live one) copies
    // the resized live terminal again and draws its text at the frame's
    // grid: never the copy taken before the resize.
    const drawn = testFrame(&preview, alloc, &state, .{ .columns = 6, .rows = 4 });
    try testing.expect(drawn != &live);
    try testing.expectEqual(@as(u16, 6), drawn.cols);
    try testing.expectEqual(@as(u64, 2), preview.locked_copies);
    const rows = try testRows(alloc, drawn);
    defer alloc.free(rows);

    // The reference: the resized live terminal (with "KL") reflowed to
    // the frame's grid on its own copy.
    var reference = try snapshot(alloc, &live, historyNeed(live.cols, .{ .columns = 6, .rows = 4 }));
    defer reference.deinit(alloc);
    try reflow(alloc, &reference, .{ .columns = 6, .rows = 4 });
    const expected = try testRows(alloc, &reference);
    defer alloc.free(expected);
    try testing.expectEqualStrings(expected, rows);
    try testing.expect(std.mem.indexOf(u8, rows, "KL") != null);
    try testing.expectEqual(@as(u16, 8), live.cols);
}

test "reflow preview: output during the gesture shows in the re-wrapped frame" {
    const alloc = testing.allocator;
    var live = try Terminal.init(global.io(), alloc, .{ .cols = 10, .rows = 4 });
    defer live.deinit(alloc);
    try live.printString("0123456789AB");

    var mutex: std.Io.Mutex = .init;
    var state: renderer.State = .{ .mutex = &mutex, .terminal = &live };
    var preview: ReflowPreview = .{};
    defer preview.deinit(alloc);

    const fit: renderer.GridSize = .{ .columns = 6, .rows = 4 };
    {
        const drawn = testFrame(&preview, alloc, &state, fit);
        const rows = try testRows(alloc, drawn);
        defer alloc.free(rows);
        try testing.expectEqualStrings("012345\n6789AB", rows);
    }
    // Output arrives at the live terminal between two frames of the same
    // size: the next frame draws it, re-wrapped.
    try live.printString("CD");
    {
        const drawn = testFrame(&preview, alloc, &state, fit);
        const rows = try testRows(alloc, drawn);
        defer alloc.free(rows);
        try testing.expectEqualStrings("012345\n6789AB\nCD", rows);
    }
    try testing.expectEqual(@as(u16, 10), live.cols);
}

test "reflow preview: the committed grid changes the live grid once and the live terminal is drawn again" {
    const alloc = testing.allocator;
    var live = try Terminal.init(global.io(), alloc, .{ .cols = 10, .rows = 4 });
    defer live.deinit(alloc);
    try live.printString("0123456789ABCDEFGHIJ");

    var mutex: std.Io.Mutex = .init;
    var state: renderer.State = .{ .mutex = &mutex, .terminal = &live };
    var preview: ReflowPreview = .{};
    defer preview.deinit(alloc);

    // Frames of a gesture: preview only.
    var last_preview_rows: ?[]const u8 = null;
    defer if (last_preview_rows) |r| alloc.free(r);
    for ([_]u16{ 9, 8, 7, 6 }) |c| {
        const drawn = testFrame(&preview, alloc, &state, .{ .columns = c, .rows = 4 });
        try testing.expect(drawn != &live);
        if (last_preview_rows) |r| alloc.free(r);
        last_preview_rows = try testRows(alloc, drawn);
        try testing.expectEqual(@as(u16, 10), live.cols);
    }

    // The coalesced commit: the PTY owner applies the last size once, and
    // the live terminal takes that grid (ghostty_surface_set_grid runs this
    // resize on a MANUAL_MIRROR surface).
    try live.resize(alloc, .{ .cols = 6, .rows = 4, .reflow = true });
    try testing.expectEqual(@as(u16, 6), live.cols);

    // The grid fits: the frame draws the live terminal, with the rows the
    // preview drew.
    const drawn = testFrame(&preview, alloc, &state, .{ .columns = 6, .rows = 4 });
    try testing.expect(drawn == &live);
    try testing.expect(preview.terminal == null);
    const rows = try testRows(alloc, drawn);
    defer alloc.free(rows);
    try testing.expectEqualStrings(last_preview_rows.?, rows);
}
