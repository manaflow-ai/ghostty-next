const std = @import("std");
const terminal = @import("../terminal/main.zig");
const math = @import("../math.zig");

/// The interval of one half of the cursor blink (shown or hidden).
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

/// Whether the cursor of `state` blinks: `style` shows it only in the
/// visible half of the blink.
pub fn blinks(
    state: *const terminal.RenderState,
    opts: StyleOptions,
) bool {
    var shown = opts;
    shown.blink_visible = true;
    var hidden = opts;
    hidden.blink_visible = false;
    return style(state, shown) != null and style(state, hidden) == null;
}

// External cursor (`ghostty_surface_config_s.cursor_external`). The embedder
// shows and blinks the cursor in a layer of its own, so a blink wakes no
// renderer and draws no frame. The renderer leaves the cursor out of its
// frames and, when the cursor moves or its cell changes, draws the cursor
// cell with its own pipelines into a target of the cell's size: the pixels
// of that cell in Ghostty's own frame. The blink is then an opacity
// animation of a layer, which Chromium runs in the compositor without a new
// frame from the renderer (cc/animation/keyframe_effect.cc).

/// `ghostty_cursor_cell_style_e`. If this is changed, update ghostty.h.
pub const CellStyle = enum(c_int) {
    block = 0,
    block_hollow = 1,
    bar = 2,
    underline = 3,
    lock = 4,

    pub fn fromStyle(s: Style) CellStyle {
        return switch (s) {
            .block => .block,
            .block_hollow => .block_hollow,
            .bar => .bar,
            .underline => .underline,
            .lock => .lock,
        };
    }
};

/// `ghostty_cursor_cell_s`: what the embedder shows. If this is changed,
/// update ghostty.h.
pub const Cell = extern struct {
    /// Increases with each published cell of a surface.
    serial: u64 = 0,
    /// The cursor cell's pixels (an IOSurfaceRef on macOS), `width` by
    /// `height`, premultiplied, in the colorspace of the surface's frames.
    /// Null when not `visible`, and when `unchanged`. Borrowed for the
    /// call: the embedder retains it to keep it.
    surface: ?*anyopaque = null,
    /// The cell (two for a wide character) in the surface's pixels, from
    /// the top-left corner of its frames.
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    column: u16 = 0,
    row: u16 = 0,
    style: CellStyle = .block,
    visible: bool = false,
    /// The embedder blinks the cursor: `blink_interval_ms` shown, then as
    /// long hidden, starting shown at each published cell.
    blinking: bool = false,
    /// The cell is the previous call's (`Publisher.restart`): the embedder
    /// keeps that surface and only starts the blink shown again, as
    /// Ghostty's own blink restarts on terminal output.
    unchanged: bool = false,
    blink_interval_ms: u32 = 0,
};

/// An embedder that shows the cursor itself (renderer.Options).
pub const External = struct {
    cb: Callback,
    userdata: ?*anyopaque,

    /// `ghostty_surface_cursor_cb`.
    pub const Callback = *const fn (?*anyopaque, *const Cell) callconv(.c) void;
    pub const Error = error{MissingCursorCallback};

    /// The external cursor of a surface config; refuses `enabled` without
    /// a callback.
    pub fn fromConfig(
        enabled: bool,
        cb: ?Callback,
        userdata: ?*anyopaque,
    ) Error!?External {
        if (!enabled) return null;
        return .{
            .cb = cb orelse return error.MissingCursorCallback,
            .userdata = userdata,
        };
    }

    pub fn publish(self: External, cell: *const Cell) void {
        self.cb(self.userdata, cell);
    }
};

/// Where the external cursor is and how it looks, from the last frame
/// update.
pub const Placement = struct {
    style: Style,
    /// The first column of the cursor cell: a wide character's head.
    column: u16,
    row: u16,
    wide: bool,
    blinking: bool,

    pub fn columns(self: Placement) u16 {
        return if (self.wide) 2 else 1;
    }

    /// The cell in the surface's pixels: the grid starts at the top-left
    /// padding (`Uniforms.projection_matrix`).
    pub fn rect(
        self: Placement,
        padding_left: u32,
        padding_top: u32,
        cell_width: u32,
        cell_height: u32,
    ) Rect {
        return .{
            .x = padding_left + @as(u32, self.column) * cell_width,
            .y = padding_top + @as(u32, self.row) * cell_height,
            .width = @as(u32, self.columns()) * cell_width,
            .height = cell_height,
        };
    }

    /// The cell in grid space, where the shaders place quads before the
    /// projection: pixels from the grid's top-left corner.
    pub fn gridRect(self: Placement, cell_width: u32, cell_height: u32) GridRect {
        const x0 = @as(i64, self.column) * cell_width;
        const y0 = @as(i64, self.row) * cell_height;
        return .{
            .x0 = x0,
            .y0 = y0,
            .x1 = x0 + @as(i64, self.columns()) * cell_width,
            .y1 = y0 + cell_height,
        };
    }
};

