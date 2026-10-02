//! Manual is a termio backend for embedders that own the byte transport,
//! for example a session host on another machine that owns the PTY. It
//! starts no subprocess, opens no PTY and has no read thread.
//!
//! The embedder feeds terminal output with `Termio.processOutput`. Bytes
//! that Ghostty would write to a PTY (encoded keys, text, paste, mouse
//! and focus reports, and, unless replies are suppressed, parser replies)
//! go to the write callback instead.
//!
//! Ported from manaflow-ai/ghostty d631f36cea and 22fa801f88 and
//! re-implemented against the current termio structure.
const Manual = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");

/// The C ABI callback that receives bytes for the remote PTY. The bytes
/// are only valid for the duration of the call.
pub const WriteCallback = *const fn (
    ?*anyopaque,
    [*]const u8,
    usize,
) callconv(.c) void;

pub const Config = struct {
    /// Receives encoded input. If null, input is dropped.
    write_cb: ?WriteCallback = null,

    /// Passed as the first argument of write_cb.
    write_userdata: ?*anyopaque = null,

    /// True if another terminal core owns the PTY protocol and this
    /// surface only mirrors its output. The caller uses this to set
    /// `termio.Options.suppress_terminal_responses`; the backend itself
    /// treats both modes the same.
    mirror: bool = false,
};

write_cb: ?WriteCallback,
write_userdata: ?*anyopaque,

/// Serializes calls to write_cb. Writes come from the thread that calls
/// the surface input APIs and from the termio thread, and the embedder
/// must see them one at a time.
write_mutex: std.Io.Mutex = .init,

pub fn init(_: Allocator, cfg: Config) !Manual {
    return .{
        .write_cb = cfg.write_cb,
        .write_userdata = cfg.write_userdata,
    };
}

pub fn deinit(self: *Manual) void {
    self.* = undefined;
}

pub fn initTerminal(_: *Manual, _: *terminal.Terminal) void {}

pub fn threadEnter(
    _: *Manual,
    _: Allocator,
    _: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    td.backend = .{ .manual = .{} };
}

pub fn threadExit(_: *Manual, _: *termio.Termio.ThreadData) void {}

pub fn focusGained(_: *Manual, _: *termio.Termio.ThreadData, _: bool) !void {}

/// There is no local PTY to resize. The embedder tells the owner of the
/// PTY about size changes through its own transport.
pub fn resize(_: *Manual, _: renderer.GridSize, _: renderer.ScreenSize) !void {}

pub fn queueWrite(
    self: *Manual,
    alloc: Allocator,
    _: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    try self.write(alloc, data, linefeed);
}

/// Deliver bytes to the write callback. If `linefeed` is set (mode 20,
/// LNM), every CR becomes CRLF, the same conversion Exec applies before
/// it writes to its PTY. Safe to call from any thread.
pub fn write(
    self: *Manual,
    alloc: Allocator,
    data: []const u8,
    linefeed: bool,
) Allocator.Error!void {
    const cb = self.write_cb orelse return;
    if (data.len == 0) return;

    const extra = if (linefeed) std.mem.count(u8, data, "\r") else 0;
    if (extra == 0) {
        self.write_mutex.lockUncancelable(global.io());
        defer self.write_mutex.unlock(global.io());
        cb(self.write_userdata, data.ptr, data.len);
        return;
    }

    const buf = try alloc.alloc(u8, data.len + extra);
    defer alloc.free(buf);
    var o: usize = 0;
    for (data) |ch| {
        buf[o] = ch;
        o += 1;
        if (ch == '\r') {
            buf[o] = '\n';
            o += 1;
        }
    }

    self.write_mutex.lockUncancelable(global.io());
    defer self.write_mutex.unlock(global.io());
    cb(self.write_userdata, buf.ptr, o);
}

pub fn childExitedAbnormally(
    _: *Manual,
    _: Allocator,
    _: *terminal.Terminal,
    _: u32,
    _: u64,
) !void {}

/// The manual backend has no per-thread state.
pub const ThreadData = struct {
    pub fn deinit(_: *ThreadData, _: Allocator) void {}
};

const TestSink = struct {
    out: std.ArrayList(u8) = .empty,
    calls: usize = 0,

    fn cb(ud: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) void {
        const self: *TestSink = @ptrCast(@alignCast(ud.?));
        self.calls += 1;
        self.out.appendSlice(std.testing.allocator, ptr[0..len]) catch
            @panic("OOM");
    }

    fn deinit(self: *TestSink) void {
        self.out.deinit(std.testing.allocator);
    }
};

test "manual: write delivers encoded input unchanged" {
    const testing = std.testing;
    var sink: TestSink = .{};
    defer sink.deinit();

    var manual = try Manual.init(testing.allocator, .{
        .write_cb = TestSink.cb,
        .write_userdata = &sink,
    });
    defer manual.deinit();

    // Keyboard, committed UTF-8 text, SGR mouse, bracketed paste and a
    // focus report all reach the backend already encoded by the surface.
    const inputs = [_][]const u8{
        "\x1b[1;5A",
        "\xce\xbb",
        "\x1b[<0;10;5M",
        "\x1b[200~hello\x1b[201~",
        "\x1b[I",
    };
    for (inputs) |input| try manual.write(testing.allocator, input, false);

    try testing.expectEqual(@as(usize, inputs.len), sink.calls);
    try testing.expectEqualStrings(
        "\x1b[1;5A\xce\xbb\x1b[<0;10;5M\x1b[200~hello\x1b[201~\x1b[I",
        sink.out.items,
    );
}

test "manual: write converts CR to CRLF in linefeed mode" {
    const testing = std.testing;
    var sink: TestSink = .{};
    defer sink.deinit();

    var manual = try Manual.init(testing.allocator, .{
        .write_cb = TestSink.cb,
        .write_userdata = &sink,
    });
    defer manual.deinit();

    try manual.write(testing.allocator, "a\rb\r", true);
    try testing.expectEqualStrings("a\r\nb\r\n", sink.out.items);

    sink.out.clearRetainingCapacity();
    try manual.write(testing.allocator, "a\rb", false);
    try testing.expectEqualStrings("a\rb", sink.out.items);
}

test "manual: write without a callback or data is a no-op" {
    const testing = std.testing;
    var sink: TestSink = .{};
    defer sink.deinit();

    var none = try Manual.init(testing.allocator, .{});
    defer none.deinit();
    try none.write(testing.allocator, "ignored", false);

    var manual = try Manual.init(testing.allocator, .{
        .write_cb = TestSink.cb,
        .write_userdata = &sink,
    });
    defer manual.deinit();
    try manual.write(testing.allocator, "", false);
    try testing.expectEqual(@as(usize, 0), sink.calls);
}
