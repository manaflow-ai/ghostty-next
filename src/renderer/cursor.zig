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
    /// Null when not `visible`. Borrowed for the call: the embedder retains
    /// it to keep it.
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
};

pub const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

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

    pub fn changed(self: *const Publisher, key: u64) bool {
        return self.last != key;
    }

    /// The cell with `key` is in a frame: returns its serial.
    pub fn commit(self: *Publisher, key: u64) u64 {
        self.last = key;
        self.serial += 1;
        return self.serial;
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

    // Frame keys: a cell, the same cell three more times (blink ticks,
    // other rows printing), a move, a move back, a style change, again.
    const keys = [_]u64{ 1, 1, 1, 1, 2, 1, 3, 3 };
    for (keys) |key| {
        if (!publisher.changed(key)) continue;
        published += 1;
        try testing.expectEqual(published, publisher.commit(key));
    }
    try testing.expectEqual(@as(u64, 4), published);

    // A failed frame publishes the same cell again with the next frame.
    publisher.reset();
    try testing.expect(publisher.changed(3));
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