pub const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

/// A rectangle in grid space (`Placement.gridRect`), end exclusive.
pub const GridRect = struct {
    x0: i64,
    y0: i64,
    x1: i64,
    y1: i64,

    /// The rectangles share pixels.
    pub fn crosses(a: GridRect, b: GridRect) bool {
        return a.x0 < b.x1 and b.x0 < a.x1 and a.y0 < b.y1 and b.y0 < a.y1;
    }
};

/// The quad of a glyph, as `cell_text_vertex` (shaders.metal) places it:
/// the y bearing is from the bottom of its cell to the top of the glyph.
pub fn glyphRect(text: anytype, cell_width: u32, cell_height: u32) GridRect {
    const x0 = @as(i64, text.grid_pos[0]) * cell_width + text.bearings[0];
    const y0 = @as(i64, text.grid_pos[1]) * cell_height + cell_height - text.bearings[1];
    return .{
        .x0 = x0,
        .y0 = y0,
        .x1 = x0 + text.glyph_size[0],
        .y1 = y0 + text.glyph_size[1],
    };
}

/// The quad of an image placement (`image.Placement`), as `image_vertex`
/// (shaders.metal) places it.
pub fn imageRect(placement: anytype, cell_width: u32, cell_height: u32) GridRect {
    const x0 = @as(i64, placement.x) * cell_width + placement.cell_offset_x;
    const y0 = @as(i64, placement.y) * cell_height + placement.cell_offset_y;
    return .{
        .x0 = x0,
        .y0 = y0,
        .x1 = x0 + placement.width,
        .y1 = y0 + placement.height,
    };
}

/// Appends to `out`, in the order of `rows` (the frame's draw order), the
/// glyphs whose quads cross `cell`: what the frame draws over a block
/// cursor in that cell, including glyphs of other rows and columns that
/// reach into it. The cell target's projection clips the rest of each.
pub fn appendCrossing(
    comptime Text: type,
    alloc: std.mem.Allocator,
    out: *std.ArrayList(Text),
    rows: []const std.ArrayList(Text),
    cell: GridRect,
    cell_width: u32,
    cell_height: u32,
) std.mem.Allocator.Error!void {
    for (rows) |row| for (row.items) |text| {
        if (glyphRect(text, cell_width, cell_height).crosses(cell))
            try out.append(alloc, text);
    };
}

/// What the cell target shows besides the glyphs and colors: equal keys
/// with equal glyphs and colors draw equal pixels.
pub const KeyGeometry = struct {
    padding_left: u32,
    padding_top: u32,
    cell_width: u32,
    cell_height: u32,
    /// Atlas positions are per font grid.
    font_grid: usize,
};

/// The key of what the cursor cell shows (`Publisher`): the placement and
/// its geometry, the cursor glyph and `texts` (`appendCrossing`), the cell
/// backgrounds of the cursor cells and of each text's own cell (minimum
/// contrast reads it), from `bg_cells` (row-major, `columns` wide), and
/// `colors`, a struct of the uniforms the shaders color with. Nothing else
/// on the screen changes it: output on other rows or columns that does not
/// reach the cell leaves the key alone.
pub fn cellKey(
    placement: ?Placement,
    geometry: KeyGeometry,
    glyph: anytype,
    texts: anytype,
    bg_cells: anytype,
    columns: usize,
    colors: anytype,
) u64 {
    var h: std.hash.Wyhash = .init(0);
    std.hash.autoHash(&h, placement != null);
    const p = placement orelse return h.final();
    std.hash.autoHash(&h, p);
    std.hash.autoHash(&h, geometry);
    h.update(std.mem.asBytes(&glyph));
    h.update(std.mem.sliceAsBytes(texts));
    const Bg = std.meta.Elem(@TypeOf(bg_cells));
    const hashBg = struct {
        fn f(hasher: *std.hash.Wyhash, cells: []const Bg, cols: usize, row: usize, col: usize) void {
            const i = row * cols + col;
            if (col < cols and i < cells.len) hasher.update(std.mem.asBytes(&cells[i]));
        }
    }.f;
    for (p.column..@as(usize, p.column) + p.columns()) |x| hashBg(&h, bg_cells, columns, p.row, x);
    for (texts) |text| hashBg(&h, bg_cells, columns, text.grid_pos[1], text.grid_pos[0]);
    inline for (std.meta.fields(@TypeOf(colors))) |field| {
        const v = @field(colors, field.name);
        switch (@typeInfo(field.type)) {
            .float => std.hash.autoHash(&h, @as(u64, @bitCast(@as(f64, v)))),
            .array => h.update(std.mem.asBytes(&v)),
            else => std.hash.autoHash(&h, v),
        }
    }
    return h.final();
}

