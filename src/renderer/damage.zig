//! Partial redraw by buffer age: where a frame changed (grid rows), what
//! each swap-chain buffer has to draw again since it was last drawn, and
//! the pixel band a frame redraws.
//!
//! A buffer drawn three frames ago misses the changes of the two frames
//! drawn into the other buffers since, so each buffer collects the damage
//! of every frame drawn after it, and a frame redraws only its buffer's
//! collected damage (with the other pixels loaded as they are). Chromium's
//! display compositor does the same: `BufferQueue` adds each frame's damage
//! to every buffer and a new buffer starts fully damaged
//! (components/viz/service/display_embedder/buffer_queue.cc,
//! `UpdateBufferDamage`, `CurrentBufferDamage`), and the renderer draws
//! with a scissor to that rect over the loaded pixels
//! (components/viz/service/display/direct_renderer.cc, partial swap).
//!
//! A buffer whose pixels may not be what the renderer drew redraws fully:
//! the embedder made it volatile and the system may have purged it, or the
//! presentation was hidden or purged since. Chromium does the same for a
//! purged IOSurface: un-purging one that was emptied marks it uncleared
//! (gpu/command_buffer/service/shared_image/iosurface_image_backing.mm,
//! `SetPurgeable`).
const std = @import("std");

/// What changed since a draw: nothing, a span of grid rows, or anything.
pub const Damage = union(enum) {
    none,
    rows: Rows,
    full,

    /// Grid rows `start` up to, not including, `end`.
    pub const Rows = struct {
        start: u32,
        end: u32,
    };

    /// Only row `y`.
    pub fn row(y: u32) Damage {
        return .{ .rows = .{ .start = y, .end = y + 1 } };
    }

    /// Adds `other`: one span that covers both (a scissor is one rect).
    pub fn add(self: *Damage, other: Damage) void {
        self.* = switch (other) {
            .none => self.*,
            .full => .full,
            .rows => |b| switch (self.*) {
                .none => other,
                .full => .full,
                .rows => |a| .{ .rows = .{
                    .start = @min(a.start, b.start),
                    .end = @max(a.end, b.end),
                } },
            },
        };
    }

    pub fn addRow(self: *Damage, y: u32) void {
        self.add(.row(y));
    }
};

/// The damage of one swap-chain buffer. A new buffer has no pixels the
/// renderer drew: fully damaged.
pub const Buffer = struct {
    damage: Damage = .full,
    /// The renderer's content epoch when this buffer was last drawn
    /// (`take`): a newer epoch means its pixels may be gone.
    epoch: u64 = 0,

    /// A frame was drawn with `frame`'s damage. Every buffer of the swap
    /// chain gets it, the one drawn now too (before its `take`).
    pub fn collect(self: *Buffer, frame: Damage) void {
        self.damage.add(frame);
    }

    /// The buffer redraws fully (a frame the GPU failed: its pixels are
    /// unknown).
    pub fn invalidate(self: *Buffer) void {
        self.damage = .full;
    }

    /// What this buffer draws now, and it is up to date after the draw.
    /// `epoch`: the renderer's content epoch, read before this frame
    /// (a later change of it reaches this buffer at its next draw).
    /// `kept`: the buffer's pixels are still the ones last drawn (not
    /// purged, never volatile since). Never `.none`: a frame that is drawn
    /// with nothing to draw (a forced redraw) draws everything.
    pub fn take(self: *Buffer, epoch: u64, kept: bool) Damage {
        const damage: Damage = if (!kept or self.epoch != epoch) .full else self.damage;
        self.damage = .none;
        self.epoch = epoch;
        return switch (damage) {
            .none => .full,
            else => damage,
        };
    }
};

/// Pixel rows of a target, full width: `y` up to, not including, `y + height`.
pub const Band = struct {
    y: u32,
    height: u32,
};

/// Where the grid is in the target, in pixels.
pub const Geometry = struct {
    screen_height: u32,
    /// Blank space above the first row.
    pad_top: f32,
    cell_height: f32,
    grid_rows: u32,
};

/// Rows above and below the damage that are drawn too: a glyph may reach
/// into the next row (tall glyphs, underlines below the baseline), so its
/// old pixels there go with it.
pub const overflow_rows = 1;

