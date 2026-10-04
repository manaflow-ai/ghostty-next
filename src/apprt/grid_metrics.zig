//! Grid geometry for ghostty_surface_grid_metrics, in the embedder's
//! logical (point) coordinates. Pure over a renderer size, a content scale
//! and a screen, so it is tested without a surface.
const std = @import("std");
const apprt = @import("../apprt.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");

// ghostty_surface_grid_metrics_s
pub const Metrics = extern struct {
    columns: u16,
    rows: u16,
    cursor_column: u16,
    cursor_row: u16,
    cursor_width_cells: u16,
    cursor_in_viewport: bool,
    cell_width: f64,
    cell_height: f64,
    padding_left: f64,
    padding_top: f64,
};

pub const Options = struct {
    /// The session host locked the grid (ghostty_surface_set_grid), so
    /// the terminal grid need not match the view's pixel grid.
    grid_locked: bool = false,
};

/// The glyph lead and width of the cell at `pin`; a wide tail or a
/// spacer head resolves to its wide glyph.
fn canonicalCursorCell(pin: terminal.Pin) ?struct {
    pin: terminal.Pin,
    width_cells: u16,
} {
    return switch (pin.rowAndCell().cell.wide) {
        .wide => .{ .pin = pin, .width_cells = 2 },
        .spacer_tail => .{ .pin = pin.left(1), .width_cells = 2 },
        .narrow => .{ .pin = pin, .width_cells = 1 },
        .spacer_head => cell: {
            var it = pin.cellIterator(.right_down, null);
            _ = it.next();
            const next = it.next() orelse return null;
            if (next.rowAndCell().cell.wide != .wide) return null;
            break :cell .{ .pin = next, .width_cells = 2 };
        },
    };
}

/// Grid metrics for an unlocked grid: the view's pixel grid must match
/// the terminal grid (a mismatch is a resize in flight).
pub fn computeUnlocked(
    size: renderer.Size,
    scale: apprt.ContentScale,
    screen: *terminal.Screen,
) ?Metrics {
    return compute(size, scale, screen, .{});
}

pub fn compute(
    size: renderer.Size,
    scale: apprt.ContentScale,
    screen: *terminal.Screen,
    options: Options,
) ?Metrics {
    const size_grid = size.grid();
    if (screen.pages.cols == 0 or
        screen.pages.rows == 0 or
        size.cell.width == 0 or
        size.cell.height == 0 or
        !std.math.isFinite(scale.x) or
        !std.math.isFinite(scale.y) or
        scale.x <= 0 or
        scale.y <= 0) return null;
    if (!options.grid_locked and
        (size_grid.columns != screen.pages.cols or
            size_grid.rows != screen.pages.rows)) return null;

    const cursor_cell = canonicalCursorCell(screen.cursor.page_pin.*);
    const cursor = if (cursor_cell) |cell|
        if (screen.pages.pointFromPin(.viewport, cell.pin)) |pt|
            if (pt.viewport.x < screen.pages.cols and
                pt.viewport.y < screen.pages.rows)
                pt
            else
                null
        else
            null
    else
        null;
    return .{
        .columns = @intCast(screen.pages.cols),
        .rows = @intCast(screen.pages.rows),
        .cursor_column = if (cursor) |pt| @intCast(pt.viewport.x) else 0,
        .cursor_row = if (cursor) |pt| @intCast(pt.viewport.y) else 0,
        .cursor_width_cells = if (cursor != null) cursor_cell.?.width_cells else 0,
        .cursor_in_viewport = cursor != null,
        .cell_width = @as(f64, @floatFromInt(size.cell.width)) / scale.x,
        .cell_height = @as(f64, @floatFromInt(size.cell.height)) / scale.y,
        .padding_left = @as(f64, @floatFromInt(size.padding.left)) / scale.x,
        .padding_top = @as(f64, @floatFromInt(size.padding.top)) / scale.y,
    };
}