/// The frame's uniforms changed to draw only the cursor cell of
/// `placement` into a target of the cell's size: the projection and the
/// cell background lookup start at that cell, and a block cursor colors the
/// text under it (`cursor_pos`), as in the frame.
pub fn cellUniforms(
    comptime Uniforms: type,
    frame: Uniforms,
    placement: Placement,
    cell_width: f32,
    cell_height: f32,
) Uniforms {
    var u = frame;
    const left = @as(f32, @floatFromInt(placement.column)) * cell_width;
    const top = @as(f32, @floatFromInt(placement.row)) * cell_height;
    const width = @as(f32, @floatFromInt(placement.columns())) * cell_width;
    u.projection_matrix = math.ortho2d(left, left + width, top + cell_height, top);
    // cell_bg finds the cell of a target pixel from the top and left
    // padding: pixel 0 is the cursor cell's top-left corner.
    u.grid_padding = .{ -top, 0, 0, -left };
    u.screen_size = .{ width, cell_height };
    if (placement.style == .block) {
        u.cursor_pos = .{ placement.column, placement.row };
        u.bools.cursor_wide = placement.wide;
    } else {
        u.cursor_pos = .{ std.math.maxInt(u16), std.math.maxInt(u16) };
        u.bools.cursor_wide = false;
    }
    return u;
}

/// Publishes a cell only when it differs from the last published one: one
/// callback per move or cell change, none for a frame that left it alone.
pub const Publisher = struct {
    /// The key of the last cell handed to a frame (`commit`).
    last: ?u64 = null,
    serial: u64 = 0,
    /// The last committed cell, without its surface (`restart`).
    cell: Cell = .{},

    pub fn changed(self: *const Publisher, key: u64) bool {
        return self.last != key;
    }

    /// `cell`, with `key`, is in a frame: returns it with its serial.
    pub fn commit(self: *Publisher, key: u64, cell: Cell) Cell {
        self.last = key;
        self.serial += 1;
        var c = cell;
        c.serial = self.serial;
        c.unchanged = false;
        self.cell = c;
        self.cell.surface = null;
        return c;
    }

    /// Ghostty's own blink would restart (terminal output) and the cell is
    /// unchanged: the call that starts the embedder's blink shown again,
    /// null when the last cell does not blink.
    pub fn restart(self: *Publisher) ?Cell {
        if (self.last == null or !self.cell.visible or !self.cell.blinking) return null;
        self.serial += 1;
        var c = self.cell;
        c.serial = self.serial;
        c.unchanged = true;
        return c;
    }

    /// The frame with the last cell failed: the next frame publishes again.
    pub fn reset(self: *Publisher) void {
        self.last = null;
    }
};

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

test "cursor: a blinking cursor blinks only where style hides it" {
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

    try testing.expect(blinks(&state, .{ .focused = true }));
    // Unfocused: a steady hollow block. Preedit: a steady block.
    try testing.expect(!blinks(&state, .{ .focused = false }));
    try testing.expect(!blinks(&state, .{ .focused = true, .preedit = true }));

    term.modes.set(.cursor_blinking, false);
    try state.update(alloc, &term);
    try testing.expect(!blinks(&state, .{ .focused = true }));

    // A hidden cursor does not blink.
    term.modes.set(.cursor_blinking, true);
    term.modes.set(.cursor_visible, false);
    try state.update(alloc, &term);
    try testing.expect(!blinks(&state, .{ .focused = true }));
}