/// The pixel band to redraw for `rows`, or null to draw the whole target
/// (the band reaches both edges, or the geometry is not drawable). A band
/// at the first or last row reaches the target's edge: the padding there
/// shows the edge row's background (`window-padding-color = extend`).
pub fn band(rows: Damage.Rows, g: Geometry) ?Band {
    if (g.grid_rows == 0 or g.screen_height == 0 or !(g.cell_height > 0)) return null;
    const start = rows.start -| overflow_rows;
    const end = @min(rows.end +| overflow_rows, g.grid_rows);
    if (start >= end) return null;

    const top: u32 = if (start == 0) 0 else pixel(g.pad_top + @as(f32, @floatFromInt(start)) * g.cell_height, .floor);
    const bottom: u32 = if (end >= g.grid_rows) g.screen_height else pixel(g.pad_top + @as(f32, @floatFromInt(end)) * g.cell_height, .ceil);
    const y = @min(top, g.screen_height);
    const y_end = @min(bottom, g.screen_height);
    if (y_end <= y) return null;
    if (y == 0 and y_end == g.screen_height) return null;
    return .{ .y = y, .height = y_end - y };
}

fn pixel(v: f32, comptime mode: enum { floor, ceil }) u32 {
    const r = switch (mode) {
        .floor => @floor(v),
        .ceil => @ceil(v),
    };
    if (!(r > 0)) return 0;
    if (r >= @as(f32, @floatFromInt(std.math.maxInt(u32)))) return std.math.maxInt(u32);
    return @intFromFloat(r);
}

test "renderer damage: spans merge into one span; full absorbs everything" {
    var d: Damage = .none;
    d.add(.none);
    try std.testing.expectEqual(Damage.none, d);
    d.addRow(5);
    try std.testing.expectEqualDeep(Damage{ .rows = .{ .start = 5, .end = 6 } }, d);
    d.addRow(2);
    try std.testing.expectEqualDeep(Damage{ .rows = .{ .start = 2, .end = 6 } }, d);
    d.add(.full);
    try std.testing.expectEqual(Damage.full, d);
    d.addRow(1);
    try std.testing.expectEqual(Damage.full, d);
}

test "renderer damage: one typed character redraws one row band" {
    const g: Geometry = .{ .screen_height = 1000, .pad_top = 4, .cell_height = 20, .grid_rows = 40 };
    // Row 10 and its overflow rows 9 and 11.
    const b = band(Damage.row(10).rows, g).?;
    try std.testing.expectEqual(@as(u32, 4 + 9 * 20), b.y);
    try std.testing.expectEqual(@as(u32, 3 * 20), b.height);
    // The first row reaches the top edge, the last row the bottom edge.
    try std.testing.expectEqual(@as(u32, 0), band(Damage.row(0).rows, g).?.y);
    const last = band(Damage.row(39).rows, g).?;
    try std.testing.expectEqual(@as(u32, 1000), last.y + last.height);
    // A span over every row is the whole target.
    try std.testing.expectEqual(@as(?Band, null), band(.{ .start = 0, .end = 40 }, g));
    try std.testing.expectEqual(@as(?Band, null), band(.{ .start = 1, .end = 39 }, g));
    // No grid: draw everything.
    try std.testing.expectEqual(@as(?Band, null), band(Damage.row(0).rows, .{
        .screen_height = 1000,
        .pad_top = 0,
        .cell_height = 0,
        .grid_rows = 40,
    }));
}

