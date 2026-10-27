//! A message queue whose producers never wait for the consumer.
//!
//! For a consumer that can be busy for a long time, for example a thread
//! that waits for a free GPU frame (or for GPU completions the system holds
//! back, an iOS app in the background). A bounded queue that blocks its
//! producers when full would then block them, often the main thread, on
//! the GPU.
//!
//! Values go to a fixed queue; when it is full, a push with a waiting
//! timeout (`.forever`, `.ns`) appends to an overflow list instead, in
//! order. Once the overflow holds a value, every later push goes there
//! too, so the consumer sees values in push order: the queue first, then
//! the overflow. The `Policy` bounds the overflow while the consumer is
//! stalled. An `.instant` push keeps its meaning: it fails when the queue
//! is full.
const std = @import("std");
const Allocator = std.mem.Allocator;
const BlockingQueue = @import("blocking_queue.zig").BlockingQueue;

const log = std.log.scoped(.overflow_queue);

/// How a push folds into the overflow. Both hooks apply only to values
/// that own no memory: the value they drop is not freed.
pub fn Policy(comptime T: type) type {
    return struct {
        /// Latest-wins state: a push of such a value removes the older value
        /// of the same tag from the overflow.
        replaces: fn (value: T) bool = never,

        /// Fold `value` into `newest`, the newest overflow value, when the
        /// two can be one (for example two scroll deltas). Returns true if
        /// it did; `value` is then not added. Order is kept because only
        /// adjacent values merge.
        merge: fn (newest: *T, value: T) bool = neverMerge,

        fn never(_: T) bool {
            return false;
        }

        fn neverMerge(_: *T, _: T) bool {
            return false;
        }
    };
}

/// Returns a never-blocking queue of `T` with a fixed part of `capacity`
/// values. `T` must be a tagged union if `policy.replaces` is set.
pub fn OverflowQueue(
    comptime T: type,
    comptime capacity: usize,
    comptime policy: Policy(T),
) type {
    return struct {
        const Self = @This();

        pub const Fixed = BlockingQueue(T, capacity);
        pub const Size = Fixed.Size;
        pub const Timeout = Fixed.Timeout;

        alloc: Allocator,

        /// The fixed queue. A consumer that only uses `.instant` or a
        /// producer that wants to wait may use it directly, but only while
        /// the overflow is empty and stays empty (no `push` with a waiting
        /// timeout), or values lose their order.
        fixed: Fixed = .{},

        /// Guards `overflow` and orders every push against it.
        overflow_mutex: std.Io.Mutex = .init,

        /// Values pushed while the queue was full, oldest first.
        overflow: std.ArrayListUnmanaged(T) = .empty,

        pub fn create(alloc: Allocator) Allocator.Error!*Self {
            const self = try alloc.create(Self);
            self.* = .{ .alloc = alloc };
            return self;
        }

        /// Free the queue. Call only after all producers and the consumer
        /// stopped. Like BlockingQueue, it does not free undelivered values.
        pub fn destroy(self: *Self, alloc: Allocator) void {
            self.overflow.deinit(self.alloc);
            alloc.destroy(self);
        }

        /// Push a value. Returns the number of undelivered values after the
        /// push, or zero if an `.instant` push found the queue full. Never
        /// waits for the consumer unless the overflow cannot grow (out of
        /// memory).
        pub fn push(
            self: *Self,
            io: std.Io,
            value: T,
            timeout: Timeout,
        ) Size {
            self.overflow_mutex.lockUncancelable(io);
            defer self.overflow_mutex.unlock(io);

            // The overflow holds older values; this one must follow them.
            if (self.overflow.items.len == 0) {
                const n = self.fixed.push(io, value, .instant);
                if (n > 0) return n;
            }

            if (timeout == .instant) return 0;

            if (self.overflow.items.len > 0 and
                policy.merge(&self.overflow.items[self.overflow.items.len - 1], value))
            {
                return self.pending();
            }

            if (policy.replaces(value)) {
                const tag = std.meta.activeTag(value);
                for (self.overflow.items, 0..) |existing, i| {
                    if (std.meta.activeTag(existing) == tag) {
                        _ = self.overflow.orderedRemove(i);
                        break;
                    }
                }
            }

            self.overflow.append(self.alloc, value) catch {
                // Keep the value. This waits for the consumer, which pops
                // the queue without the overflow lock. The order relative
                // to the overflow is lost; that is better than losing it.
                log.warn("overflow allocation failed, waiting for the consumer", .{});
                return self.fixed.push(io, value, timeout);
            };

            return self.pending();
        }

        /// Pop the oldest value without blocking. Only the consumer calls
        /// this.
        pub fn pop(self: *Self, io: std.Io) ?T {
            if (self.fixed.pop(io)) |value| return value;

            self.overflow_mutex.lockUncancelable(io);
            defer self.overflow_mutex.unlock(io);
            if (self.overflow.items.len == 0) return null;
            return self.overflow.orderedRemove(0);
        }

        /// The undelivered count once the overflow is in use. Call with
        /// the overflow lock held.
        fn pending(self: *const Self) Size {
            return std.math.cast(Size, capacity + self.overflow.items.len) orelse
                std.math.maxInt(Size);
        }
    };
}

test "overflow queue: merges fold only into the newest overflow value" {
    const testing = std.testing;
    const io = testing.io;

    const Value = union(enum) {
        delta: i32,
        mark: u8,

        fn merge(newest: *@This(), value: @This()) bool {
            if (newest.* != .delta or value != .delta) return false;
            newest.delta += value.delta;
            return true;
        }
    };
    const Queue = OverflowQueue(Value, 2, .{ .merge = Value.merge });

    const q = try Queue.create(testing.allocator);
    defer q.destroy(testing.allocator);

    // The fixed queue never merges.
    try testing.expect(q.push(io, .{ .delta = 1 }, .forever) > 0);
    try testing.expect(q.push(io, .{ .delta = 2 }, .forever) > 0);

    // In the overflow, adjacent deltas fold; a mark in between keeps
    // the deltas on each side of it apart.
    try testing.expect(q.push(io, .{ .delta = 3 }, .forever) > 0);
    try testing.expect(q.push(io, .{ .delta = 4 }, .forever) > 0);
    try testing.expect(q.push(io, .{ .mark = 1 }, .forever) > 0);
    try testing.expect(q.push(io, .{ .delta = 5 }, .forever) > 0);
    try testing.expect(q.push(io, .{ .delta = 6 }, .forever) > 0);
    try testing.expectEqual(@as(usize, 3), q.overflow.items.len);

    try testing.expectEqual(@as(i32, 1), q.pop(io).?.delta);
    try testing.expectEqual(@as(i32, 2), q.pop(io).?.delta);
    try testing.expectEqual(@as(i32, 7), q.pop(io).?.delta);
    try testing.expectEqual(@as(u8, 1), q.pop(io).?.mark);
    try testing.expectEqual(@as(i32, 11), q.pop(io).?.delta);
    try testing.expect(q.pop(io) == null);
}
