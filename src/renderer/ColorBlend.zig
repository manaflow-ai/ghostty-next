//! Theme color transitions on the GPU (cmux-next).
//!
//! Every cell color keeps its source: a palette entry, a default color,
//! a config color (`Slot`), or `direct` for a true color. The renderer
//! writes the source once when it rebuilds the cells; the shaders look
//! the color up in `Uniforms.palette`, the table of the colors shown in
//! this frame. A theme change only moves that table: each frame mixes
//! the colors that were shown when the change came (`from`) toward the
//! new colors (`to`) along the embedder's curve, once on the CPU (one
//! mix per table entry, not per pixel), and uploads it with the other
//! uniforms. No cell is rebuilt for a blend frame, and the terminal lock
//! is not taken.
//!
//! A change that comes from the config (a theme, a light/dark switch, a
//! config reload) blends with the surface's transition
//! (`ghostty_surface_set_color_transition`); a second change during a
//! blend starts from the colors on screen, so a quick series never jumps.
//! Any other change (OSC 4/10/11/12 from a program, the cursor moving
//! onto a cell of another color) switches its entries at once.
const ColorBlend = @This();

const std = @import("std");
const global = @import("../global.zig");
const terminal = @import("../terminal/main.zig");

const RGB = terminal.color.RGB;

/// The source of a cell color: `0...255` a palette entry, `Slot.*` a
/// default or config color, `direct` the cell's own RGB.
pub const Ref = u16;

/// The cell's own RGB is the color (a true color): it switches at once.
pub const direct: Ref = 0xFFFF;

/// Table entries after the 256 palette entries.
pub const Slot = struct {
    pub const foreground: Ref = 256;
    pub const background: Ref = 257;
    pub const cursor: Ref = 258;
    pub const cursor_text: Ref = 259;
    pub const selection_background: Ref = 260;
    pub const selection_foreground: Ref = 261;
    pub const search_background: Ref = 262;
    pub const search_foreground: Ref = 263;
    pub const search_selected_background: Ref = 264;
    pub const search_selected_foreground: Ref = 265;
    pub const bold: Ref = 266;
};

/// Entries in the table: the palette, the slots, rounded up to a
/// multiple of 4 so the GLSL `uvec4` array covers it exactly.
pub const slot_count = 268;

/// The colors of every table entry (target colors when the renderer
/// builds it).
pub const Table = [slot_count]RGB;

/// The table as the shaders read it.
pub const ShaderTable = [slot_count][4]u8;

/// A color and its source.
pub const Paint = struct {
    rgb: RGB,
    ref: Ref,

    /// A color with no table entry (a true color).
    pub fn rgbOnly(rgb: RGB) Paint {
        return .{ .rgb = rgb, .ref = direct };
    }

    /// Table entry `ref` of `table`.
    pub fn entry(table: *const Table, ref: Ref) Paint {
        return .{ .rgb = table[ref], .ref = ref };
    }
};

pub const Space = enum(u8) { oklab = 0, srgb = 1 };

/// The most curve samples a transition carries.
pub const max_samples = 64;

/// How a config color change animates.
pub const Spec = struct {
    /// Zero: the change is instant (the upstream behavior).
    duration_ns: u64 = 0,
    space: Space = .oklab,
    /// Curve progress at `sample_count` evenly spaced time fractions,
    /// from 0 to 1. Fewer than 2 samples: linear.
    sample_count: u8 = 0,
    samples: [max_samples]f32 = @splat(0),

    pub const instant: Spec = .{};

    /// Curve progress at time fraction `fraction` (0...1).
    pub fn progress(self: *const Spec, fraction: f64) f64 {
        const f = std.math.clamp(fraction, 0, 1);
        if (self.sample_count < 2) return f;
        const last: f64 = @floatFromInt(self.sample_count - 1);
        const pos = f * last;
        const i: usize = @intFromFloat(@floor(pos));
        if (i + 1 >= self.sample_count) return self.samples[self.sample_count - 1];
        const a: f64 = self.samples[i];
        const b: f64 = self.samples[i + 1];
        return a + (b - a) * (pos - @floor(pos));
    }
};

/// The colors at the start of the running blend, or of the last change.
from: Table = std.mem.zeroes(Table),
/// The colors the cells were built with.
to: Table = std.mem.zeroes(Table),
/// `from` and `to` in `spec.space` components (OKLab or sRGB 0...1).
from_c: [slot_count][3]f32 = std.mem.zeroes([slot_count][3]f32),
to_c: [slot_count][3]f32 = std.mem.zeroes([slot_count][3]f32),
/// False until the first frame update: its colors show at once.
has_colors: bool = false,
/// The running blend: its curve and start. Null start: no blend.
spec: Spec = .instant,
start: ?std.Io.Timestamp = null,