test "cursor external: enabled needs the callback" {
    const testing = std.testing;
    const Cb = struct {
        fn cb(_: ?*anyopaque, _: *const Cell) callconv(.c) void {}
    };
    var userdata: u8 = 0;

    try testing.expectError(error.MissingCursorCallback, External.fromConfig(true, null, null));
    try testing.expectEqual(@as(?External, null), try External.fromConfig(false, &Cb.cb, &userdata));
    const external = (try External.fromConfig(true, &Cb.cb, &userdata)).?;
    try testing.expect(external.cb == &Cb.cb);
    try testing.expect(external.userdata == @as(?*anyopaque, &userdata));
}

test "cursor external: one publish per move or cell change" {
    const testing = std.testing;
    var publisher: Publisher = .{};
    var published: u64 = 0;
    const shown: Cell = .{ .visible = true, .blinking = true, .blink_interval_ms = blink_interval_ms };

    // Frame keys (`cellKey`, tested below): a cell, the same cell three
    // more times (blink ticks, other rows printing), a move, a move back,
    // a style change, again.
    const keys = [_]u64{ 1, 1, 1, 1, 2, 1, 3, 3 };
    for (keys) |key| {
        if (!publisher.changed(key)) continue;
        published += 1;
        const cell = publisher.commit(key, shown);
        try testing.expectEqual(published, cell.serial);
        try testing.expect(!cell.unchanged);
    }
    try testing.expectEqual(@as(u64, 4), published);

    // A failed frame publishes the same cell again with the next frame.
    publisher.reset();
    try testing.expect(publisher.changed(3));
}

test "cursor external: a blink restart republishes the unchanged cell" {
    const testing = std.testing;
    var publisher: Publisher = .{};

    // Nothing published yet: nothing to restart.
    try testing.expectEqual(@as(?Cell, null), publisher.restart());

    var surface: u8 = 0;
    const first = publisher.commit(7, .{
        .surface = &surface,
        .x = 10,
        .y = 20,
        .width = 9,
        .height = 19,
        .visible = true,
        .blinking = true,
        .blink_interval_ms = blink_interval_ms,
    });
    try testing.expectEqual(@as(u64, 1), first.serial);
    try testing.expect(first.surface != null);

    // Output that leaves the cell alone: the same cell, a new serial, no
    // surface (the embedder keeps the last one), and the key holds.
    const again = publisher.restart().?;
    try testing.expectEqual(@as(u64, 2), again.serial);
    try testing.expect(again.unchanged);
    try testing.expect(again.surface == null);
    try testing.expect(again.visible and again.blinking);
    try testing.expectEqual(first.x, again.x);
    try testing.expectEqual(first.width, again.width);
    try testing.expect(!publisher.changed(7));

    // The next new cell is not marked unchanged and keeps counting.
    const moved = publisher.commit(8, .{ .visible = true, .blinking = true });
    try testing.expectEqual(@as(u64, 3), moved.serial);
    try testing.expect(!moved.unchanged);

    // A steady or hidden cursor has no blink to restart.
    _ = publisher.commit(9, .{ .visible = true, .blinking = false });
    try testing.expectEqual(@as(?Cell, null), publisher.restart());
    _ = publisher.commit(10, .{});
    try testing.expectEqual(@as(?Cell, null), publisher.restart());
}

/// The CellText fields the key and the glyph quads read, for tests.
const TestText = extern struct {
    glyph_pos: [2]u32 = .{ 0, 0 },
    glyph_size: [2]u32,
    bearings: [2]i16,
    grid_pos: [2]u16,
    color: [4]u8 = .{ 255, 255, 255, 255 },
};

