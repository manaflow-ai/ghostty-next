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
