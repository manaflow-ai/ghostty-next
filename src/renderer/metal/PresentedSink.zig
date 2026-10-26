//! Delivers the embedder's presented callback (`ghostty_surface_presented_cb`)
//! from the drawable presented handlers, which Core Animation can run after
//! the surface is freed. The sink is reference counted (the renderer holds
//! one reference, each drawable handler one more), and `close` stops
//! delivery: after it returns no callback runs and none is running, so the
//! embedder may free the callback's userdata once `ghostty_surface_free`
//! returns. A callback in progress delays `close` only for its own run; the
//! contract in ghostty.h says it never blocks.
const PresentedSink = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../../global.zig");

/// ghostty_surface_presented_cb: userdata, frame id, the host time
/// (`mach_absolute_time`) at the callback, and the drawable's
/// `presentedTime` (seconds, `CACurrentMediaTime` base; 0 when the frame
/// was not shown).
pub const Callback = *const fn (?*anyopaque, u64, u64, f64) callconv(.c) void;

const closed_bit: u32 = 1 << 31;

alloc: Allocator,
refs: std.atomic.Value(u32) = .init(1),
/// `closed_bit` | the number of callbacks running.
state: std.atomic.Value(u32) = .init(0),
callback: ?Callback,
userdata: ?*anyopaque,

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

/// Any thread: run the callback unless the sink is closed.
pub fn deliver(self: *PresentedSink, frame_id: u64, host_time: u64, presented_time: f64) void {
    const cb = self.callback orelse return;
    if (self.state.fetchAdd(1, .acquire) & closed_bit != 0) {
        self.leave();
        return;
    }
    defer self.leave();
    cb(self.userdata, frame_id, host_time, presented_time);
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
    sink.deliver(7, 0, 1.5);
    try std.testing.expectEqual(@as(u32, 1), counter.calls.load(.acquire));
    try std.testing.expectEqual(@as(u64, 7), counter.last_frame.load(.acquire));

    sink.close();
    sink.release();
    // A handler that runs after the surface is freed calls nothing.
    handler_ref.deliver(8, 0, 0);
    try std.testing.expectEqual(@as(u32, 1), counter.calls.load(.acquire));
    handler_ref.release();
}

test "close waits for a callback in progress (teardown)" {
    var counter: TestCounter = .{};
    const sink = try PresentedSink.create(std.testing.allocator, &TestCounter.callback, &counter);
    defer sink.release();

    const presenter = try std.Thread.spawn(.{}, PresentedSink.deliver, .{ sink, 3, 0, 0 });
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
    sink.deliver(1, 0, 0);
    sink.close();
    sink.release();
}
