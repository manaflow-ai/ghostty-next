//! The alpha of a cell with an explicit background color (cmux-next).
//!
//! Ghostty draws such a cell opaque, or at `background-opacity` with
//! `background-opacity-cells`. cmux NEXT draws a wallpaper or a
//! translucent window under its terminals, so a program's background band
//! (Claude Code's sent message, a status line) hid it. Two configs change
//! that: `background-cells-opacity` sets the alpha of every explicit
//! background, and `background-cells-neutral-fade` fades the ones that
//! differ from the theme background only in lightness, by how far they
//! are from it, so a near-background gray keeps only a tint and a colored
//! background keeps its color.
const std = @import("std");
const terminal = @import("../terminal/main.zig");
const ColorBlend = @import("ColorBlend.zig");

const RGB = terminal.color.RGB;

/// Oklab chroma difference under which a background counts as a lightness
/// shift of the theme background (a gray band on a gray theme).
pub const neutral_chroma: f32 = 0.03;

pub const Options = struct {
    /// `background-cells-opacity`: null keeps the old rule.
    opacity: ?f64 = null,
    /// `background-cells-neutral-fade`: Oklab lightness distance; 0 is off.
    neutral_fade: f64 = 0,
    /// `background-opacity-cells` and `background-opacity` (the old rule).
    opacity_cells: bool = false,
    background_opacity: f64 = 1,

    pub fn active(self: Options) bool {
        return self.opacity != null or self.neutral_fade > 0;
    }
};

/// The alpha of an explicit background `bg` on a terminal whose default
/// background is `default_bg`. Selected and reversed cells never come
/// here: they stay opaque.
pub fn explicit(bg: RGB, default_bg: RGB, opts: Options) u8 {
    const base: f64 = if (opts.opacity) |o|
        std.math.clamp(o, 0, 1)
    else if (opts.opacity_cells)
        std.math.clamp(opts.background_opacity, 0, 1)
    else
        1;
    var alpha = base;
    if (opts.neutral_fade > 0) {
        const a = ColorBlend.oklab(bg);
        const b = ColorBlend.oklab(default_bg);
        const chroma = std.math.hypot(a[1] - b[1], a[2] - b[2]);
        if (chroma < neutral_chroma) {
            const dl: f64 = @abs(a[0] - b[0]);
            alpha = base * @min(1, dl / opts.neutral_fade);
        }
    }
    return @intFromFloat(@round(alpha * 255));
}

test "cell bg alpha: unset keeps the old rule" {
    const t = std.testing;
    const bg: RGB = .{ .r = 0x37, .g = 0x37, .b = 0x37 };
    const def: RGB = .{ .r = 0x1e, .g = 0x1e, .b = 0x1e };
    try t.expectEqual(@as(u8, 255), explicit(bg, def, .{}));
    try t.expectEqual(@as(u8, 128), explicit(bg, def, .{ .opacity_cells = true, .background_opacity = 0.5 }));
}

test "cell bg alpha: opacity sets every explicit background" {
    const t = std.testing;
    const red: RGB = .{ .r = 0x80, .g = 0x10, .b = 0x10 };
    const def: RGB = .{ .r = 0x1e, .g = 0x1e, .b = 0x1e };
    try t.expectEqual(@as(u8, 179), explicit(red, def, .{ .opacity = 0.7 }));
    try t.expectEqual(@as(u8, 0), explicit(red, def, .{ .opacity = 0 }));
    try t.expectEqual(@as(u8, 255), explicit(red, def, .{ .opacity = 4 }));
}

test "cell bg alpha: neutral fade clears the theme background and tints a gray band" {
    const t = std.testing;
    const def: RGB = .{ .r = 0x1e, .g = 0x1e, .b = 0x1e };
    // A program repainting the theme background: fully clear.
    try t.expectEqual(@as(u8, 0), explicit(def, def, .{ .neutral_fade = 0.2 }));
    // A gray band just off it: a partial tint.
    const band: RGB = .{ .r = 0x37, .g = 0x37, .b = 0x37 };
    const a = explicit(band, def, .{ .neutral_fade = 0.2 });
    try t.expect(a > 0 and a < 200);
    // Far lighter gray: opaque.
    const white: RGB = .{ .r = 0xff, .g = 0xff, .b = 0xff };
    try t.expectEqual(@as(u8, 255), explicit(white, def, .{ .neutral_fade = 0.2 }));
    // With an opacity too, the fade scales it.
    try t.expectEqual(@as(u8, 0), explicit(def, def, .{ .neutral_fade = 0.2, .opacity = 0.7 }));
}

test "cell bg alpha: neutral fade leaves colored backgrounds alone" {
    const t = std.testing;
    const def: RGB = .{ .r = 0x1e, .g = 0x1e, .b = 0x1e };
    const diff_red: RGB = .{ .r = 0x3d, .g = 0x1e, .b = 0x1e };
    const diff_green: RGB = .{ .r = 0x1e, .g = 0x3a, .b = 0x22 };
    try t.expectEqual(@as(u8, 255), explicit(diff_red, def, .{ .neutral_fade = 0.2 }));
    try t.expectEqual(@as(u8, 255), explicit(diff_green, def, .{ .neutral_fade = 0.2 }));
}
