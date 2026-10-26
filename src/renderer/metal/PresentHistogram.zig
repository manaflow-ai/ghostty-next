//! Durations of the present-form spike (OffMainPresenter: the renderer's
//! `nextDrawable` wait or its transaction commit), safe to record from any
//! thread. Bucket 0 holds durations below 1 us; bucket i (i > 0) holds
//! durations from 2^(i-1) us to below 2^i us; the last bucket also holds
//! everything above it. Count, sum and max are exact.
const PresentHistogram = @This();

const std = @import("std");

pub const bucket_count = 20;

buckets: [bucket_count]std.atomic.Value(u64) = @splat(.init(0)),
count: std.atomic.Value(u64) = .init(0),
sum_ns: std.atomic.Value(u64) = .init(0),
max_ns: std.atomic.Value(u64) = .init(0),

pub fn bucketOf(ns: u64) usize {
    const us = ns / std.time.ns_per_us;
    if (us == 0) return 0;
    return @min(bucket_count - 1, @as(usize, std.math.log2_int(u64, us)) + 1);
}

pub fn record(self: *PresentHistogram, ns: u64) void {
    _ = self.buckets[bucketOf(ns)].fetchAdd(1, .monotonic);
    _ = self.count.fetchAdd(1, .monotonic);
    _ = self.sum_ns.fetchAdd(ns, .monotonic);
    _ = self.max_ns.fetchMax(ns, .monotonic);
}

/// The bucket counts, for the log line.
pub fn snapshot(self: *const PresentHistogram) [bucket_count]u64 {
    var out: [bucket_count]u64 = undefined;
    for (&out, &self.buckets) |*o, *b| o.* = b.load(.monotonic);
    return out;
}

test "bucketOf: below 1 us, then powers of two microseconds, then the last bucket" {
    try std.testing.expectEqual(@as(usize, 0), bucketOf(0));
    try std.testing.expectEqual(@as(usize, 0), bucketOf(999));
    try std.testing.expectEqual(@as(usize, 1), bucketOf(1_000));
    try std.testing.expectEqual(@as(usize, 1), bucketOf(1_999));
    try std.testing.expectEqual(@as(usize, 2), bucketOf(2_000));
    try std.testing.expectEqual(@as(usize, 2), bucketOf(3_999));
    try std.testing.expectEqual(@as(usize, 3), bucketOf(4_000));
    try std.testing.expectEqual(@as(usize, 14), bucketOf(8_192_000)); // 8.192 ms
    try std.testing.expectEqual(@as(usize, bucket_count - 1), bucketOf(std.math.maxInt(u64)));
}

test "record keeps count, sum and max exact" {
    var h: PresentHistogram = .{};
    h.record(500);
    h.record(3_000);
    h.record(10 * std.time.ns_per_s);
    const b = h.snapshot();
    try std.testing.expectEqual(@as(u64, 1), b[0]);
    try std.testing.expectEqual(@as(u64, 1), b[2]);
    try std.testing.expectEqual(@as(u64, 1), b[bucket_count - 1]);
    try std.testing.expectEqual(@as(u64, 3), h.count.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 500 + 3_000 + 10 * std.time.ns_per_s), h.sum_ns.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 10 * std.time.ns_per_s), h.max_ns.load(.monotonic));
}