test "cursor external: a glyph crosses the cell only where its quad reaches" {
    const testing = std.testing;
    const cw: u32 = 10;
    const ch: u32 = 20;
    const p: Placement = .{ .style = .block, .column = 3, .row = 2, .wide = false, .blinking = true };
    const cell = p.gridRect(cw, ch);
    try testing.expectEqual(GridRect{ .x0 = 30, .y0 = 40, .x1 = 40, .y1 = 60 }, cell);

    // The cursor's own character (bearing y 15: its top is 5 px down).
    const own: TestText = .{ .glyph_size = .{ 8, 14 }, .bearings = .{ 1, 15 }, .grid_pos = .{ 3, 2 } };
    try testing.expectEqual(GridRect{ .x0 = 31, .y0 = 45, .x1 = 39, .y1 = 59 }, glyphRect(own, cw, ch));
    try testing.expect(glyphRect(own, cw, ch).crosses(cell));
    // A neighbor in the same row that stays in its cell.
    const left: TestText = .{ .glyph_size = .{ 8, 14 }, .bearings = .{ 1, 15 }, .grid_pos = .{ 2, 2 } };
    try testing.expect(!glyphRect(left, cw, ch).crosses(cell));
    // A wide icon in the column to the left that reaches into the cell.
    const icon: TestText = .{ .glyph_size = .{ 16, 18 }, .bearings = .{ 0, 19 }, .grid_pos = .{ 2, 2 } };
    try testing.expect(glyphRect(icon, cw, ch).crosses(cell));
    // A tall glyph of the row above that reaches down into the cell.
    const tall: TestText = .{ .glyph_size = .{ 8, 30 }, .bearings = .{ 1, 18 }, .grid_pos = .{ 3, 1 } };
    try testing.expect(glyphRect(tall, cw, ch).crosses(cell));
    // A combining mark of the row below stacked up into the cell.
    const mark: TestText = .{ .glyph_size = .{ 6, 4 }, .bearings = .{ 2, 22 }, .grid_pos = .{ 3, 3 } };
    try testing.expect(glyphRect(mark, cw, ch).crosses(cell));
    // Touching the edge is not crossing: the rows above and below.
    const above: TestText = .{ .glyph_size = .{ 10, 20 }, .bearings = .{ 0, 20 }, .grid_pos = .{ 3, 1 } };
    const below: TestText = .{ .glyph_size = .{ 10, 20 }, .bearings = .{ 0, 20 }, .grid_pos = .{ 3, 3 } };
    try testing.expect(!glyphRect(above, cw, ch).crosses(cell));
    try testing.expect(!glyphRect(below, cw, ch).crosses(cell));

    // Rows in draw order: only the crossing glyphs, in that order.
    const alloc = testing.allocator;
    var rows: [3]std.ArrayList(TestText) = .{ .empty, .empty, .empty };
    defer for (&rows) |*r| r.deinit(alloc);
    try rows[0].appendSlice(alloc, &.{ above, tall });
    try rows[1].appendSlice(alloc, &.{ left, icon, own });
    try rows[2].appendSlice(alloc, &.{ below, mark });
    var out: std.ArrayList(TestText) = .empty;
    defer out.deinit(alloc);
    try appendCrossing(TestText, alloc, &out, &rows, cell, cw, ch);
    try testing.expectEqualSlices(TestText, &.{ tall, icon, own, mark }, out.items);

    // A kitty image placed over the cell, and one beside it.
    const Img = struct { x: i32, y: i32, cell_offset_x: u32, cell_offset_y: u32, width: u32, height: u32 };
    const over: Img = .{ .x = 1, .y = 1, .cell_offset_x = 4, .cell_offset_y = 0, .width = 30, .height = 25 };
    const beside: Img = .{ .x = 5, .y = 0, .cell_offset_x = 0, .cell_offset_y = 0, .width = 30, .height = 100 };
    try testing.expect(imageRect(over, cw, ch).crosses(cell));
    try testing.expect(!imageRect(beside, cw, ch).crosses(cell));
}