test "grid metrics reject resize skew and report an offscreen cursor" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term = try terminal.Terminal.init(std.testing.io, alloc, .{
        .cols = 10,
        .rows = 2,
    });
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("one\r\ntwo\r\nthree\r\nfour\r\n");
    term.scrollViewport(.top);
    const screen = term.screens.active;

    const size: renderer.Size = .{
        .screen = .{ .width = 83, .height = 37 },
        .cell = .{ .width = 8, .height = 16 },
        .padding = .{ .left = 3, .top = 5 },
    };
    const snapshot = computeUnlocked(
        size,
        .{ .x = 2, .y = 2 },
        screen,
    ).?;
    try testing.expectEqual(@as(u16, 10), snapshot.columns);
    try testing.expectEqual(@as(u16, 2), snapshot.rows);
    try testing.expect(!snapshot.cursor_in_viewport);
    try testing.expectEqual(@as(u16, 0), snapshot.cursor_width_cells);
    try testing.expectEqual(@as(f64, 4), snapshot.cell_width);
    try testing.expectEqual(@as(f64, 8), snapshot.cell_height);
    try testing.expectEqual(@as(f64, 1.5), snapshot.padding_left);
    try testing.expectEqual(@as(f64, 2.5), snapshot.padding_top);

    var mismatched_size = size;
    mismatched_size.screen.width += size.cell.width;
    try testing.expect(computeUnlocked(
        mismatched_size,
        .{ .x = 2, .y = 2 },
        screen,
    ) == null);

    term.scrollViewport(.bottom);
    const active = computeUnlocked(
        size,
        .{ .x = 2, .y = 2 },
        screen,
    ).?;
    try testing.expect(active.cursor_in_viewport);
    try testing.expectEqual(@as(u16, 1), active.cursor_width_cells);
}

test "grid metrics canonicalize a wide-tail cursor" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term = try terminal.Terminal.init(std.testing.io, alloc, .{
        .cols = 6,
        .rows = 2,
    });
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("A橋B\x1b[1;3H");
    const cursor_pin = term.screens.active.cursor.page_pin.*;
    try testing.expectEqual(
        terminal.page.Cell.Wide.spacer_tail,
        cursor_pin.rowAndCell().cell.wide,
    );

    const snapshot = computeUnlocked(
        .{
            .screen = .{ .width = 51, .height = 37 },
            .cell = .{ .width = 8, .height = 16 },
            .padding = .{ .left = 3, .top = 5 },
        },
        .{ .x = 1, .y = 1 },
        term.screens.active,
    ).?;
    try testing.expect(snapshot.cursor_in_viewport);
    try testing.expectEqual(@as(u16, 1), snapshot.cursor_column);
    try testing.expectEqual(@as(u16, 0), snapshot.cursor_row);
    try testing.expectEqual(@as(u16, 2), snapshot.cursor_width_cells);
}

test "grid metrics resolve a spacer-head cursor to its wrapped glyph" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term = try terminal.Terminal.init(std.testing.io, alloc, .{
        .cols = 4,
        .rows = 3,
    });
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("ABC橋\x1b[1;4H");
    const cursor_pin = term.screens.active.cursor.page_pin.*;
    try testing.expectEqual(
        terminal.page.Cell.Wide.spacer_head,
        cursor_pin.rowAndCell().cell.wide,
    );

    const snapshot = computeUnlocked(
        .{
            .screen = .{ .width = 35, .height = 53 },
            .cell = .{ .width = 8, .height = 16 },
            .padding = .{ .left = 3, .top = 5 },
        },
        .{ .x = 1, .y = 1 },
        term.screens.active,
    ).?;
    try testing.expect(snapshot.cursor_in_viewport);
    try testing.expectEqual(@as(u16, 0), snapshot.cursor_column);
    try testing.expectEqual(@as(u16, 1), snapshot.cursor_row);
    try testing.expectEqual(@as(u16, 2), snapshot.cursor_width_cells);
}


test "grid metrics follow a host-locked grid that differs from the view" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term = try terminal.Terminal.init(std.testing.io, alloc, .{
        .cols = 10,
        .rows = 2,
    });
    defer term.deinit(alloc);
    const screen = term.screens.active;

    // The view fits 20x4 cells, but the session host locked the grid to
    // 10x2 (ghostty_surface_set_grid). Metrics describe the locked grid.
    const size: renderer.Size = .{
        .screen = .{ .width = 160, .height = 64 },
        .cell = .{ .width = 8, .height = 16 },
        .padding = .{ .left = 0, .top = 0 },
    };
    try testing.expect(computeUnlocked(
        size,
        .{ .x = 1, .y = 1 },
        screen,
    ) == null);
    const locked = compute(
        size,
        .{ .x = 1, .y = 1 },
        screen,
        .{ .grid_locked = true },
    ).?;
    try testing.expectEqual(@as(u16, 10), locked.columns);
    try testing.expectEqual(@as(u16, 2), locked.rows);
    try testing.expect(locked.cursor_in_viewport);
    try testing.expectEqual(@as(f64, 8), locked.cell_width);
}
