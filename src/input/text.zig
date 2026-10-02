const std = @import("std");

/// Encode committed text input (typed text, an IME commit) for the pty.
/// Ported from manaflow-ai/ghostty 22fa801f88.
///
/// This differs from paste encoding:
/// - no bracketed paste wrappers
/// - no control-byte stripping
/// - a line break (LF or CRLF) becomes a single CR, like the Enter key
pub fn encode(
    data: anytype,
) switch (@TypeOf(data)) {
    []u8 => []const u8,
    []const u8 => Error![]const u8,
    else => unreachable,
} {
    const mutable = @TypeOf(data) == []u8;

    if (comptime mutable) {
        // Compact in place. Reads stay at or ahead of writes, so `prev`
        // must hold the input byte, which a write may have replaced.
        var o: usize = 0;
        var prev: u8 = 0;
        for (data) |ch| {
            defer prev = ch;
            // CRLF: the CR was already written, drop the LF.
            if (ch == '\n' and prev == '\r') continue;
            data[o] = if (ch == '\n') '\r' else ch;
            o += 1;
        }
        return data[0..o];
    }

    if (std.mem.indexOfScalar(u8, data, '\n') != null) {
        return Error.MutableRequired;
    }

    return data;
}

pub const Error = error{
    MutableRequired,
};

test "encode committed text without newlines" {
    const testing = std.testing;
    const result = try encode(@as([]const u8, "hello"));
    try testing.expectEqualStrings("hello", result);
}

test "encode committed text with newline const" {
    const testing = std.testing;
    try testing.expectError(Error.MutableRequired, encode(
        @as([]const u8, "hello\nworld"),
    ));
}

test "encode committed text with newline mutable" {
    const testing = std.testing;
    const data: []u8 = try testing.allocator.dupe(u8, "hello\nworld");
    defer testing.allocator.free(data);
    const result = encode(data);
    try testing.expectEqualStrings("hello\rworld", result);
}

test "encode committed text collapses CRLF to CR" {
    const testing = std.testing;
    const data: []u8 = try testing.allocator.dupe(u8, "a\r\nb\n\nc\r\r\n");
    defer testing.allocator.free(data);
    const result = encode(data);
    try testing.expectEqualStrings("a\rb\r\rc\r\r", result);
}
