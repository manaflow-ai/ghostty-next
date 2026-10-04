//! History digest: identifies the newest history rows of a primary screen.
//!
//! A cmux host and its mirrors parse the same bytes and resize with the same
//! code (Terminal.resize), so after a resize both hold the same reflowed
//! history. The host sends the digest of its history with the READY snapshot
//! prefix it encodes at the resize; a mirror computes the digest of its own
//! reflowed history and keeps that history only when the two are equal. A
//! silent divergence (a missed frame, a different Unicode width or grapheme
//! mode, a different scrollback limit) changes the row count or the digest,
//! and the mirror then asks the host for the history instead.
//!
//! Algorithm version 1 (`version`), SHA-256 over these bytes, every integer
//! unsigned little-endian, where H is the history row count, N = min(H,
//! `window_rows`) and C the column count:
//!
//!   - the ASCII bytes "ghostty-history-digest" and `version` (u32)
//!   - N (u32), C (u16); H itself is not hashed (see `matches`)
//!   - for each of the N newest history rows, from the oldest of them to the
//!     row directly above the active area:
//!       - flags (u8): bit 0 `Row.wrap`, bit 1 `Row.wrap_continuation`
//!       - for each of the C cells: `Cell.wide` (u8), the first codepoint
//!         (u32; 0 for an empty or background-only cell), the count of
//!         further grapheme codepoints (u16), then each of them (u32)
//!
//! Styles, colors, hyperlinks, protection and semantic marks are not hashed:
//! a mirror applies its own color policy.
//!
//! `matches` is the rule a mirror applies: equal digests, and equal row
//! counts or a mirror whose smaller scrollback limit dropped its oldest rows.
//!
//! This is the C API's `ghostty_terminal_history_digest` and the embedded
//! surface's `ghostty_surface_history_digest`; keep the header docs in sync.
const std = @import("std");
const PageList = @import("PageList.zig");
const Screen = @import("Screen.zig");
const Terminal = @import("Terminal.zig");

/// The algorithm version. Change it with any change to the hashed bytes.
pub const version: u32 = 1;

/// The digest length: SHA-256.
pub const len = 32;

/// The most history rows a digest covers.
pub const window_rows = 64;

const domain = "ghostty-history-digest";

pub const Digest = struct {
    /// History rows of the screen (physical rows above the active area).
    history_rows: u64,

    /// SHA-256 of the newest history rows (see the file docs).
    bytes: [len]u8,

    pub fn eql(self: Digest, other: Digest) bool {
        return self.history_rows == other.history_rows and
            std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};

/// The digest of the terminal's primary screen, active or not.
pub fn terminal(t: *const Terminal) Digest {
    return pages(&t.screens.get(.primary).?.pages);
}

/// The digest of a screen's history.
pub fn screen(s: *const Screen) Digest {
    return pages(&s.pages);
}

/// The digest of a page list's history. Reading a compressed page that
/// holds one of the newest history rows decompresses it.
pub fn pages(list: *const PageList) Digest {
    _ = list;
    return .{ .history_rows = 0, .bytes = @splat(0) }; // red: not implemented
}

/// Whether a mirror's history matches the owner's, after both reflowed
/// at the same point of the byte stream: equal digests and either equal
/// history row counts, or the mirror holds fewer rows only because its
/// own scrollback limit dropped the oldest ones (`local_truncated`, see
/// `PageList.history_truncated`) while both still have at least
/// `window_rows` rows, so the digests cover the same full window.
///
/// With a dropped oldest part the oldest local logical line can be a
/// fragment of the owner's, and its reflowed rows can differ from the
/// owner's; every newer row is the owner's row.
pub fn matches(local: Digest, local_truncated: bool, expected: Digest) bool {
    _ = local;
    _ = local_truncated;
    _ = expected;
    return false; // red: not implemented
}

fn update(hash: *std.crypto.hash.sha2.Sha256, comptime T: type, value: T) void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    hash.update(&buf);
}

fn testTerminal(alloc: std.mem.Allocator, cols: u16) !Terminal {
    var t: Terminal = try .init(std.testing.io, alloc, .{
        .cols = cols,
        .rows = 5,
        .max_scrollback_bytes = null,
    });
    t.flags.shell_redraws_prompt = .false;
    return t;
}

fn testFeed(t: *Terminal, bytes: []const u8) void {
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(bytes);
}

test "history digest: equal after the same bytes and resize, changes with one row" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var a = try testTerminal(alloc, 40);
    defer a.deinit(alloc);
    var b = try testTerminal(alloc, 40);
    defer b.deinit(alloc);
    var c = try testTerminal(alloc, 40);
    defer c.deinit(alloc);

    // No history yet: equal, zero rows.
    try testing.expect(terminal(&a).eql(terminal(&b)));
    try testing.expectEqual(@as(u64, 0), terminal(&a).history_rows);

    var buf: [128]u8 = undefined;
    for (0..200) |i| {
        // Long soft-wrapping lines, a wide character and a grapheme.
        const line = try std.fmt.bufPrint(&buf, "\x1b[3{d}m{d:0>3} " ++ ("abcdefghij" ** 6) ++ " 漢 e\u{301}\x1b[m\r\n", .{ i % 8, i });
        testFeed(&a, line);
        testFeed(&b, line);
        // c differs from a and b in one character of one old line.
        if (i == 190) {
            var changed: [128]u8 = undefined;
            @memcpy(changed[0..line.len], line);
            changed[10] = 'X'; // "abc..." -> "aXc..."
            testFeed(&c, changed[0..line.len]);
        } else testFeed(&c, line);
    }

    try a.resize(alloc, .{ .cols = 25, .rows = 5 });
    try b.resize(alloc, .{ .cols = 25, .rows = 5 });
    try c.resize(alloc, .{ .cols = 25, .rows = 5 });

    const da = terminal(&a);
    try testing.expect(da.history_rows > window_rows);
    try testing.expect(da.eql(terminal(&b)));
    const dc = terminal(&c);
    try testing.expectEqual(da.history_rows, dc.history_rows);
    try testing.expect(!std.mem.eql(u8, &da.bytes, &dc.bytes));

    // Colors are not hashed.
    var d = try testTerminal(alloc, 25);
    defer d.deinit(alloc);
    var e = try testTerminal(alloc, 25);
    defer e.deinit(alloc);
    for (0..20) |i| {
        testFeed(&d, try std.fmt.bufPrint(&buf, "\x1b[31mred {d}\x1b[m\r\n", .{i}));
        testFeed(&e, try std.fmt.bufPrint(&buf, "\x1b[44mred {d}\x1b[m\r\n", .{i}));
    }
    try testing.expect(terminal(&d).eql(terminal(&e)));

    // The rule a mirror applies.
    const short: Digest = .{ .history_rows = da.history_rows - 1, .bytes = da.bytes };
    try testing.expect(matches(da, false, da));
    try testing.expect(!matches(dc, false, da));
    try testing.expect(!matches(short, false, da));
    try testing.expect(matches(short, true, da));
    try testing.expect(!matches(da, true, short));
    const tiny: Digest = .{ .history_rows = window_rows - 1, .bytes = da.bytes };
    try testing.expect(!matches(tiny, true, da));

    // The alternate screen is never hashed.
    const before = terminal(&a);
    testFeed(&a, "\x1b[?1049h");
    for (0..20) |_| testFeed(&a, "alternate\r\n");
    try testing.expect(before.eql(terminal(&a)));
}
