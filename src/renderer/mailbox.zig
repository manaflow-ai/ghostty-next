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
//! So producers never wait. Messages go to a fixed queue; when it is
//! full, a push with a waiting timeout (`.forever`, `.ns`) appends to an
//! overflow list instead, in order. Once the overflow holds a message,
//! every later push goes there too, so the renderer sees messages in
//! push order: the queue first, then the overflow. State messages whose
//! latest value wins (focus, visible, resize, cursor blink reset, display
//! id, presentation health) replace an older one of the same kind in the
//! overflow, which bounds it while the renderer is stalled. An `.instant`
//! push keeps its meaning: it fails when the queue is full.
const Mailbox = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const BlockingQueue = @import("../datastruct/main.zig").BlockingQueue;
const Message = @import("message.zig").Message;

const log = std.log.scoped(.renderer_mailbox);

const Queue = BlockingQueue(Message, capacity);

/// Messages the fixed queue holds before pushes overflow.
pub const capacity = 64;

pub const Size = Queue.Size;
pub const Timeout = Queue.Timeout;

alloc: Allocator,
queue: Queue,

/// Guards `overflow` and orders every push against it.
overflow_mutex: std.Io.Mutex = .init,

/// Messages pushed while the queue was full, oldest first.
overflow: std.ArrayListUnmanaged(Message) = .empty,

pub fn create(alloc: Allocator) Allocator.Error!*Mailbox {
    const self = try alloc.create(Mailbox);
    self.* = .{ .alloc = alloc, .queue = .{} };
    return self;
}

/// Free the mailbox. Call only after all producers and the consumer
/// stopped. Like the queue, it does not free undelivered messages.
pub fn destroy(self: *Mailbox, alloc: Allocator) void {
    self.overflow.deinit(self.alloc);
    alloc.destroy(self);
}

/// Push a message. Returns the number of undelivered messages after the
/// push, or zero if an `.instant` push found the queue full. Never waits
/// for the consumer unless the overflow cannot grow (out of memory).
pub fn push(
    self: *Mailbox,
    io: std.Io,
    value: Message,
    timeout: Timeout,
) Size {
    self.overflow_mutex.lockUncancelable(io);
    defer self.overflow_mutex.unlock(io);

    // The overflow holds older messages; this one must follow them.
    if (self.overflow.items.len == 0) {
        const n = self.queue.push(io, value, .instant);
        if (n > 0) return n;
    }

    if (timeout == .instant) return 0;

    if (coalesces(value)) {
        const tag = std.meta.activeTag(value);
        for (self.overflow.items, 0..) |existing, i| {
            if (std.meta.activeTag(existing) == tag) {
                _ = self.overflow.orderedRemove(i);
                break;
            }
        }
    }

    self.overflow.append(self.alloc, value) catch {
        // Keep the message. This waits for the consumer, which pops the
        // queue without the overflow lock. The order relative to the
        // overflow is lost; that is better than losing the message.
        log.warn("renderer mailbox overflow allocation failed, waiting", .{});
        return self.queue.push(io, value, timeout);
    };

    return std.math.cast(Size, capacity + self.overflow.items.len) orelse
        std.math.maxInt(Size);
}

/// Pop the oldest message without blocking. Only the renderer thread
/// calls this.
pub fn pop(self: *Mailbox, io: std.Io) ?Message {
    if (self.queue.pop(io)) |value| return value;

    self.overflow_mutex.lockUncancelable(io);
    defer self.overflow_mutex.unlock(io);
    if (self.overflow.items.len == 0) return null;
    return self.overflow.orderedRemove(0);
}

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
    try testing.expectEqual(@as(Size, 0), mailbox.push(io, .{ .inspector = true }, .instant));

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
