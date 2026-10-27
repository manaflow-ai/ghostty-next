//! Delivers the drawable presented handlers, which Core Animation can run
//! after the surface is freed, to the renderer (its observer, which asks main
//! to show the overlay) and to the embedder's presented callback
//! (`ghostty_surface_presented_cb`). The sink is reference counted (the
//! renderer holds one reference, each drawable handler one more), and
//! `close` stops delivery: after it returns no observer or callback runs and
//! none is running, so the renderer's memory and the callback's userdata may
//! be freed once `ghostty_surface_free` returns. A run in progress delays
//! `close` only for itself; neither the observer nor (by the contract in
//! ghostty.h) the callback blocks.
const PresentedSink = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../../global.zig");

/// ghostty_surface_presented_cb: userdata, frame id, the host time
/// (`mach_absolute_time`) at the callback, and the drawable's
/// `presentedTime` (seconds, `CACurrentMediaTime` base; 0 when the frame
/// was not shown).
pub const Callback = *const fn (?*anyopaque, u64, u64, f64) callconv(.c) void;

/// One drawable's presented handler.
pub const Presented = struct {
    /// The frame id (PresentState.Ticket.sequence).
    frame_id: u64,
    /// The hide generation the frame was encoded in.
    generation: u64,
    /// The frame's pixel size, packed (PresentState.pack).
    size: u64,
    /// `mach_absolute_time` when the handler ran.
    host_time: u64,
    /// The drawable's `presentedTime`; 0 when it was not shown.
    presented_time: f64,
};

/// The renderer's handler, run before the embedder's callback.
pub const Observer = *const fn (ctx: *anyopaque, presented: Presented) void;

const closed_bit: u32 = 1 << 31;

alloc: Allocator,
refs: std.atomic.Value(u32) = .init(1),
/// `closed_bit` | the number of callbacks running.
state: std.atomic.Value(u32) = .init(0),
callback: ?Callback,
userdata: ?*anyopaque,
observer: ?Observer = null,
/// Set once the renderer has its final address (`observe`).
observer_ctx: std.atomic.Value(?*anyopaque) = .init(null),

pub fn create(alloc: Allocator, callback: ?Callback, userdata: ?*anyopaque) Allocator.Error!*PresentedSink {
    const self = try alloc.create(PresentedSink);
    self.* = .{ .alloc = alloc, .callback = callback, .userdata = userdata };
    return self;
}

pub fn retain(self: *PresentedSink) *PresentedSink {
    _ = self.refs.fetchAdd(1, .monotonic);
    return self;
}

pub fn release(self: *PresentedSink) void {
    if (self.refs.fetchSub(1, .acq_rel) != 1) return;
    self.alloc.destroy(self);
}

/// The renderer's handler for each presented drawable, from now on.
/// Renderer thread, before it encodes a frame.
pub fn observe(self: *PresentedSink, observer: Observer, ctx: *anyopaque) void {
    self.observer = observer;
    self.observer_ctx.store(ctx, .release);
}

/// Any thread: run the observer and the callback unless the sink is closed.
pub fn deliver(self: *PresentedSink, presented: Presented) void {
    if (self.state.fetchAdd(1, .acquire) & closed_bit != 0) {
        self.leave();
        return;
    }
    defer self.leave();
    if (self.observer_ctx.load(.acquire)) |ctx| self.observer.?(ctx, presented);
    if (self.callback) |cb| cb(self.userdata, presented.frame_id, presented.host_time, presented.presented_time);
}

fn leave(self: *PresentedSink) void {
    const before = self.state.fetchSub(1, .release);
    if (before == closed_bit | 1) global.io().futexWake(u32, &self.state.raw, 1);
}

/// Stops delivery and waits for a running callback to return. Main thread,
/// once, when the renderer is freed.
pub fn close(self: *PresentedSink) void {
    var state = self.state.fetchOr(closed_bit, .acq_rel) | closed_bit;
    while (state != closed_bit) {
        global.io().futexWaitUncancelable(u32, &self.state.raw, state);
        state = self.state.load(.acquire);
    }
}

const TestCounter = struct {
    calls: std.atomic.Value(u32) = .init(0),
    last_frame: std.atomic.Value(u64) = .init(0),
    /// The callback waits here until the test lets it go.
    gate: std.atomic.Value(u32) = .init(1),
    entered: std.atomic.Value(u32) = .init(0),

    fn callback(ud: ?*anyopaque, frame_id: u64, _: u64, _: f64) callconv(.c) void {
        const self: *TestCounter = @ptrCast(@alignCast(ud.?));
        self.entered.store(1, .release);
        while (self.gate.load(.acquire) != 0) std.Thread.yield() catch {};
        self.last_frame.store(frame_id, .release);
        _ = self.calls.fetchAdd(1, .acq_rel);
    }
};

