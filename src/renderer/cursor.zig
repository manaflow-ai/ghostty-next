const std = @import("std");
const terminal = @import("../terminal/main.zig");
const size = @import("size.zig");

/// How long a blinking cursor shows, then hides, in milliseconds.
pub const blink_interval_ms = 600;

/// Available cursor styles for drawing that renderers must support.
/// This is a superset of terminal cursor styles since the renderer supports
/// some additional cursor states such as the hollow block.
pub const Style = enum {
    // Typical cursor input styles
    block,
    block_hollow,
    bar,
    underline,

    // Special cursor styles
    lock,

    /// Create a cursor style from the terminal style request.
    pub fn fromTerminal(term: terminal.CursorStyle) Style {
        return switch (term) {
            .bar => .bar,
            .block => .block,
            .block_hollow => .block_hollow,
            .underline => .underline,
        };
    }
};

pub const StyleOptions = struct {
    preedit: bool = false,
    focused: bool = false,
    blink_visible: bool = false,
};

/// Returns the cursor style to use for the current render state or null
/// if a cursor should not be rendered at all.
pub fn style(
    state: *const terminal.RenderState,
    opts: StyleOptions,
) ?Style {
    // Note the order of conditionals below is important. It represents
    // a priority system of how we determine what state overrides cursor
    // visibility and style.

    // The cursor must be visible in the viewport to be rendered.
    if (state.cursor.viewport == null) return null;

    // If we are in preedit, then we always show the block cursor. We do
    // this even if the cursor is explicitly not visible because it shows
    // an important editing state to the user.
    if (opts.preedit) return .block;

    // If we're at a password input its always a lock.
    if (state.cursor.password_input) return .lock;

    // If the cursor is explicitly not visible by terminal mode, we don't render.
    if (!state.cursor.visible) return null;

    // If we're not focused, our cursor is always visible so that
    // we can show the hollow box.
    if (!opts.focused) return .block_hollow;

    // If the cursor is blinking and our blink state is not visible,
    // then we don't show the cursor.
    if (state.cursor.blinking and !opts.blink_visible) return null;

    // Otherwise, we use whatever style the terminal wants.
    return .fromTerminal(state.cursor.visual_style);
}

/// Whether `style` shows the cursor only in a blink's visible phase: a
/// focused, visible, blinking cursor in the viewport. Such a cursor can
/// blink on its own layer, animated by the compositor, so the renderer
/// thread needs no blink timer. A preedit block, a lock and an unfocused
/// hollow block never blink.
pub fn blinks(
    state: *const terminal.RenderState,
    opts: StyleOptions,
) bool {
    if (state.cursor.viewport == null) return false;
    if (opts.preedit) return false;
    if (state.cursor.password_input) return false;
    if (!state.cursor.visible) return false;
    if (!opts.focused) return false;
    return state.cursor.blinking;
}

/// A rectangle of screen pixels, origin at the top left.
pub const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

/// The screen pixels the layer of a blinking cursor covers: its cell (two
/// for a wide character) and its glyph's box, which a bar can extend past
/// the cell, clipped to the screen. Grid coordinates start at the padding's
/// top-left corner (the renderer's projection). Null when none of it is on
/// the screen.
pub fn layerRect(
    grid_pos: [2]u16,
    wide: bool,
    cell: size.CellSize,
    padding: size.Padding,
    screen: size.ScreenSize,
    glyph_size: [2]u32,
    bearings: [2]i16,
) ?Rect {
    const cell_w: i64 = cell.width;
    const cell_h: i64 = cell.height;
    const cell_x = @as(i64, grid_pos[0]) * cell_w;
    const cell_y = @as(i64, grid_pos[1]) * cell_h;
    // The text shader's glyph box: x from the bearing, y from the cell's
    // top plus the cell height less the bearing.
    const glyph_x = cell_x + bearings[0];
    const glyph_y = cell_y + cell_h - bearings[1];
    const left = @min(cell_x, glyph_x) + padding.left;
    const top = @min(cell_y, glyph_y) + padding.top;
    const right = @max(cell_x + cell_w * @as(i64, if (wide) 2 else 1), glyph_x + glyph_size[0]) + padding.left;
    const bottom = @max(cell_y + cell_h, glyph_y + glyph_size[1]) + padding.top;
    const x0 = std.math.clamp(left, 0, screen.width);
    const y0 = std.math.clamp(top, 0, screen.height);
    const x1 = std.math.clamp(right, 0, screen.width);
    const y1 = std.math.clamp(bottom, 0, screen.height);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{
        .x = @intCast(x0),
        .y = @intCast(y0),
        .width = @intCast(x1 - x0),
        .height = @intCast(y1 - y0),
    };
}

