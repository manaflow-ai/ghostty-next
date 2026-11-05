//! The per-frame cost of the renderer's reflow preview
//! (`renderer/ReflowPreview.zig`): during a resize gesture every frame
//! draws the terminal re-wrapped at that frame's grid without changing
//! the live terminal. Each frame here is what the renderer thread does
//! for one frame of a divider drag: `update` (the copy under the
//! terminal lock, the reflow off it) and `source` (under the lock), at a
//! new grid every frame.
//!
//! Each step runs `frames` frames: the width steps down one column per
//! frame and back, and the height changes every 8 frames. At the end of
//! the run it prints the per-frame p50, p95, p99 and max, and the time
//! of `source` alone. Run: `ghostty-bench +reflow-preview` (zig build -Demit-bench).
const ReflowPreviewBench = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const terminalpkg = @import("../terminal/main.zig");
const renderer = @import("../renderer.zig");
const ReflowPreview = @import("../renderer/ReflowPreview.zig");
const Benchmark = @import("Benchmark.zig");
const global = @import("../global.zig");
const Terminal = terminalpkg.Terminal;

opts: Options,
alloc: Allocator,
terminal: Terminal,
mutex: std.Io.Mutex = .init,
state: renderer.State = undefined,
preview: ReflowPreview = .{},
total: std.ArrayList(u64) = .empty,
locked: std.ArrayList(u64) = .empty,
copy_ns: std.ArrayList(u64) = .empty,
reflow_ns: std.ArrayList(u64) = .empty,

pub const Options = struct {
    @"terminal-cols": u16 = 200,
    @"terminal-rows": u16 = 60,

    /// Lines written before the run: history and a full screen of
    /// soft-wrapped, styled lines.
    @"fill-lines": u32 = 2000,

    /// Frames per step (one gesture).
    frames: u32 = 160,

    /// Steps (gestures) per run.
    loops: u32 = 5,

    /// Also time the two parts of a rebuild apart: the copy of the live
    /// terminal (under the terminal lock) and the reflow of the copy (off
    /// the lock).
    split: bool = true,
};

pub fn create(alloc: Allocator, opts: Options) !*ReflowPreviewBench {
    const ptr = try alloc.create(ReflowPreviewBench);
    errdefer alloc.destroy(ptr);
    ptr.* = .{
        .opts = opts,
        .alloc = alloc,
        .terminal = try .init(global.io(), alloc, .{
            .cols = opts.@"terminal-cols",
            .rows = opts.@"terminal-rows",
            .max_scrollback_bytes = 10_000_000,
        }),
    };
    ptr.state = .{ .mutex = &ptr.mutex, .terminal = &ptr.terminal };
    return ptr;
}

pub fn destroy(self: *ReflowPreviewBench, alloc: Allocator) void {
    report("frame", self.total.items);
    report("source (under the lock; the copy in update also holds it)", self.locked.items);
    report("split: copy (under the terminal lock)", self.copy_ns.items);
    report("split: reflow (off the lock)", self.reflow_ns.items);
    std.debug.print("reflow-preview copies under the terminal lock: {d} for {d} frames\n", .{ self.preview.locked_copies, self.total.items.len });
    self.total.deinit(alloc);
    self.locked.deinit(alloc);
    self.copy_ns.deinit(alloc);
    self.reflow_ns.deinit(alloc);
    self.preview.deinit(alloc);
    self.terminal.deinit(alloc);
    alloc.destroy(self);
}

fn report(name: []const u8, items: []u64) void {
    if (items.len == 0) return;
    std.mem.sort(u64, items, {}, std.sort.asc(u64));
    const at = struct {
        fn f(v: []const u64, pct: usize) u64 {
            return v[@min(v.len - 1, v.len * pct / 100)];
        }
    }.f;
    std.debug.print(
        "reflow-preview {s}: n={d} p50={d}us p95={d}us p99={d}us max={d}us\n",
        .{ name, items.len, at(items, 50) / 1000, at(items, 95) / 1000, at(items, 99) / 1000, items[items.len - 1] / 1000 },
    );
}

pub fn benchmark(self: *ReflowPreviewBench) Benchmark {
    return .init(self, .{ .stepFn = step, .setupFn = setup });
}

fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ReflowPreviewBench = @ptrCast(@alignCast(ptr));
    var s = self.terminal.vtStream();
    defer s.deinit();
    var line: [600]u8 = undefined;
    for (0..self.opts.@"fill-lines") |i| {
        if (i % 4 == 0) s.nextSlice("\x1b[1;32m");
        for (&line, 0..) |*ch, j| ch.* = if (j % 9 == 8) ' ' else @intCast('a' + (i + j) % 26);
        const n = 60 + (i * 37) % 500;
        s.nextSlice(line[0..n]);
        s.nextSlice("\x1b[m\r\n");
    }
}

fn step(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ReflowPreviewBench = @ptrCast(@alignCast(ptr));
    const io = global.io();
    const cols = self.opts.@"terminal-cols";
    const rows = self.opts.@"terminal-rows";
    const half = self.opts.frames / 2;
    for (0..self.opts.loops) |_| {
        for (0..self.opts.frames) |i| {
            const d: u16 = @intCast(if (i < half) i else self.opts.frames - 1 - i);
            const fit: renderer.GridSize = .{
                .columns = @max(10, cols -| (1 + d)),
                .rows = @max(2, rows - @as(u16, @intCast((i / 8) % 4))),
            };
            const t0: std.Io.Timestamp = .now(io, .awake);
            self.preview.update(self.alloc, &self.state, true, fit);
            const t1: std.Io.Timestamp = .now(io, .awake);
            var lock_ns: i96 = 0;
            {
                self.state.lockDemand(io);
                defer self.state.unlockDemand(io);
                const drawn = self.preview.source(self.alloc, true, self.state.terminal, fit);
                if (drawn.cols != fit.columns) return error.BenchmarkFailed;
            }
            const t2: std.Io.Timestamp = .now(io, .awake);
            lock_ns = t1.durationTo(t2).nanoseconds;
            self.total.append(self.alloc, @intCast(t0.durationTo(t2).nanoseconds)) catch return error.BenchmarkFailed;
            self.locked.append(self.alloc, @intCast(lock_ns)) catch return error.BenchmarkFailed;
            if (self.opts.split) try self.splitFrame(fit);
        }
    }
    if (self.terminal.cols != cols or self.terminal.rows != rows) return error.BenchmarkFailed;
}

/// One rebuild at `fit`, its copy and its reflow timed apart.
fn splitFrame(self: *ReflowPreviewBench, fit: renderer.GridSize) Benchmark.Error!void {
    const io = global.io();
    const t0: std.Io.Timestamp = .now(io, .awake);
    var copy = copy: {
        self.state.lockDemand(io);
        defer self.state.unlockDemand(io);
        break :copy ReflowPreview.snapshot(self.alloc, self.state.terminal, ReflowPreview.historyNeed(self.state.terminal.cols, fit)) catch return error.BenchmarkFailed;
    };
    defer copy.deinit(self.alloc);
    const t1: std.Io.Timestamp = .now(io, .awake);
    ReflowPreview.reflow(self.alloc, &copy, fit) catch return error.BenchmarkFailed;
    const t2: std.Io.Timestamp = .now(io, .awake);
    self.copy_ns.append(self.alloc, @intCast(t0.durationTo(t1).nanoseconds)) catch return error.BenchmarkFailed;
    self.reflow_ns.append(self.alloc, @intCast(t1.durationTo(t2).nanoseconds)) catch return error.BenchmarkFailed;
}
