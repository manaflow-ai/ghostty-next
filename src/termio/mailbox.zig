const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const xev = global.xev;
const renderer = @import("../renderer.zig");
const termio = @import("../termio.zig");
const OverflowQueue = @import("../datastruct/main.zig").OverflowQueue;

const log = std.log.scoped(.io_writer);

/// A queue used for storing messages that is periodically drained.
/// Typically used by a multi-threaded application. The capacity is
/// hardcoded to a value that empirically has made sense for Ghostty usage
/// but I'm open to changing it with good arguments.
const Queue = OverflowQueue(termio.Message, 64, .{
    .replaces = replaces,
    .merge = merge,
});

/// What a send does when the queue is full.
pub const Backpressure = enum {
    /// Wait until the termio thread pops a message. For a termio thread
    /// with its own loop (termio.Thread `.own`), which only waits on the
    /// PTY.
    block,

    /// Never wait: the message overflows, in order (OverflowQueue). For
    /// handlers hosted on the renderer thread (termio.Thread `.hosted`),
    /// which can wait a long time for a GPU frame; a blocking send would
    /// then block the main thread or the output queue on the GPU.
    overflow,
};

/// The location to where write-related messages are sent.
pub const Mailbox = union(enum) {
    // /// Write messages to an unbounded list backed by an allocator.
    // /// This is useful for single-threaded applications where you're not
    // /// afraid of running out of memory. You should be careful that you're
    // /// processing this in a timely manner though since some heavy workloads
    // /// will produce a LOT of messages.
    // ///
    // /// At the time of authoring this, the primary use case for this is
    // /// testing more than anything, but it probably will have a use case
    // /// in libghostty eventually.
    // unbounded: std.ArrayList(termio.Message),

    /// Write messages to a SPSC queue for multi-threaded applications.
    spsc: struct {
        queue: *Queue,
        wakeup: xev.Async,
        backpressure: Backpressure,
    },

    /// Init the SPSC writer.
    pub fn initSPSC(alloc: Allocator, backpressure: Backpressure) !Mailbox {
        var queue = try Queue.create(alloc);
        errdefer queue.destroy(alloc);

        var wakeup = try xev.Async.init();
        errdefer wakeup.deinit();

        return .{ .spsc = .{
            .queue = queue,
            .wakeup = wakeup,
            .backpressure = backpressure,
        } };
    }

    pub fn deinit(self: *Mailbox, alloc: Allocator) void {
        switch (self.*) {
            .spsc => |*v| {
                while (v.queue.pop(global.io())) |msg| msg.deinit();
                v.queue.destroy(alloc);
                v.wakeup.deinit();
            },
        }
    }

    /// Sends the given message without notifying there are messages.
    ///
    /// If the optional mutex is given, it must already be LOCKED. If the
    /// send would block (`.block` only), we'll unlock this mutex, resend
    /// the message, and lock it again. This handles an edge case where
    /// queues are full. An `.overflow` mailbox never waits.
    pub fn send(
        self: *Mailbox,
        msg: termio.Message,
        mutex: ?*std.Io.Mutex,
    ) void {
        switch (self.*) {
            .spsc => |*mb| send: {
                if (mb.backpressure == .overflow) {
                    if (mb.queue.push(global.io(), msg, .forever) == 0) msg.deinit();
                    break :send;
                }

                // A `.block` mailbox never overflows, so it uses the fixed
                // queue directly. Try to write to the queue with an instant
                // timeout. This is the fast path because we can queue
                // without a lock.
                if (mb.queue.fixed.push(global.io(), msg, .{ .instant = {} }) > 0) break :send;

                // If we enter this conditional, the queue is full. We wake up
                // the writer thread so that it can process messages to clear up
                // space. However, the writer thread may require the renderer
                // lock so we need to unlock.
                mb.wakeup.notify() catch |err| {
                    log.warn("failed to wake up writer, data will be dropped err={}", .{err});
                    msg.deinit();
                    return;
                };

                // Unlock the renderer state so the writer thread can acquire it.
                // Then try to queue our message before continuing. This is a very
                // slow path because we are having a lot of contention for data.
                // But this only gets triggered in certain pathological cases.
                //
                // Note that writes themselves don't require a lock, but there
                // are other messages in the writer queue (resize, focus) that
                // could acquire the lock. This is why we have to release our lock
                // here.
                if (mutex) |m| m.unlock(global.io());
                defer if (mutex) |m| m.lockUncancelable(global.io());
                if (mb.queue.fixed.push(global.io(), msg, .{ .forever = {} }) == 0) msg.deinit();
            },
        }
    }

    /// Notify that there are new messages. This may be a noop depending
    /// on the writer type.
    pub fn notify(self: *Mailbox) void {
        switch (self.*) {
            .spsc => |*v| v.wakeup.notify() catch |err| {
                log.warn("failed to notify writer, data will be dropped err={}", .{err});
            },
        }
    }
};

