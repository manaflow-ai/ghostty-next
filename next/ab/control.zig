//! Toolchain control for the reflow-preview A/B (scratch, never merged).
//! The same source is compiled by each arm's Zig (0.16.0 and 0.17.0) with
//! ReleaseFast and timed from outside: append, sort and sum 8 M integers.
//! It reads no Ghostty code, so a time difference here is the compiler or
//! std, not the terminal sources.
const std = @import("std");

pub fn main() void {
    const alloc = std.heap.page_allocator;
    var list: std.ArrayList(u64) = .empty;
    defer list.deinit(alloc);
    var x: u64 = 0x9E3779B97F4A7C15;
    var i: usize = 0;
    while (i < 8_000_000) : (i += 1) {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        list.append(alloc, x) catch unreachable;
    }
    std.mem.sort(u64, list.items, {}, std.sort.asc(u64));
    var sum: u64 = 0;
    for (list.items, 0..) |v, j| sum +%= v ^ j;
    std.mem.doNotOptimizeAway(sum);
}