test "cursor: only a focused visible blinking cursor blinks" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var term: terminal.Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    term.screens.active.cursor.cursor_style = .bar;
    term.modes.set(.cursor_blinking, true);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    // The blink phase does not matter: the layer runs it.
    try testing.expect(blinks(&state, .{ .focused = true, .blink_visible = true }));
    try testing.expect(blinks(&state, .{ .focused = true, .blink_visible = false }));
    try testing.expect(!blinks(&state, .{ .focused = false, .blink_visible = true }));
    try testing.expect(!blinks(&state, .{ .focused = true, .preedit = true }));

    term.modes.set(.cursor_blinking, false);
    try state.update(alloc, &term);
    try testing.expect(!blinks(&state, .{ .focused = true, .blink_visible = true }));

    term.modes.set(.cursor_blinking, true);
    term.modes.set(.cursor_visible, false);
    try state.update(alloc, &term);
    try testing.expect(!blinks(&state, .{ .focused = true, .blink_visible = true }));
}

test "cursor: a layer covers the cursor cell and its glyph, on the screen" {
    const testing = std.testing;
    const cell: size.CellSize = .{ .width = 10, .height = 20 };
    const padding: size.Padding = .{ .top = 4, .left = 6 };
    const screen: size.ScreenSize = .{ .width = 200, .height = 100 };

    // A block glyph that fills its cell.
    try testing.expectEqual(Rect{ .x = 36, .y = 44, .width = 10, .height = 20 }, layerRect(
        .{ 3, 2 },
        false,
        cell,
        padding,
        screen,
        .{ 10, 20 },
        .{ 0, 20 },
    ).?);

    // A wide cell is two columns.
    try testing.expectEqual(Rect{ .x = 36, .y = 44, .width = 20, .height = 20 }, layerRect(
        .{ 3, 2 },
        true,
        cell,
        padding,
        screen,
        .{ 20, 20 },
        .{ 0, 20 },
    ).?);

    // A bar drawn one pixel left of its cell widens the layer.
    try testing.expectEqual(Rect{ .x = 35, .y = 44, .width = 11, .height = 20 }, layerRect(
        .{ 3, 2 },
        false,
        cell,
        padding,
        screen,
        .{ 2, 20 },
        .{ -1, 20 },
    ).?);

    // Clipped at the screen's right edge; nothing past it.
    try testing.expectEqual(Rect{ .x = 196, .y = 4, .width = 4, .height = 20 }, layerRect(
        .{ 19, 0 },
        false,
        cell,
        padding,
        screen,
        .{ 10, 20 },
        .{ 0, 20 },
    ).?);
    try testing.expect(layerRect(.{ 30, 0 }, false, cell, padding, screen, .{ 10, 20 }, .{ 0, 20 }) == null);
}

test "cursor: default uses configured style" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var term: terminal.Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    term.screens.active.cursor.cursor_style = .bar;
    term.modes.set(.cursor_blinking, true);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    try testing.expect(style(&state, .{ .preedit = false, .focused = true, .blink_visible = true }) == .bar);
    try testing.expect(style(&state, .{ .preedit = false, .focused = false, .blink_visible = true }) == .block_hollow);
    try testing.expect(style(&state, .{ .preedit = false, .focused = false, .blink_visible = false }) == .block_hollow);
    try testing.expect(style(&state, .{ .preedit = false, .focused = true, .blink_visible = false }) == null);
}

test "cursor: blinking disabled" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var term = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    term.screens.active.cursor.cursor_style = .bar;
    term.modes.set(.cursor_blinking, false);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    try testing.expect(style(&state, .{ .focused = true, .blink_visible = true }) == .bar);
    try testing.expect(style(&state, .{ .focused = true, .blink_visible = false }) == .bar);
    try testing.expect(style(&state, .{ .focused = false, .blink_visible = true }) == .block_hollow);
    try testing.expect(style(&state, .{ .focused = false, .blink_visible = false }) == .block_hollow);
}

test "cursor: explicitly not visible" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var term = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    term.screens.active.cursor.cursor_style = .bar;
    term.modes.set(.cursor_visible, false);
    term.modes.set(.cursor_blinking, false);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    try testing.expect(style(&state, .{ .focused = true, .blink_visible = true }) == null);
    try testing.expect(style(&state, .{ .focused = true, .blink_visible = false }) == null);
    try testing.expect(style(&state, .{ .focused = false, .blink_visible = true }) == null);
    try testing.expect(style(&state, .{ .focused = false, .blink_visible = false }) == null);
}

test "cursor: always block with preedit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var term = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    // In any bool state
    try testing.expect(style(&state, .{ .preedit = true, .focused = false, .blink_visible = false }) == .block);
    try testing.expect(style(&state, .{ .preedit = true, .focused = true, .blink_visible = false }) == .block);
    try testing.expect(style(&state, .{ .preedit = true, .focused = true, .blink_visible = true }) == .block);
    try testing.expect(style(&state, .{ .preedit = true, .focused = false, .blink_visible = true }) == .block);

    // If we're scrolled though, then we don't show the cursor.
    for (0..100) |_| try term.index();
    term.scrollViewport(.{ .top = {} });
    try state.update(alloc, &term);

    // In any bool state
    try testing.expect(style(&state, .{ .preedit = true, .focused = false, .blink_visible = false }) == null);
    try testing.expect(style(&state, .{ .preedit = true, .focused = true, .blink_visible = false }) == null);
    try testing.expect(style(&state, .{ .preedit = true, .focused = true, .blink_visible = true }) == null);
    try testing.expect(style(&state, .{ .preedit = true, .focused = false, .blink_visible = true }) == null);
}