/// Latest-wins messages that own no memory: a newer one replaces the older
/// one in the overflow.
fn replaces(msg: termio.Message) bool {
    return switch (msg) {
        .resize, .selection_scroll, .inspector => true,
        else => false,
    };
}

/// Fold a scroll into the adjacent scroll before it in the overflow: a
/// burst of wheel or viewport scrolls while the consumer is stalled stays
/// one message.
fn merge(newest: *termio.Message, msg: termio.Message) bool {
    switch (msg) {
        .scroll_viewport => |v| {
            if (newest.* != .scroll_viewport) return false;
            switch (v) {
                .delta => |d| {
                    if (newest.scroll_viewport != .delta) return false;
                    newest.scroll_viewport.delta +|= d;
                },
                // An absolute target makes the scroll before it moot.
                else => newest.* = msg,
            }
            return true;
        },
        .scroll_wheel => |w| {
            if (newest.* != .scroll_wheel) return false;
            const n = &newest.scroll_wheel;
            if (!n.mods.equal(w.mods) or
                n.any_button_pressed != w.any_button_pressed or
                n.mouse_reporting != w.mouse_reporting or
                (n.delta_y > 0) != (w.delta_y > 0)) return false;
            n.delta_y +|= w.delta_y;
            n.x = w.x;
            n.y = w.y;
            return true;
        },
        else => return false,
    }
}

test "termio mailbox: an overflow send never waits and folds scrolls" {
    const testing = std.testing;
    const io = global.io();

    var mailbox = try Mailbox.initSPSC(testing.allocator, .overflow);
    defer mailbox.deinit(testing.allocator);
    const queue = mailbox.spsc.queue;

    // Nothing pops: the fixed queue fills, then sends overflow.
    for (0..64) |_| mailbox.send(.{ .jump_to_prompt = 1 }, null);
    for (0..100) |_| mailbox.send(.{ .scroll_viewport = .{ .delta = 2 } }, null);
    for (0..10) |_| mailbox.send(.{ .jump_to_prompt = -1 }, null);
    mailbox.send(.{ .scroll_viewport = .{ .delta = 5 } }, null);
    mailbox.send(.{ .scroll_viewport = .{ .bottom = {} } }, null);
    const wheel: termio.Message.ScrollWheel = .{
        .delta_y = 1,
        .x = 0,
        .y = 0,
        .mods = .{},
        .any_button_pressed = false,
        .mouse_reporting = true,
    };
    for (0..50) |i| {
        var w = wheel;
        w.x = @floatFromInt(i);
        mailbox.send(.{ .scroll_wheel = w }, null);
    }
    var down = wheel;
    down.delta_y = -3;
    mailbox.send(.{ .scroll_wheel = down }, null);
    mailbox.send(.{ .selection_scroll = true }, null);
    mailbox.send(.{ .selection_scroll = false }, null);

    // The queue first, in order.
    for (0..64) |_| try testing.expectEqual(@as(isize, 1), queue.pop(io).?.jump_to_prompt);

    // Then the overflow: adjacent scrolls folded, others kept in order.
    try testing.expectEqual(@as(isize, 200), queue.pop(io).?.scroll_viewport.delta);
    for (0..10) |_| try testing.expectEqual(@as(isize, -1), queue.pop(io).?.jump_to_prompt);
    try testing.expect(queue.pop(io).?.scroll_viewport == .bottom);
    const up = queue.pop(io).?.scroll_wheel;
    try testing.expectEqual(@as(isize, 50), up.delta_y);
    try testing.expectEqual(@as(f32, 49), up.x);
    try testing.expectEqual(@as(isize, -3), queue.pop(io).?.scroll_wheel.delta_y);
    try testing.expectEqual(false, queue.pop(io).?.selection_scroll);
    try testing.expect(queue.pop(io) == null);
}
