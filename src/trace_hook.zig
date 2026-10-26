//! The process-wide trace hook (`ghostty_set_trace_hook`, ghostty.h): the
//! embedder's callback for a surface's render, GPU, present and IO events,
//! so it can place them on its own trace (cmux-next's Perfetto recording).
//!
//! Off, an event site costs one atomic load and one branch, the cost of a
//! Chromium TRACE_EVENT site that reads its category's enabled flag
//! (base/trace_event/trace_event.h, `category_group_enabled`).
const std = @import("std");

/// ghostty_trace_event_e.
pub const Event = enum(c_int) {
    /// A draw starts (the renderer thread, or the main thread's display
    /// pass). seq: the number the draw's frame gets if it commits one.
    frame_begin = 0,
    /// The draw ends. seq: the number of the frame it committed to the GPU,
    /// or 0 when it committed none (nothing changed).
    frame_end = 1,
    /// A frame's IOSurface became the layer's contents. seq: frame number.
    contents_set = 2,
    /// The GPU completed a frame (the command buffer's completed handler).
    /// seq: frame number.
    gpu_done = 3,
    /// Ghostty passed encoded input to the manual IO write callback.
    /// seq: the byte count.
    io_write = 4,
    /// ghostty_surface_free returned for the surface. seq: 0.
    surface_destroy = 5,
};

/// ghostty_trace_hook_cb: (ctx, event, surface trace id, seq).
pub const Callback = *const fn (?*anyopaque, Event, u64, u64) callconv(.c) void;

/// ghostty_trace_hook_s. The embedder owns it and never changes or frees
/// it once installed: a call can read it after a later install returns.
pub const Hook = extern struct {
    callback: ?Callback = null,
    ctx: ?*anyopaque = null,
};

var installed: std.atomic.Value(?*const Hook) = .init(null);
var last_surface_id: std.atomic.Value(u64) = .init(0);

/// Installs `hook`, or turns tracing off with null (or a null callback).
pub fn install(hook: ?*const Hook) void {
    const on: ?*const Hook = if (hook) |h| (if (h.callback != null) h else null) else null;
    installed.store(on, .release);
}

/// Reports `event` to the installed hook, if any.
pub inline fn emit(event: Event, surface: u64, seq: u64) void {
    const hook = installed.load(.acquire) orelse return;
    hook.callback.?(hook.ctx, event, surface, seq);
}

/// A surface trace id: nonzero, never reused in this process.
pub fn newSurfaceId() u64 {
    return last_surface_id.fetchAdd(1, .monotonic) + 1;
}

const TestSink = struct {
    var events: [8]struct { Event, u64, u64 } = undefined;
    var count: usize = 0;
    var ctx_seen: ?*anyopaque = null;

    fn cb(ctx: ?*anyopaque, event: Event, surface: u64, seq: u64) callconv(.c) void {
        ctx_seen = ctx;
        events[count] = .{ event, surface, seq };
        count += 1;
    }

    fn expectEvent(i: usize, event: Event, surface: u64, seq: u64) !void {
        const testing = std.testing;
        try testing.expectEqual(event, events[i][0]);
        try testing.expectEqual(surface, events[i][1]);
        try testing.expectEqual(seq, events[i][2]);
    }

    fn reset() void {
        count = 0;
        ctx_seen = null;
    }
};

test "trace hook: an installed hook gets each event with its ctx" {
    const testing = std.testing;
    defer install(null);
    TestSink.reset();
    var marker: u8 = 0;
    const hook: Hook = .{ .callback = &TestSink.cb, .ctx = &marker };
    install(&hook);

    emit(.frame_begin, 7, 3);
    emit(.gpu_done, 7, 3);
    emit(.io_write, 9, 12);

    try testing.expectEqual(@as(usize, 3), TestSink.count);
    try testing.expectEqual(@as(?*anyopaque, &marker), TestSink.ctx_seen);
    try TestSink.expectEvent(0, .frame_begin, 7, 3);
    try TestSink.expectEvent(1, .gpu_done, 7, 3);
    try TestSink.expectEvent(2, .io_write, 9, 12);
}

test "trace hook: off calls nothing" {
    const testing = std.testing;
    TestSink.reset();
    var hook: Hook = .{ .callback = &TestSink.cb };
    install(&hook);
    install(null);
    emit(.frame_end, 1, 1);
    try testing.expectEqual(@as(usize, 0), TestSink.count);

    // A record without a callback is off too, not a null call.
    hook.callback = null;
    install(&hook);
    defer install(null);
    emit(.surface_destroy, 1, 0);
    try testing.expectEqual(@as(usize, 0), TestSink.count);
}

test "trace hook: surface ids are nonzero and unique" {
    const testing = std.testing;
    const a = newSurfaceId();
    const b = newSurfaceId();
    try testing.expect(a != 0);
    try testing.expect(b > a);
}

test "ghostty.h TraceEvent" {
    try @import("lib/enum.zig").checkGhosttyHEnum(Event, "GHOSTTY_TRACE_");
}

test "ghostty.h trace hook record" {
    const testing = std.testing;
    const c = @import("ghostty.h");
    const T = c.ghostty_trace_hook_s;
    try testing.expectEqual(@offsetOf(Hook, "callback"), @offsetOf(T, "callback"));
    try testing.expectEqual(@offsetOf(Hook, "ctx"), @offsetOf(T, "ctx"));
    try testing.expectEqual(@sizeOf(Hook), @sizeOf(T));
}
