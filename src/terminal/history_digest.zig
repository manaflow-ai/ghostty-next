//! History digest: identifies the history rows a mirror splices in.
//!
//! A cmux host and its mirrors parse the same bytes and resize with the same
//! code (Terminal.resize), so after a resize both hold the same reflowed
//! history. The host encodes the READY snapshot prefix at the resize; READY
//! carries the page that holds the first active row, so it already holds the
//! newest `S` history rows (the seam: the rows above the active area in that
//! page). The mirror keeps those and splices its own older rows above them.
//! The host sends the digest of the rows directly above the seam with READY;
//! the mirror computes the digest of its own reflowed history at the same
//! seam (taken from the decoded READY) and splices only when they are equal.
//! A silent divergence (a missed frame, a different Unicode width or grapheme
//! mode, a different scrollback limit) changes the row count or the digest,
//! and the mirror then requests a new snapshot with history instead.
//!
//! Algorithm version 2 (`version`), SHA-256 over these bytes, every integer
//! unsigned little-endian, where H is the history row count, S the seam,
//! N = min(H - S, `window_rows`) (0 when H <= S) and C the column count:
//!
//!   - the ASCII bytes "ghostty-history-digest" and `version` (u32)
//!   - S (u32), N (u32), C (u16); H itself is not hashed (see `matches`)
//!   - for each of the N history rows directly above the seam (history rows
//!     H - S - N to H - S - 1, counted from the oldest), oldest first:
//!       - flags (u8): bit 0 `Row.wrap`, bit 1 `Row.wrap_continuation`
//!       - for each of the C cells: `Cell.wide` (u8), the first codepoint
//!         (u32; 0 for an empty or background-only cell), the count of
//!         further grapheme codepoints (u16), then each of them (u32)
//!
//! Styles, colors, hyperlinks, protection and semantic marks are not hashed:
//! a mirror applies its own color policy.
//!
//! `matches` is the rule a mirror applies: equal digests, and equal row
//! counts or a mirror whose smaller scrollback limit cut its oldest rows.
//! Rows older than the window are checked by the row count only, and not
//! at all when the mirror's limit cut its history.
//!
//! This is the C API's `ghostty_terminal_history_digest` and the embedded
//! surface's `ghostty_surface_history_digest`; keep the header docs in sync.
const std = @import("std");
const PageList = @import("PageList.zig");
const Screen = @import("Screen.zig");
const Terminal = @import("Terminal.zig");

/// The algorithm version. Change it with any change to the hashed bytes.
pub const version: u32 = 2;

/// The digest length: SHA-256.
pub const len = 32;

/// The most history rows a digest covers: the rows above the seam.
pub const window_rows = 64;

const domain = "ghostty-history-digest";

