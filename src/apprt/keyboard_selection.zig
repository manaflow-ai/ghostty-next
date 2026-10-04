//! Selection helpers for an embedder's keyboard copy mode. Copy mode is a
//! selection: a one-cell selection is the copy cursor, and the upstream
//! `adjust_selection` binding action moves its end. These helpers place a
//! selection at a viewport cell, report the moving end in viewport
//! coordinates, and widen a selection to whole lines. They are pure over a
//! screen, so they are tested without a surface; the embedded apprt holds
//! the terminal lock and tracks the result with `setSelection`.
const std = @import("std");
const terminal = @import("../terminal/main.zig");

const Screen = terminal.Screen;
const Selection = terminal.Selection;
const grid_metrics = @import("grid_metrics.zig");

/// The moving end of a selection, in viewport cells.
pub const Endpoint = extern struct {
    /// Row relative to the viewport's top row: negative above the
    /// viewport, `rows` or more below it.
    row: i32,
    /// Column of the end cell's glyph lead.
    column: u16,
    /// 2 for a wide glyph, 1 otherwise.
    width_cells: u16,
    /// The end cell is visible.
    in_viewport: bool,
};

/// A one-cell selection at a visible cell (the copy cursor). A wide tail
/// or a spacer head resolves to the wide glyph. Null outside the viewport.
pub fn cellSelection(screen: *const Screen, column: u16, row: u16) ?Selection {
    if (column >= screen.pages.cols or row >= screen.pages.rows) return null;
    const pin = screen.pages.pin(.{ .viewport = .{ .x = column, .y = row } }) orelse return null;
    const cell = grid_metrics.canonicalCell(pin) orelse return null;
    return Selection.init(cell.pin, cell.pin, false);
}

/// Where the selection's moving end is relative to the viewport.
pub fn endpoint(screen: *const Screen, sel: Selection) Endpoint {
    const end = sel.end();
    const cell = grid_metrics.canonicalCell(end);
    const lead = if (cell) |c| c.pin else end;
    const top = screen.pages.pointFromPin(.screen, screen.pages.getTopLeft(.viewport)).?.screen.y;
    const y = screen.pages.pointFromPin(.screen, lead).?.screen.y;
    const row = std.math.cast(i32, @as(i64, @intCast(y)) - @as(i64, @intCast(top))) orelse
        (if (y < top) std.math.minInt(i32) else std.math.maxInt(i32));
    return .{
        .row = row,
        .column = @intCast(lead.x),
        .width_cells = if (cell) |c| c.width_cells else 1,
        .in_viewport = row >= 0 and row < screen.pages.rows,
    };
}

/// The selection widened to whole rows: the anchor (start) row and the
/// moving end's row, keeping the direction so `adjust` keeps moving the end.
pub fn linewise(screen: *const Screen, sel: Selection) Selection {
    const last: terminal.size.CellCountInt = screen.pages.cols - 1;
    var start = sel.start();
    var end = sel.end();
    const start_y = screen.pages.pointFromPin(.screen, start).?.screen.y;
    const end_y = screen.pages.pointFromPin(.screen, end).?.screen.y;
    const forward = start_y < end_y or (start_y == end_y and start.x <= end.x);
    if (forward) {
        start.x = 0;
        end.x = last;
    } else {
        start.x = last;
        end.x = 0;
    }
    return Selection.init(start, end, false);
}


test "keyboard selection: a cell selection resolves a wide tail to its lead" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 6, .rows = 2, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A橋B");

    const sel = cellSelection(&s, 2, 0).?;
    try testing.expectEqual(terminal.point.Point{ .screen = .{ .x = 1, .y = 0 } }, s.pages.pointFromPin(.screen, sel.start()).?);
    try testing.expect(sel.start().eql(sel.end()));
    const end = endpoint(&s, sel);
    try testing.expect(end.in_viewport);
    try testing.expectEqual(@as(u16, 1), end.column);
    try testing.expectEqual(@as(i32, 0), end.row);
    try testing.expectEqual(@as(u16, 2), end.width_cells);
}

test "keyboard selection: a cell outside the viewport is refused" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 4, .rows = 2, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try testing.expect(cellSelection(&s, 4, 0) == null);
    try testing.expect(cellSelection(&s, 0, 2) == null);
}

test "keyboard selection: the end row is relative to the viewport top" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 2, .max_scrollback_bytes = 10_000 });
    defer s.deinit();
    try s.testWriteString("one\ntwo\nthree\nfour");

    // Viewport shows "three" and "four"; select "two" one row above it.
    const two = s.pages.pin(.{ .screen = .{ .x = 0, .y = 1 } }).?;
    const above = endpoint(&s, Selection.init(two, two, false));
    try testing.expect(!above.in_viewport);
    try testing.expectEqual(@as(i32, -1), above.row);

    s.pages.scroll(.{ .top = {} });
    const visible = endpoint(&s, Selection.init(two, two, false));
    try testing.expect(visible.in_viewport);
    try testing.expectEqual(@as(i32, 1), visible.row);
}

test "keyboard selection: linewise widens to whole rows in both directions" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 4, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A1234\nB5678\nC1234");

    const forward = linewise(&s, Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 2, .y = 0 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
        false,
    ));
    try testing.expectEqual(terminal.point.Point{ .screen = .{ .x = 0, .y = 0 } }, s.pages.pointFromPin(.screen, forward.start()).?);
    try testing.expectEqual(terminal.point.Point{ .screen = .{ .x = 4, .y = 1 } }, s.pages.pointFromPin(.screen, forward.end()).?);

    const reverse = linewise(&s, Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 1, .y = 2 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
        false,
    ));
    try testing.expectEqual(terminal.point.Point{ .screen = .{ .x = 4, .y = 2 } }, s.pages.pointFromPin(.screen, reverse.start()).?);
    try testing.expectEqual(terminal.point.Point{ .screen = .{ .x = 0, .y = 1 } }, s.pages.pointFromPin(.screen, reverse.end()).?);
}

test "keyboard selection: adjust down then linewise keeps the anchor row" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 4, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A1234\nB5678\nC1234");

    var sel = linewise(&s, cellSelection(&s, 2, 0).?);
    sel.adjust(&s, .down);
    sel = linewise(&s, sel);
    try testing.expectEqual(terminal.point.Point{ .screen = .{ .x = 0, .y = 0 } }, s.pages.pointFromPin(.screen, sel.start()).?);
    try testing.expectEqual(terminal.point.Point{ .screen = .{ .x = 4, .y = 1 } }, s.pages.pointFromPin(.screen, sel.end()).?);
}