/// A swap chain of `n` buffers of `rows` rows each, drawn the way the
/// renderer draws: the next buffer in turn redraws its collected damage
/// over its loaded pixels (`partial`), or every row.
fn Sim(comptime n: usize, comptime rows: usize) type {
    return struct {
        const Self = @This();

        screen: [rows]u32 = @splat(0),
        pixels: [n][rows]u32 = @splat(@splat(0xdead)),
        buffers: [n]Buffer = @splat(.{}),
        next: usize = 0,
        epoch: u64 = 0,
        kept: [n]bool = @splat(true),
        /// Rows each draw redrew.
        drawn_rows: usize = 0,

        /// `draw`, and the buffer drawn shows what a full redraw shows.
        fn frame(self: *Self, damage: Damage, value: u32) !void {
            try std.testing.expect(self.draw(damage, value));
        }

        /// The screen changes `damage`'s rows (by `value`) and a frame is
        /// drawn. Returns whether the buffer drawn shows the screen.
        fn draw(self: *Self, damage: Damage, value: u32) bool {
            switch (damage) {
                .none => {},
                .full => for (&self.screen) |*r| {
                    r.* +%= value;
                },
                .rows => |s| for (s.start..s.end) |y| {
                    self.screen[y] +%= value;
                },
            }
            for (&self.buffers) |*b| b.collect(damage);
            const i = self.next;
            self.next = (self.next + 1) % n;
            const taken = self.buffers[i].take(self.epoch, self.kept[i]);
            self.kept[i] = true;
            const span: Damage.Rows = switch (taken) {
                .none => unreachable,
                .full => .{ .start = 0, .end = rows },
                .rows => |s| .{
                    .start = s.start -| overflow_rows,
                    .end = @min(s.end + overflow_rows, rows),
                },
            };
            for (span.start..span.end) |y| self.pixels[i][y] = self.screen[y];
            self.drawn_rows = span.end - span.start;
            return std.mem.eql(u32, &self.screen, &self.pixels[i]);
        }

        /// The system purged buffer `i` (it was made volatile).
        fn purge(self: *Self, i: usize) void {
            self.pixels[i] = @splat(0);
            self.kept[i] = false;
        }
    };
}

test "renderer damage: buffer age: partial frames show what full redraws show" {
    var sim: Sim(3, 24) = .{};
    // The first frame of each buffer draws it fully.
    for (0..3) |_| try sim.frame(.full, 1);
    try std.testing.expectEqual(@as(usize, 24), sim.drawn_rows);

    // Typing on row 10: each frame changes one row, and once every buffer
    // saw the row, a frame redraws one band (the row and its overflow).
    for (0..9) |i| try sim.frame(.row(10), @intCast(i + 2));
    try std.testing.expectEqual(@as(usize, 3), sim.drawn_rows);

    // Damage on different rows in turn: each buffer draws the union of what
    // it missed.
    try sim.frame(.row(3), 7);
    try sim.frame(.row(20), 7);
    try sim.frame(.row(12), 7);
    try sim.frame(.{ .rows = .{ .start = 5, .end = 8 } }, 9);
    try sim.frame(.none, 0);
    try sim.frame(.none, 0);
    try sim.frame(.none, 0);
    try sim.frame(.full, 3);
    for (0..6) |_| try sim.frame(.row(0), 1);
    try std.testing.expectEqual(@as(usize, 2), sim.drawn_rows);
}

test "renderer damage: buffer age: a purged buffer forces a full redraw" {
    var sim: Sim(3, 24) = .{};
    for (0..3) |_| try sim.frame(.full, 1);
    for (0..3) |_| try sim.frame(.row(10), 1);

    // Buffer 0 (drawn next) was made volatile and purged: its pixels are
    // zero, so the next frame redraws it fully and shows the screen.
    sim.purge(sim.next);
    try sim.frame(.row(10), 1);
    try std.testing.expectEqual(@as(usize, 24), sim.drawn_rows);

    // Without the purge rule the band alone would leave the purged rows.
    var stale: Sim(3, 24) = .{};
    for (0..3) |_| try stale.frame(.full, 1);
    for (0..3) |_| try stale.frame(.row(10), 1);
    stale.pixels[stale.next] = @splat(0);
    try std.testing.expect(!stale.draw(.row(10), 1));
}

test "renderer damage: buffer age: a new content epoch (hidden, purged presentation) redraws every buffer" {
    var sim: Sim(3, 24) = .{};
    for (0..3) |_| try sim.frame(.full, 1);
    for (0..3) |_| try sim.frame(.row(4), 1);
    try std.testing.expectEqual(@as(usize, 3), sim.drawn_rows);
    sim.epoch += 1;
    for (0..3) |_| {
        try sim.frame(.row(4), 1);
        try std.testing.expectEqual(@as(usize, 24), sim.drawn_rows);
    }
    try sim.frame(.row(4), 1);
    try std.testing.expectEqual(@as(usize, 3), sim.drawn_rows);

    // A failed GPU frame: every buffer redraws.
    for (&sim.buffers) |*b| b.invalidate();
    try sim.frame(.row(4), 1);
    try std.testing.expectEqual(@as(usize, 24), sim.drawn_rows);
}