test "cursor external: the key changes only with what the cell shows" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const cols: usize = 6;
    const geometry: KeyGeometry = .{ .padding_left = 4, .padding_top = 6, .cell_width = 10, .cell_height = 20, .font_grid = 1 };
    const Bg = extern struct { color: [4]u8 };
    const Colors = struct { cursor: [4]u8, bg: [4]u8, min_contrast: f32, palette: [2][4]u8 };
    const colors: Colors = .{
        .cursor = .{ 1, 2, 3, 255 },
        .bg = .{ 0, 0, 0, 255 },
        .min_contrast = 1,
        .palette = .{ .{ 9, 9, 9, 255 }, .{ 8, 8, 8, 255 } },
    };
    const cursor_glyph: TestText = .{ .glyph_size = .{ 10, 20 }, .bearings = .{ 0, 20 }, .grid_pos = .{ 2, 1 } };
    const p: Placement = .{ .style = .block, .column = 2, .row = 1, .wide = false, .blinking = true };

    // A 6 x 3 screen: a glyph in each cell, and the cell backgrounds.
    var bgs: [3 * cols]Bg = @splat(.{ .color = .{ 0, 0, 0, 0 } });
    var rows: [3]std.ArrayList(TestText) = .{ .empty, .empty, .empty };
    defer for (&rows) |*r| r.deinit(alloc);
    for (&rows, 0..) |*r, y| for (0..cols) |x| try r.append(alloc, .{
        .glyph_size = .{ 8, 14 },
        .bearings = .{ 1, 15 },
        .grid_pos = .{ @intCast(x), @intCast(y) },
        .glyph_pos = .{ @intCast(x * 10), 0 },
    });

    // As drawCursorCell keys a frame: the crossing glyphs, then the key.
    const key = struct {
        fn f(
            a: std.mem.Allocator,
            pl: ?Placement,
            g: KeyGeometry,
            glyph: TestText,
            rs: []const std.ArrayList(TestText),
            b: []const Bg,
            c: Colors,
        ) !u64 {
            var texts: std.ArrayList(TestText) = .empty;
            defer texts.deinit(a);
            if (pl) |pp| try appendCrossing(TestText, a, &texts, rs, pp.gridRect(g.cell_width, g.cell_height), g.cell_width, g.cell_height);
            return cellKey(pl, g, glyph, texts.items, b, cols, c);
        }
    }.f;

    const base = try key(alloc, p, geometry, cursor_glyph, &rows, &bgs, colors);
    // A blink tick changes none of the inputs.
    try testing.expectEqual(base, try key(alloc, p, geometry, cursor_glyph, &rows, &bgs, colors));

    // Output on another row, and in another column of the cursor row (a
    // prompt clock, a spinner): the same key.
    rows[0].items[2].glyph_pos = .{ 500, 0 };
    rows[1].items[5].glyph_pos = .{ 600, 0 };
    bgs[0 * cols + 2] = .{ .color = .{ 255, 0, 0, 255 } };
    bgs[1 * cols + 5] = .{ .color = .{ 0, 255, 0, 255 } };
    try testing.expectEqual(base, try key(alloc, p, geometry, cursor_glyph, &rows, &bgs, colors));

    // The character under the cursor changes.
    rows[1].items[2].glyph_pos = .{ 700, 0 };
    const new_char = try key(alloc, p, geometry, cursor_glyph, &rows, &bgs, colors);
    try testing.expect(new_char != base);

    // Its background changes.
    bgs[1 * cols + 2] = .{ .color = .{ 0, 0, 255, 255 } };
    const new_bg = try key(alloc, p, geometry, cursor_glyph, &rows, &bgs, colors);
    try testing.expect(new_bg != new_char);

    // A glyph of the row above grows down into the cell.
    rows[0].items[2].glyph_size = .{ 8, 40 };
    const reach = try key(alloc, p, geometry, cursor_glyph, &rows, &bgs, colors);
    try testing.expect(reach != new_bg);

    // A move, a style change, a color change, a font change.
    var moved = p;
    moved.column = 3;
    var moved_glyph = cursor_glyph;
    moved_glyph.grid_pos = .{ 3, 1 };
    try testing.expect(try key(alloc, moved, geometry, moved_glyph, &rows, &bgs, colors) != reach);
    var bar = p;
    bar.style = .bar;
    try testing.expect(try key(alloc, bar, geometry, cursor_glyph, &rows, &bgs, colors) != reach);
    var recolored = colors;
    recolored.cursor = .{ 9, 9, 9, 255 };
    try testing.expect(try key(alloc, p, geometry, cursor_glyph, &rows, &bgs, recolored) != reach);
    var contrast = colors;
    contrast.min_contrast = 3;
    try testing.expect(try key(alloc, p, geometry, cursor_glyph, &rows, &bgs, contrast) != reach);
    var font = geometry;
    font.font_grid = 2;
    try testing.expect(try key(alloc, p, font, cursor_glyph, &rows, &bgs, colors) != reach);

    // No cursor: one key, whatever the screen shows.
    try testing.expectEqual(
        try key(alloc, null, geometry, cursor_glyph, &rows, &bgs, colors),
        try key(alloc, null, font, moved_glyph, &rows, &bgs, recolored),
    );
}

test "cursor external: the cell rect covers the cursor cells" {
    const testing = std.testing;
    const narrow: Placement = .{ .style = .block, .column = 3, .row = 2, .wide = false, .blinking = true };
    try testing.expectEqual(
        Rect{ .x = 4 + 3 * 10, .y = 6 + 2 * 20, .width = 10, .height = 20 },
        narrow.rect(4, 6, 10, 20),
    );
    var wide = narrow;
    wide.wide = true;
    try testing.expectEqual(@as(u32, 20), wide.rect(4, 6, 10, 20).width);
}