/// Sets the colors the cells are built with. `config_change`: the change
/// came from the config at that time, so it blends with `spec` from the
/// colors shown now, on a clock that started then. Otherwise every entry
/// that changed shows its new color at once.
pub fn setTarget(
    self: *ColorBlend,
    new: *const Table,
    config_change: ?std.Io.Timestamp,
    spec: Spec,
) void {
    if (!self.has_colors) {
        self.has_colors = true;
        self.from = new.*;
        self.to = new.*;
        self.start = null;
        self.spec = .instant;
        return;
    }

    const now: std.Io.Timestamp = .now(global.io(), .awake);
    if (config_change != null and spec.duration_ns > 0 and !tablesEql(new, &self.to)) {
        // Retarget from the colors on screen now.
        var on_screen: Table = undefined;
        self.shownAt(now, &on_screen);
        self.from = on_screen;
        self.to = new.*;
        self.spec = spec;
        self.start = config_change;
        for (0..slot_count) |i| {
            self.from_c[i] = components(self.from[i], spec.space);
            self.to_c[i] = components(self.to[i], spec.space);
        }
        return;
    }

    if (!self.isRunningAt(now)) {
        self.start = null;
        self.from = new.*;
        self.to = new.*;
        return;
    }

    // A blend runs: entries that changed outside the config switch now.
    for (0..slot_count) |i| {
        if (new[i].eql(self.to[i])) continue;
        self.from[i] = new[i];
        self.to[i] = new[i];
        const c = components(new[i], self.spec.space);
        self.from_c[i] = c;
        self.to_c[i] = c;
    }
}

/// True while a blend runs: the renderer keeps drawing frames.
pub fn isRunning(self: *const ColorBlend) bool {
    if (self.start == null) return false;
    return self.isRunningAt(.now(global.io(), .awake));
}

fn isRunningAt(self: *const ColorBlend, now: std.Io.Timestamp) bool {
    const start = self.start orelse return false;
    const elapsed: i128 = start.durationTo(now).nanoseconds;
    return elapsed < self.spec.duration_ns;
}

/// The table shown in a frame drawn now.
pub fn shown(self: *const ColorBlend, out: *ShaderTable) void {
    var table: Table = undefined;
    self.shownAt(.now(global.io(), .awake), &table);
    for (table, out) |c, *o| o.* = .{ c.r, c.g, c.b, 255 };
}

fn shownAt(self: *const ColorBlend, now: std.Io.Timestamp, out: *Table) void {
    const start = self.start orelse {
        out.* = self.to;
        return;
    };
    const elapsed: i128 = start.durationTo(now).nanoseconds;
    if (elapsed >= self.spec.duration_ns) {
        out.* = self.to;
        return;
    }
    const fraction: f64 = @as(f64, @floatFromInt(@max(elapsed, 0))) /
        @as(f64, @floatFromInt(self.spec.duration_ns));
    const p = self.spec.progress(fraction);
    if (p <= 0) {
        out.* = self.from;
        return;
    }
    if (p >= 1) {
        out.* = self.to;
        return;
    }
    const pf: f32 = @floatCast(p);
    for (0..slot_count) |i| {
        if (self.from[i].eql(self.to[i])) {
            out[i] = self.to[i];
            continue;
        }
        const a = self.from_c[i];
        const b = self.to_c[i];
        out[i] = color(.{
            a[0] + (b[0] - a[0]) * pf,
            a[1] + (b[1] - a[1]) * pf,
            a[2] + (b[2] - a[2]) * pf,
        }, self.spec.space);
    }
}

fn tablesEql(a: *const Table, b: *const Table) bool {
    for (a, b) |x, y| if (!x.eql(y)) return false;
    return true;
}

// The mix is cmux-motion's `mix_rgba` (cmux-tui/crates/cmux-motion/src/
// color.rs) for opaque colors, so terminal text blends on the same path
// as the window's layer colors.

fn linear(c: f32) f32 {
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

fn gamma(c: f32) f32 {
    return if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
}

fn components(rgb: RGB, space: Space) [3]f32 {
    const r: f32 = @as(f32, @floatFromInt(rgb.r)) / 255.0;
    const g: f32 = @as(f32, @floatFromInt(rgb.g)) / 255.0;
    const b: f32 = @as(f32, @floatFromInt(rgb.b)) / 255.0;
    switch (space) {
        .srgb => return .{ r, g, b },
        .oklab => {
            const lr = linear(r);
            const lg = linear(g);
            const lb = linear(b);
            const l = std.math.cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb);
            const m = std.math.cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb);
            const s = std.math.cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb);
            return .{
                0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
            };
        },
    }
}

fn color(c: [3]f32, space: Space) RGB {
    const v: [3]f32 = switch (space) {
        .srgb => c,
        .oklab => oklab: {
            const l0 = c[0] + 0.3963377774 * c[1] + 0.2158037573 * c[2];
            const m0 = c[0] - 0.1055613458 * c[1] - 0.0638541728 * c[2];
            const s0 = c[0] - 0.0894841775 * c[1] - 1.2914855480 * c[2];
            const l = l0 * l0 * l0;
            const m = m0 * m0 * m0;
            const s = s0 * s0 * s0;
            break :oklab .{
                gamma(std.math.clamp(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s, 0, 1)),
                gamma(std.math.clamp(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s, 0, 1)),
                gamma(std.math.clamp(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s, 0, 1)),
            };
        },
    };
    return .{ .r = byte(v[0]), .g = byte(v[1]), .b = byte(v[2]) };
}

fn byte(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255.0));
}
