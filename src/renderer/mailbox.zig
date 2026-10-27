//! The renderer thread's mailbox.
//!
//! Surface calls (resize, focus, occlusion, font and config changes) and
//! output parsing post messages here. The renderer thread drains it when
//! it wakes, but it can be busy for a long time: waiting for a free frame
//! while the GPU is slow, or while the system holds back GPU completions
//! (an iOS app in the background). A bounded queue that blocks its
//! producers when full would then block the main thread or the output
//! queue on the GPU.
//!
//! So producers never wait: the mailbox is an OverflowQueue
//! (datastruct/overflow_queue.zig). When the fixed queue is full, pushes
//! with a waiting timeout overflow in order. State messages whose latest
//! value wins (focus, visible, resize, cursor blink reset, display id,
//! presentation health) replace an older one of the same kind in the
//! overflow, which bounds it while the renderer is stalled. An `.instant`
//! push keeps its meaning: it fails when the queue is full.
const std = @import("std");
const OverflowQueue = @import("../datastruct/main.zig").OverflowQueue;
const Message = @import("message.zig").Message;

/// Messages the fixed queue holds before pushes overflow.
pub const capacity = 64;

pub const Mailbox = OverflowQueue(Message, capacity, .{ .replaces = coalesces });

/// True for messages that only carry the latest state and own no memory.
fn coalesces(value: Message) bool {
    return switch (value) {
        .focus,
        .visible,
        .resize,
        .reset_cursor_blink,
        .macos_display_id,
        .presentation_health,
        => true,
        else => false,
    };
}

test "renderer mailbox: a full mailbox never blocks and keeps order" {
    const testing = std.testing;
    const io = testing.io;

    const mailbox = try Mailbox.create(testing.allocator);
    defer mailbox.destroy(testing.allocator);

    // Fill the queue.
    for (0..capacity) |i| {
        try testing.expect(mailbox.push(io, .{ .macos_display_id = @intCast(i) }, .forever) > 0);
    }

    // An instant push fails as before.
    try testing.expectEqual(@as(Mailbox.Size, 0), mailbox.push(io, .{ .inspector = true }, .instant));

    // Waiting pushes overflow without blocking. Latest-wins state
    // replaces its older value; other messages keep every copy.
    try testing.expect(mailbox.push(io, .{ .inspector = true }, .forever) > 0);
    try testing.expect(mailbox.push(io, .{ .focus = true }, .forever) > 0);
    try testing.expect(mailbox.push(io, .{ .inspector = false }, .forever) > 0);
    try testing.expect(mailbox.push(io, .{ .focus = false }, .{ .ns = 1 }) > 0);
    try testing.expectEqual(@as(usize, 3), mailbox.overflow.items.len);

    for (0..capacity) |i| {
        const value = mailbox.pop(io).?;
        try testing.expectEqual(@as(u32, @intCast(i)), value.macos_display_id);
    }

    // The queue has room now, but pushes stay behind the overflow.
    try testing.expect(mailbox.push(io, .{ .visible = true }, .instant) == 0);
    try testing.expect(mailbox.push(io, .{ .visible = false }, .forever) > 0);

    try testing.expectEqual(true, mailbox.pop(io).?.inspector);
    try testing.expectEqual(false, mailbox.pop(io).?.inspector);
    try testing.expectEqual(false, mailbox.pop(io).?.focus);
    try testing.expectEqual(false, mailbox.pop(io).?.visible);
    try testing.expect(mailbox.pop(io) == null);

    // With the overflow empty, pushes use the queue again.
    try testing.expect(mailbox.push(io, .{ .visible = true }, .instant) > 0);
    try testing.expectEqual(true, mailbox.pop(io).?.visible);
    try testing.expect(mailbox.pop(io) == null);
}
