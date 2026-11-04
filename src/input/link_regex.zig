//! Compiled link regexes, shared by every surface and renderer in the
//! process.
//!
//! Each surface used its own compiled copy of each configured link regex,
//! and so did its renderer: two compiles of the URL regex on the main
//! thread for every new surface (about 0.5 ms each time, onig_compile, in
//! cmux's workspace switch trace). Now each distinct pattern is compiled
//! once and shared, counted by its users.
//!
//! Sharing is safe across threads (a surface searches on the app thread,
//! its renderer on the renderer thread): Oniguruma 6.9.9's onig_search and
//! onig_match never write to the regex_t. regexec.c assigns no `reg->`
//! field, the match stack is per call, and the int_map_backward table,
//! the last field the search wrote, was removed "for thread-safe"
//! (HISTORY, 2016/07/17). Only compile and free change a regex_t, and both
//! happen here under the lock.
//!
//! A pattern no one uses stays compiled, up to `max_unused` patterns: a
//! workspace switch frees surfaces and then makes new ones, which must not
//! compile again.
const std = @import("std");
const builtin = @import("builtin");
const oni = @import("oniguruma");
const global = @import("../global.zig");

const log = std.log.scoped(.link_regex);

/// Compiled patterns kept while nothing uses them.
pub const max_unused = 16;

const Entry = struct {
    /// Owned copy of the pattern (the key).
    pattern: []u8,
    regex: oni.Regex,
    /// Surfaces and renderer link sets that hold this regex.
    refs: usize,
};

/// Not the global state's allocator: the entries outlive any one surface,
/// and tests check the testing allocator for leaks after each test.
const alloc = if (builtin.link_libc) std.heap.c_allocator else std.heap.page_allocator;

var mutex: std.Io.Mutex = .init;
/// Oldest first, so eviction drops the longest-unused pattern first.
var entries: std.ArrayList(Entry) = .empty;
/// Compiles done since the process started (tests).
var compile_count: usize = 0;

/// The compiled regex for `pattern`, compiled now only when no surface has
/// it yet. Every call needs one `release` of the result.
pub fn acquire(pattern: []const u8) !oni.Regex {
    mutex.lockUncancelable(global.io());
    defer mutex.unlock(global.io());

    for (entries.items) |*entry| {
        if (std.mem.eql(u8, entry.pattern, pattern)) {
            entry.refs += 1;
            return entry.regex;
        }
    }

    // Same options as input.Link.oniRegex: the pattern is the whole key.
    var regex = try oni.Regex.init(
        pattern,
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    errdefer regex.deinit();
    const owned = try alloc.dupe(u8, pattern);
    errdefer alloc.free(owned);
    try entries.append(alloc, .{ .pattern = owned, .regex = regex, .refs = 1 });
    compile_count += 1;
    trimUnused();
    return regex;
}

/// Gives back a regex from `acquire`.
pub fn release(regex: oni.Regex) void {
    mutex.lockUncancelable(global.io());
    defer mutex.unlock(global.io());

    for (entries.items) |*entry| {
        if (entry.regex.value == regex.value) {
            std.debug.assert(entry.refs > 0);
            entry.refs -= 1;
            trimUnused();
            return;
        }
    }
    log.warn("release of a link regex that was not acquired", .{});
}

/// Frees the oldest unused patterns above `max_unused`. Holds the lock.
fn trimUnused() void {
    var unused: usize = 0;
    for (entries.items) |entry| {
        if (entry.refs == 0) unused += 1;
    }
    var i: usize = 0;
    while (unused > max_unused and i < entries.items.len) {
        if (entries.items[i].refs != 0) {
            i += 1;
            continue;
        }
        var entry = entries.orderedRemove(i);
        entry.regex.deinit();
        alloc.free(entry.pattern);
        unused -= 1;
    }
}

/// How many compiles the process has done (tests).
pub fn compiles() usize {
    mutex.lockUncancelable(global.io());
    defer mutex.unlock(global.io());
    return compile_count;
}

test "link_regex: one compile per pattern while it is used or recently used" {
    const testing = std.testing;
    const pattern = "link-regex-cache-test-[a-z]+";
    const before = compiles();

    const a = try acquire(pattern);
    const b = try acquire(pattern);
    try testing.expectEqual(a.value, b.value);
    try testing.expectEqual(before + 1, compiles());

    // All users gone, then a new one: the kept regex, no compile.
    release(a);
    release(b);
    const c = try acquire(pattern);
    defer release(c);
    try testing.expectEqual(a.value, c.value);
    try testing.expectEqual(before + 1, compiles());
}

test "link_regex: unused patterns above the cap are freed, used ones stay" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;

    const held = try acquire("link-regex-cache-held");
    defer release(held);
    var i: usize = 0;
    while (i < max_unused + 4) : (i += 1) {
        const p = try std.fmt.bufPrint(&buf, "link-regex-cache-evict-{d}", .{i});
        release(try acquire(p));
    }

    mutex.lockUncancelable(global.io());
    var unused: usize = 0;
    var held_found = false;
    for (entries.items) |entry| {
        if (entry.refs == 0) unused += 1;
        if (entry.regex.value == held.value) held_found = true;
    }
    mutex.unlock(global.io());
    try testing.expect(unused <= max_unused);
    try testing.expect(held_found);
}
