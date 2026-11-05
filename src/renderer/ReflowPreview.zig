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
//! read by a second render state (`watch`). Under the terminal lock the
//! work grows with the screen and the copied rows, never with the
//! history; the reflow runs without the lock.
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
/// (demand-aware, like the frame update) for the change check and the
/// copy only. On any failure the preview ends and the live terminal is
/// drawn.
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

    var copy: Terminal = copy: {
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
        if (!grid_changed and !live_changed) return;

        break :copy snapshot(alloc, state.terminal, fit) catch |err| {
            log.warn("reflow preview copy failed err={}", .{err});
            self.end(alloc);
            return;
        };
    };

    reflow(alloc, &copy, fit) catch |err| {
        log.warn("reflow preview resize failed err={}", .{err});
        copy.deinit(alloc);
        // Only the renderer thread uses the preview terminal; the watch
        // is reset at the next `end` under the lock.
        if (self.terminal) |*old| old.deinit(alloc);
        self.terminal = null;
        self.grid = .{};
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
    var copy = snapshot(alloc, live, fit) catch |err| {
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
fn reflow(alloc: Allocator, copy: *Terminal, fit: renderer.GridSize) !void {
    copy.flags.shell_redraws_prompt = .false;
    try copy.resize(alloc, .{
        .cols = fit.columns,
        .rows = fit.rows,
        .reflow = true,
    });
    copy.flags.dirty.clear = true;
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
    // Not in GHOSTSNP v1; the reflow must pull history as the owner does.
    copy.flags.resize_pull_scrollback = live.flags.resize_pull_scrollback;

    // A new row starts anywhere in an old row and spans at most
    // ceil(new cols / old cols) + 1 old rows of one logical line, so this
    // many old rows above the screen fill any reflow to `fit`, including
    // rows a taller grid pulls from history.
    const widen = std.math.divCeil(usize, fit.columns, live.cols) catch 1;
    const need = @as(usize, fit.rows) * (widen + 1) + margin_rows;

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

test "reflow preview: per-frame cost of a 200x60 screen" {
    const alloc = testing.allocator;
    const cols = 200;
    const rows = 60;
    var live = try Terminal.init(global.io(), alloc, .{
        .cols = cols,
        .rows = rows,
        .max_scrollback_bytes = null,
    });
    defer live.deinit(alloc);
    // A busy screen: 2000 lines of history and a full screen of long
    // lines (each wraps, so every frame re-wraps every row) with styles.
    {
        var line: [450]u8 = undefined;
        for (0..2060) |i| {
            for (&line, 0..) |*ch, j| ch.* = @intCast('a' + (i + j) % 26);
            try live.setAttribute(.bold);
            try live.setAttribute(.{ .@"8_fg" = @enumFromInt(@as(u8, @intCast(i % 8))) });
            const n = 120 + (i * 37) % 330;
            try live.printString(line[0..n]);
            try live.setAttribute(.unset);
            try live.printString("\n");
        }
    }

    var mutex: std.Io.Mutex = .init;
    var state: renderer.State = .{ .mutex = &mutex, .terminal = &live };
    var preview: ReflowPreview = .{};
    defer preview.deinit(alloc);

    // A drag: one new width per frame, 200 down to 121 and back, and a
    // height change every 8 frames. Each frame rebuilds the preview.
    const frame_count = 160;
    var times: [frame_count]u64 = undefined;
    var locked: [frame_count]u64 = undefined;
    for (0..frame_count) |i| {
        const step: u16 = @intCast(if (i < 80) i else 159 - i);
        const fit: renderer.GridSize = .{
            .columns = cols - 1 - step,
            .rows = rows - @as(u16, @intCast((i / 8) % 4)),
        };
        const t_start = std.Io.Timestamp.now(global.io(), .awake);
        preview.update(alloc, &state, true, fit);
        const t_mid = std.Io.Timestamp.now(global.io(), .awake);
        state.lockDemand(global.io());
        const drawn = preview.source(alloc, true, state.terminal, fit);
        state.unlockDemand(global.io());
        const t_end = std.Io.Timestamp.now(global.io(), .awake);
        try testing.expectEqual(fit.columns, drawn.cols);
        times[i] = @intCast(t_start.durationTo(t_end).toNanoseconds());
        locked[i] = @intCast(t_mid.durationTo(t_end).toNanoseconds());
    }
    // Live terminal untouched by the whole drag.
    try testing.expectEqual(@as(u16, cols), live.cols);
    try testing.expectEqual(@as(u16, rows), live.rows);

    std.mem.sort(u64, &times, {}, std.sort.asc(u64));
    std.mem.sort(u64, &locked, {}, std.sort.asc(u64));
    const p50 = times[frame_count / 2];
    const p95 = times[frame_count * 95 / 100];
    const max = times[frame_count - 1];
    std.debug.print(
        "reflow preview cost 200x60 ({s}): per frame p50 {d} us, p95 {d} us, max {d} us; source (under lock) p95 {d} us\n",
        .{ @tagName(builtin.mode), p50 / 1000, p95 / 1000, max / 1000, locked[frame_count * 95 / 100] / 1000 },
    );
    // The budget (cmux-ad m18): well under 1 ms per frame on an M-series
    // Mac. Only an optimized build measures it; Debug only prints.
    if (builtin.mode != .Debug) try testing.expect(p95 < 1 * std.time.ns_per_ms);
}