test "cursor external: the cell target shows the frame's pixels of the cell" {
    const testing = std.testing;
    // The fields of the Metal and OpenGL uniforms that cellUniforms sets.
    const U = struct {
        projection_matrix: math.Mat,
        screen_size: [2]f32,
        grid_padding: [4]f32,
        cursor_pos: [2]u16,
        bools: struct { cursor_wide: bool },
    };
    const cw: f32 = 9;
    const ch: f32 = 19;
    const pad_left: f32 = 5;
    const pad_top: f32 = 7;
    const cols: f32 = 80;
    const rows: f32 = 24;
    // As generic.zig updateScreenSizeUniforms sets them, with 3 and 2
    // pixels of right and bottom padding.
    const frame: U = .{
        .projection_matrix = math.ortho2d(-pad_left, cols * cw + 3, rows * ch + 2, -pad_top),
        .screen_size = .{ pad_left + cols * cw + 3, pad_top + rows * ch + 2 },
        .grid_padding = .{ pad_top, 3, 2, pad_left },
        .cursor_pos = .{ std.math.maxInt(u16), std.math.maxInt(u16) },
        .bools = .{ .cursor_wide = false },
    };

    // The target pixel of a grid-space point: projection, then viewport.
    const pixel = struct {
        fn f(u: U, x: f32, y: f32) [2]f32 {
            const m = u.projection_matrix;
            const ndc_x = m[0][0] * x + m[1][0] * y + m[3][0];
            const ndc_y = m[0][1] * x + m[1][1] * y + m[3][1];
            return .{ (ndc_x + 1) / 2 * u.screen_size[0], (1 - ndc_y) / 2 * u.screen_size[1] };
        }
    }.f;

    inline for (.{ false, true }) |wide| {
        const placement: Placement = .{ .style = .block, .column = 41, .row = 17, .wide = wide, .blinking = false };
        const rect = placement.rect(@intFromFloat(pad_left), @intFromFloat(pad_top), @intFromFloat(cw), @intFromFloat(ch));
        const cell = cellUniforms(U, frame, placement, cw, ch);
        try testing.expectEqual([2]f32{ @floatFromInt(rect.width), @floatFromInt(rect.height) }, cell.screen_size);

        // Glyph corners in grid space, inside and around the cell.
        const points = [_][2]f32{
            .{ 41 * cw, 17 * ch },
            .{ 41 * cw + 3.5, 17 * ch + 11.25 },
            .{ 43 * cw, 18 * ch },
            .{ 40 * cw - 2, 17 * ch - 4 },
        };
        for (points) |p| {
            const in_frame = pixel(frame, p[0], p[1]);
            const in_cell = pixel(cell, p[0], p[1]);
            try testing.expectApproxEqAbs(in_frame[0] - @as(f32, @floatFromInt(rect.x)), in_cell[0], 0.001);
            try testing.expectApproxEqAbs(in_frame[1] - @as(f32, @floatFromInt(rect.y)), in_cell[1], 0.001);
        }

        // cell_bg: every target pixel finds a cursor cell's background.
        var x: f32 = 0.5;
        while (x < cell.screen_size[0]) : (x += 1) {
            var y: f32 = 0.5;
            while (y < cell.screen_size[1]) : (y += 1) {
                const col = @floor((x - cell.grid_padding[3]) / cw);
                const row = @floor((y - cell.grid_padding[0]) / ch);
                try testing.expect(col == 41 or (wide and col == 42));
                try testing.expectEqual(@as(f32, 17), row);
            }
        }

        // A block colors the text under it, a wide one in both columns.
        try testing.expectEqual([2]u16{ 41, 17 }, cell.cursor_pos);
        try testing.expectEqual(wide, cell.bools.cursor_wide);
    }

    // Other styles leave the text color alone.
    const bar: Placement = .{ .style = .bar, .column = 41, .row = 17, .wide = false, .blinking = false };
    const bar_cell = cellUniforms(U, frame, bar, cw, ch);
    try testing.expectEqual([2]u16{ std.math.maxInt(u16), std.math.maxInt(u16) }, bar_cell.cursor_pos);
}