test "presented callbacks run until close and never after it" {
    var counter: TestCounter = .{ .gate = .init(0) };
    const sink = try PresentedSink.create(std.testing.allocator, &TestCounter.callback, &counter);
    // A drawable handler's reference outlives the renderer's.
    const handler_ref = sink.retain();
    sink.deliver(testPresented(7, 1.5));
    try std.testing.expectEqual(@as(u32, 1), counter.calls.load(.acquire));
    try std.testing.expectEqual(@as(u64, 7), counter.last_frame.load(.acquire));

    sink.close();
    sink.release();
    // A handler that runs after the surface is freed calls nothing.
    handler_ref.deliver(testPresented(8, 0));
    try std.testing.expectEqual(@as(u32, 1), counter.calls.load(.acquire));
    handler_ref.release();
}

test "close waits for a callback in progress (teardown)" {
    var counter: TestCounter = .{};
    const sink = try PresentedSink.create(std.testing.allocator, &TestCounter.callback, &counter);
    defer sink.release();

    const presenter = try std.Thread.spawn(.{}, PresentedSink.deliver, .{ sink, testPresented(3, 0) });
    while (counter.entered.load(.acquire) == 0) std.Thread.yield() catch {};

    var closed: std.atomic.Value(bool) = .init(false);
    const Closer = struct {
        fn run(s: *PresentedSink, done: *std.atomic.Value(bool)) void {
            s.close();
            done.store(true, .release);
        }
    };
    const closer = try std.Thread.spawn(.{}, Closer.run, .{ sink, &closed });
    // The callback still runs: close has not returned.
    for (0..1000) |_| std.Thread.yield() catch {};
    try std.testing.expect(!closed.load(.acquire));

    counter.gate.store(0, .release);
    closer.join();
    presenter.join();
    try std.testing.expect(closed.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), counter.calls.load(.acquire));
}

test "a sink without a callback delivers nothing and closes at once" {
    const sink = try PresentedSink.create(std.testing.allocator, null, null);
    sink.deliver(testPresented(1, 0));
    sink.close();
    sink.release();
}

test "the observer runs before the callback, and never after close" {
    const Seen = struct {
        frames: std.atomic.Value(u64) = .init(0),
        generation: std.atomic.Value(u64) = .init(0),
        fn observe(ctx: *anyopaque, p: Presented) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.generation.store(p.generation, .release);
            _ = self.frames.fetchAdd(1, .acq_rel);
        }
    };
    var seen: Seen = .{};
    var counter: TestCounter = .{ .gate = .init(0) };
    const sink = try PresentedSink.create(std.testing.allocator, &TestCounter.callback, &counter);
    // A drawable presented before the renderer observes: the callback only.
    sink.deliver(testPresented(1, 0));
    sink.observe(&Seen.observe, &seen);
    var p = testPresented(2, 0.5);
    p.generation = 9;
    sink.deliver(p);
    try std.testing.expectEqual(@as(u64, 1), seen.frames.load(.acquire));
    try std.testing.expectEqual(@as(u64, 9), seen.generation.load(.acquire));
    try std.testing.expectEqual(@as(u32, 2), counter.calls.load(.acquire));
    const handler_ref = sink.retain();
    sink.close();
    sink.release();
    // After teardown the renderer's memory is gone: no observer run.
    handler_ref.deliver(testPresented(3, 0.5));
    try std.testing.expectEqual(@as(u64, 1), seen.frames.load(.acquire));
    handler_ref.release();
}

test "a sink without an embedder callback still runs the observer" {
    const Seen = struct {
        n: u32 = 0,
        fn observe(ctx: *anyopaque, _: Presented) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.n += 1;
        }
    };
    var seen: Seen = .{};
    const sink = try PresentedSink.create(std.testing.allocator, null, null);
    sink.observe(&Seen.observe, &seen);
    sink.deliver(testPresented(1, 0));
    try std.testing.expectEqual(@as(u32, 1), seen.n);
    sink.close();
    sink.release();
}

fn testPresented(frame_id: u64, presented_time: f64) Presented {
    return .{
        .frame_id = frame_id,
        .generation = 1,
        .size = 0,
        .host_time = 0,
        .presented_time = presented_time,
    };
}