pub const Digest = struct {
    /// History rows of the screen (physical rows above the active area).
    history_rows: u64,

    /// The seam: the newest history rows that a READY prefix carries.
    seam_rows: u64,

    /// SHA-256 of the history rows above the seam (see the file docs).
    bytes: [len]u8,

    pub fn eql(self: Digest, other: Digest) bool {
        return self.history_rows == other.history_rows and
            self.seam_rows == other.seam_rows and
            std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};

/// The digest of the terminal's primary screen, active or not, at its own
/// seam: what the owner computes when it encodes READY.
pub fn terminal(t: *const Terminal) Digest {
    return pages(&t.screens.get(.primary).?.pages);
}

/// The digest of a screen's history at its own seam.
pub fn screen(s: *const Screen) Digest {
    return pages(&s.pages);
}

/// The seam of a page list: the history rows above the active area in the
/// page that holds the first active row, which a READY prefix carries.
pub fn seam(list: *const PageList) u64 {
    return list.getTopLeft(.active).y;
}

/// The digest of a page list's history at its own seam.
pub fn pages(list: *const PageList) Digest {
    return pagesAtSeam(list, seam(list));
}

/// The digest of a page list's history at the given seam: what a mirror
/// computes on its reflowed terminal with the seam of the decoded READY.
/// Reading a compressed page in the window decompresses it.
pub fn pagesAtSeam(list: *const PageList, seam_rows: u64) Digest {
    const history_rows: u64 = list.total_rows - list.rows;
    const above: u64 = history_rows -| seam_rows;
    const n: u32 = @intCast(@min(above, window_rows));

    var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    hash.update(domain);
    update(&hash, u32, version);
    update(&hash, u32, @truncate(seam_rows));
    update(&hash, u32, n);
    update(&hash, u16, list.cols);

    if (n > 0) {
        const first: u32 = @intCast(above - n);
        var it = list.rowIterator(
            .right_down,
            .{ .history = .{ .y = first } },
            .{ .history = .{ .y = first + n - 1 } },
        );
        while (it.next()) |pin| {
            const rac = pin.rowAndCell();
            const row = rac.row;
            var flags: u8 = 0;
            if (row.wrap) flags |= 1;
            if (row.wrap_continuation) flags |= 2;
            hash.update(&.{flags});

            for (pin.cells(.all)) |*cell| {
                hash.update(&.{@intFromEnum(cell.wide)});
                const cp: u32 = switch (cell.content_tag) {
                    .codepoint, .codepoint_grapheme => cell.content.codepoint.data,
                    .bg_color_palette, .bg_color_rgb => 0,
                };
                update(&hash, u32, cp);
                const extra: []const u21 = if (cell.content_tag == .codepoint_grapheme)
                    pin.grapheme(cell) orelse &.{}
                else
                    &.{};
                update(&hash, u16, @intCast(extra.len));
                for (extra) |g| update(&hash, u32, g);
            }
        }
    }

    var result: Digest = .{
        .history_rows = history_rows,
        .seam_rows = seam_rows,
        .bytes = undefined,
    };
    hash.final(&result.bytes);
    return result;
}

/// Whether a mirror's history matches the owner's, after both reflowed
/// at the same point of the byte stream (`local` computed with
/// `pagesAtSeam` at the seam of the owner's READY): equal seams and
/// digests, and either equal history row counts, or the mirror holds
/// fewer rows only because its own scrollback limit cut the oldest ones
/// (`local_cut`: `PageList.history_truncated` and
/// `PageList.historyAtLimit`) while both have at least `window_rows` rows
/// above the seam, so the digests cover the same full window.
///
/// With a cut oldest part the oldest local logical line can be a fragment
/// of the owner's, and its reflowed rows can differ from the owner's;
/// every newer row is the owner's row.
pub fn matches(local: Digest, local_cut: bool, expected: Digest) bool {
    if (local.seam_rows != expected.seam_rows) return false;
    if (!std.mem.eql(u8, &local.bytes, &expected.bytes)) return false;
    if (local.history_rows == expected.history_rows) return true;
    return local_cut and
        local.history_rows -| local.seam_rows >= window_rows and
        expected.history_rows -| expected.seam_rows >= window_rows and
        local.history_rows < expected.history_rows;
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

    // Equal at the owner's own seam.
    try testing.expect(terminal(&a).eql(terminal(&b)));
    try testing.expectEqual(seam(&a.screens.get(.primary).?.pages), terminal(&a).seam_rows);

    // One changed row in the window changes the digest. At seam 0 the
    // window is the newest 64 history rows, which hold line 190.
    const da = pagesAtSeam(&a.screens.get(.primary).?.pages, 0);
    try testing.expect(da.history_rows > window_rows);
    try testing.expect(da.eql(pagesAtSeam(&b.screens.get(.primary).?.pages, 0)));
    const dc = pagesAtSeam(&c.screens.get(.primary).?.pages, 0);
    try testing.expectEqual(da.history_rows, dc.history_rows);
    try testing.expect(!std.mem.eql(u8, &da.bytes, &dc.bytes));

    // A seam above line 190 leaves it out of the window.
    const above = pagesAtSeam(&a.screens.get(.primary).?.pages, 40);
    try testing.expect(above.eql(pagesAtSeam(&c.screens.get(.primary).?.pages, 40)));

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
    const short: Digest = .{ .history_rows = da.history_rows - 1, .seam_rows = da.seam_rows, .bytes = da.bytes };
    try testing.expect(matches(da, false, da));
    try testing.expect(!matches(dc, false, da));
    try testing.expect(!matches(short, false, da));
    try testing.expect(matches(short, true, da));
    try testing.expect(!matches(da, true, short));
    const tiny: Digest = .{ .history_rows = da.seam_rows + window_rows - 1, .seam_rows = da.seam_rows, .bytes = da.bytes };
    var other_seam = da;
    other_seam.seam_rows +%= 1;
    try testing.expect(!matches(other_seam, false, da));
    try testing.expect(!matches(tiny, true, da));

    // A seam beyond the history: an empty window, still bound to the seam.
    const all = pagesAtSeam(&a.screens.get(.primary).?.pages, da.history_rows + 5);
    try testing.expect(all.eql(pagesAtSeam(&c.screens.get(.primary).?.pages, da.history_rows + 5)));
    try testing.expect(!std.mem.eql(u8, &all.bytes, &pagesAtSeam(&c.screens.get(.primary).?.pages, da.history_rows + 6).bytes));

    // The alternate screen is never hashed.
    const before = terminal(&a);
    testFeed(&a, "\x1b[?1049h");
    for (0..20) |_| testFeed(&a, "alternate\r\n");
    try testing.expect(before.eql(terminal(&a)));
}

test "history digest: empty and short histories" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var a = try testTerminal(alloc, 20);
    defer a.deinit(alloc);
    var b = try testTerminal(alloc, 20);
    defer b.deinit(alloc);

    // Empty history: no rows, the seam is 0, equal digests.
    const empty = terminal(&a);
    try testing.expectEqual(@as(u64, 0), empty.history_rows);
    try testing.expectEqual(@as(u64, 0), empty.seam_rows);
    try testing.expect(empty.eql(terminal(&b)));

    // Fewer than 64 history rows: the window holds all of them.
    for (0..20) |i| {
        var buf: [32]u8 = undefined;
        testFeed(&a, try std.fmt.bufPrint(&buf, "row {d}\r\n", .{i}));
        testFeed(&b, try std.fmt.bufPrint(&buf, "row {d}\r\n", .{if (i == 2) 99 else i}));
    }
    const da = pagesAtSeam(&a.screens.get(.primary).?.pages, 0);
    try testing.expect(da.history_rows > 0);
    try testing.expect(da.history_rows < window_rows);
    const db = pagesAtSeam(&b.screens.get(.primary).?.pages, 0);
    try testing.expectEqual(da.history_rows, db.history_rows);
    try testing.expect(!std.mem.eql(u8, &da.bytes, &db.bytes));
    try testing.expect(!std.mem.eql(u8, &empty.bytes, &da.bytes));

    // Too few rows above the seam for the cut-history rule.
    const short: Digest = .{ .history_rows = da.history_rows - 1, .seam_rows = 0, .bytes = da.bytes };
    try testing.expect(!matches(short, true, da));
}
