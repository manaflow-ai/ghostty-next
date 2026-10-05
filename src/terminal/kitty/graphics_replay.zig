//! Kitty graphics replay: a Kitty graphics APC byte stream that recreates
//! the images and placements of a terminal's active areas in another
//! terminal (a snapshot viewer) that restored the same snapshot. The
//! GHOSTSNP format carries no images; the owner sends this stream after
//! the snapshot (C API: ghostty_terminal_kitty_replay_encode).
//!
//! What the stream recreates, for the primary screen's active area and the
//! alternate screen:
//!
//! - Every placement that shows in the active area: a placement pinned to
//!   a cell whose rectangle reaches into the active area (a placement only
//!   in scrollback is not replayed), every virtual (U=1, unicode
//!   placeholder) placement, and every relative (P=) placement whose
//!   parent chain ends at such a placement. A placement keeps its image ID,
//!   external placement ID (an internal p=0 ID is assigned again by the
//!   viewer), z-index, cell offsets, source rectangle, columns and rows,
//!   parent and parent offsets.
//! - Every image that those placements use, with its image ID and image
//!   number. Images without such a placement are not replayed.
//!
//! Wire format. Every command is quiet (q=2), so the viewer writes no
//! reply. An image goes inline (t=d) as zlib-compressed (o=z) raw pixels:
//! the storage holds decoded pixels only (a PNG was decoded at load, so
//! f=100 never occurs), RGB as f=24 and RGBA as f=32 (grayscale storage
//! is widened to f=32). Its base64 payload is cut into chunks of at most
//! 4096 bytes (m=1 on every chunk but the last). Placements follow all
//! images: pinned and virtual ones first, then relative ones, parents
//! before children. The stream uses the private ghostty-next keys of
//! Command.Replay: E (screen) on every command, J (image number) on an
//! image, and B/L (row and column) on a pinned placement, so it moves no
//! cursor and switches no screen. A Kitty client never sends them.
//!
//! Byte cap. Images are taken newest first (by generation, the
//! transmission order) while their transmission bytes fit the cap; the
//! first image that does not fit and every older one are skipped and
//! counted, with their placements. The kept images go on the wire oldest
//! first, so the viewer's image ages (eviction order and the newest image
//! for a number) follow the owner's.
//!
//! Not replayed: animation frames and state (only the root frame), images
//! whose data is still loading, an in-progress chunked transmission, and
//! the internal placement ID values. A pinned placement above the active
//! area needs its row in the viewer (history restored before the stream);
//! the viewer drops it otherwise.
//!
//! Encoding only reads the terminal. The caller holds the terminal's lock.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

const Terminal = @import("../Terminal.zig");
const Screen = @import("../Screen.zig");
const ScreenSet = @import("../ScreenSet.zig");
const PageList = @import("../PageList.zig");
const command = @import("graphics_command.zig");
const Image = @import("graphics_image.zig").Image;
const ImageStorage = @import("graphics_storage.zig").ImageStorage;
const Placement = ImageStorage.Placement;
const PlacementKey = ImageStorage.PlacementKey;
const Replay = command.Command.Replay;

/// The Kitty limit for the base64 payload of one chunk.
pub const chunk_len = 4096;

/// What one encode wrote.
pub const Stats = struct {
    /// Images transmitted.
    images: u64 = 0,
    /// Placements written.
    placements: u64 = 0,
    /// Images that a replayed placement uses but that the byte cap
    /// skipped (their placements are skipped too).
    skipped_images: u64 = 0,
    /// Bytes of the image transmissions (the value the cap limits).
    image_bytes: u64 = 0,
    /// All bytes written.
    bytes: u64 = 0,
};

pub const Error = Allocator.Error || std.Io.Writer.Error;

/// Write the replay stream of `t` to `writer`. `max_image_bytes` caps the
/// bytes of the image transmissions (std.math.maxInt(u64) for no cap).
pub fn encode(
    alloc: Allocator,
    t: *const Terminal,
    max_image_bytes: u64,
    writer: *std.Io.Writer,
) Error!Stats {
    // Red test commit: not implemented yet.
    _ = alloc;
    _ = t;
    _ = max_image_bytes;
    _ = writer;
    return .{};
}

const screen_keys = [_]ScreenSet.Key{ .primary, .alternate };

const Candidate = struct {
    /// Index into screen_keys.
    screen: usize,
    id: u32,
    generation: u64,
    /// The encoded transmission, once encoded.
    bytes: []u8 = &.{},

    fn newerFirst(_: void, a: Candidate, b: Candidate) bool {
        if (a.generation != b.generation) return a.generation > b.generation;
        if (a.screen != b.screen) return a.screen < b.screen;
        return a.id < b.id;
    }
};

/// The replayed placements of one screen and the images they use.
const Selection = struct {
    const Entry = struct { key: PlacementKey, depth: usize };

    placements: std.ArrayList(Entry) = .empty,
    images: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Images on the wire and placements written, during the encode.
    sent: std.AutoHashMapUnmanaged(u32, void) = .empty,
    written: std.AutoHashMapUnmanaged(PlacementKey, void) = .empty,

    fn init(alloc: Allocator, t: *const Terminal, key: ScreenSet.Key) Allocator.Error!Selection {
        var self: Selection = .{};
        errdefer self.deinit(alloc);
        const screen = t.screens.get(key) orelse return self;
        const storage = &screen.kitty_images;

        var it = storage.placements.iterator();
        while (it.next()) |entry| {
            const p = entry.value_ptr.*;
            const img = storage.images.get(entry.key_ptr.image_id) orelse continue;
            // Data that is still loading cannot be sent.
            if (img.data.bytes() == null) continue;
            const depth: usize = switch (p.location) {
                .virtual => 0,
                .pin => if (pinShows(t, screen, img, p)) 0 else continue,
                .relative => |rel| depth: {
                    const chain = storage.resolveChain(rel) orelse continue;
                    switch (chain.root.location) {
                        .virtual => {},
                        .pin => {
                            const root_img = storage.images.get(chain.root_key.image_id) orelse continue;
                            if (!pinShows(t, screen, root_img, chain.root)) continue;
                        },
                        .relative => continue,
                    }
                    break :depth chainDepth(storage, rel);
                },
            };
            try self.placements.append(alloc, .{ .key = entry.key_ptr.*, .depth = depth });
            try self.images.put(alloc, entry.key_ptr.image_id, {});
        }

        // A relative placement also needs every image up its chain.
        for (self.placements.items) |entry| {
            var p = storage.placements.get(entry.key).?;
            while (p.location == .relative) {
                const parent = p.location.relative.parent;
                try self.images.put(alloc, parent.image_id, {});
                p = storage.placements.get(parent) orelse break;
            }
        }

        std.mem.sort(Entry, self.placements.items, {}, entryLess);
        return self;
    }

    fn deinit(self: *Selection, alloc: Allocator) void {
        self.placements.deinit(alloc);
        self.images.deinit(alloc);
        self.sent.deinit(alloc);
        self.written.deinit(alloc);
    }

    fn entryLess(_: void, a: Entry, b: Entry) bool {
        if (a.depth != b.depth) return a.depth < b.depth;
        if (a.key.image_id != b.key.image_id) return a.key.image_id < b.key.image_id;
        if (a.key.placement_id.tag != b.key.placement_id.tag) {
            return a.key.placement_id.tag == .external;
        }
        return a.key.placement_id.id < b.key.placement_id.id;
    }
};

/// The number of parents up to the chain's root.
fn chainDepth(storage: *const ImageStorage, rel: Placement.Relative) usize {
    var depth: usize = 1;
    var key = rel.parent;
    while (storage.placements.get(key)) |p| {
        switch (p.location) {
            .relative => |parent| {
                depth += 1;
                key = parent.parent;
            },
            .pin, .virtual => break,
        }
    }
    return depth;
}

/// Whether a pinned placement shows in the active area: its anchor or its
/// last row is in the active area.
fn pinShows(t: *const Terminal, screen: *const Screen, img: Image, p: Placement) bool {
    const pin = p.location.pin;
    if (pin.garbage) return false;
    if (screen.pages.pointFromPin(.active, pin.*) != null) return true;
    const rect = p.rect(img, t) orelse return false;
    return screen.pages.pointFromPin(.active, rect.bottom_right) != null;
}

/// The private screen key value.
fn screenValue(key: ScreenSet.Key) u8 {
    return switch (key) {
        .primary => 0,
        .alternate => 1,
    };
}

/// The complete transmission commands of one image.
fn encodeImage(alloc: Allocator, key: ScreenSet.Key, img: Image) Error![]u8 {
    const data = img.data.bytes().?;

    // RGB and RGBA go as stored; grayscale widens to RGBA.
    var widened: ?[]u8 = null;
    defer if (widened) |w| alloc.free(w);
    const pixels: []const u8, const format: u8 = switch (img.format) {
        .rgb => .{ data, 24 },
        .rgba => .{ data, 32 },
        .gray, .gray_alpha => pixels: {
            const bpp: usize = if (img.format == .gray) 1 else 2;
            const count = data.len / bpp;
            const out = try alloc.alloc(u8, count * 4);
            widened = out;
            for (0..count) |px| {
                const v = data[px * bpp];
                out[px * 4 + 0] = v;
                out[px * 4 + 1] = v;
                out[px * 4 + 2] = v;
                out[px * 4 + 3] = if (bpp == 2) data[px * bpp + 1] else 255;
            }
            break :pixels .{ out, 32 };
        },
        // Stored images are decoded; PNG never reaches the storage.
        .png => unreachable,
    };

    // zlib (o=z).
    var deflated: std.Io.Writer.Allocating = try .initCapacity(alloc, 64);
    defer deflated.deinit();
    {
        const window = try alloc.alloc(u8, flate.max_window_len);
        defer alloc.free(window);
        const compress = try alloc.create(flate.Compress);
        defer alloc.destroy(compress);
        compress.* = flate.Compress.init(&deflated.writer, window, .zlib, .default) catch
            return error.OutOfMemory;
        compress.writer.writeAll(pixels) catch return error.OutOfMemory;
        compress.finish() catch return error.OutOfMemory;
    }
    const zlib = deflated.written();

    const b64 = std.base64.standard.Encoder;
    const encoded = try alloc.alloc(u8, b64.calcSize(zlib.len));
    defer alloc.free(encoded);
    _ = b64.encode(encoded, zlib);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    const screen = screenValue(key);
    var offset: usize = 0;
    var first = true;
    while (true) {
        const end = @min(offset + chunk_len, encoded.len);
        const more: u8 = if (end < encoded.len) 1 else 0;
        writeChunk(w, img, format, screen, first, more, encoded[offset..end]) catch
            return error.OutOfMemory;
        first = false;
        offset = end;
        if (more == 0) break;
    }
    return try out.toOwnedSlice();
}

fn writeChunk(
    w: *std.Io.Writer,
    img: Image,
    format: u8,
    screen: u8,
    first: bool,
    more: u8,
    payload: []const u8,
) std.Io.Writer.Error!void {
    try w.writeAll("\x1b_G");
    if (first) {
        try w.print("a=t,q=2,t=d,f={d},o=z,s={d},v={d},i={d}", .{
            format,
            img.width,
            img.height,
            img.id,
        });
        if (img.number > 0) try w.print(",{c}={d}", .{ Replay.number_key, img.number });
        if (img.metadata.transient) try w.writeAll(",N=1");
    } else {
        try w.writeAll("q=2");
    }
    try w.print(",{c}={d},m={d};", .{ Replay.screen_key, screen, more });
    try w.writeAll(payload);
    try w.writeAll("\x1b\\");
}

/// Write one placement command and return its length.
fn writePlacement(
    writer: *std.Io.Writer,
    t: *const Terminal,
    key: ScreenSet.Key,
    pkey: PlacementKey,
    p: Placement,
) std.Io.Writer.Error!u64 {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("\x1b_Ga=p,q=2,i={d}", .{pkey.image_id}) catch unreachable;
    if (pkey.placement_id.tag == .external) {
        w.print(",p={d}", .{pkey.placement_id.id}) catch unreachable;
    }
    w.print(",{c}={d}", .{ Replay.screen_key, screenValue(key) }) catch unreachable;
    switch (p.location) {
        .pin => |pin| {
            const screen = t.screens.get(key).?;
            const top = screen.pages.pin(.{ .active = .{} }).?;
            const row = rowOffset(screen, top, pin.*);
            w.print(",{c}={d},{c}={d},C=1", .{
                Replay.row_key,
                row,
                Replay.col_key,
                pin.x,
            }) catch unreachable;
        },
        .virtual => w.writeAll(",U=1") catch unreachable,
        .relative => |rel| {
            w.print(",P={d}", .{rel.parent.image_id}) catch unreachable;
            if (rel.parent.placement_id.tag == .external) {
                w.print(",Q={d}", .{rel.parent.placement_id.id}) catch unreachable;
            }
            if (rel.horizontal_offset != 0) w.print(",H={d}", .{rel.horizontal_offset}) catch unreachable;
            if (rel.vertical_offset != 0) w.print(",V={d}", .{rel.vertical_offset}) catch unreachable;
        },
    }
    const fields = [_]struct { k: u8, v: u32 }{
        .{ .k = 'x', .v = p.source_x },
        .{ .k = 'y', .v = p.source_y },
        .{ .k = 'w', .v = p.source_width },
        .{ .k = 'h', .v = p.source_height },
        .{ .k = 'X', .v = p.x_offset },
        .{ .k = 'Y', .v = p.y_offset },
        .{ .k = 'c', .v = p.columns },
        .{ .k = 'r', .v = p.rows },
    };
    for (fields) |f| {
        if (f.v != 0) w.print(",{c}={d}", .{ f.k, f.v }) catch unreachable;
    }
    if (p.z != 0) w.print(",z={d}", .{p.z}) catch unreachable;
    w.writeAll("\x1b\\") catch unreachable;
    const bytes = w.buffered();
    try writer.writeAll(bytes);
    return bytes.len;
}

/// Rows from the top of the active area to `pin` (negative above it).
fn rowOffset(screen: *const Screen, top: PageList.Pin, pin: PageList.Pin) i64 {
    const top_y = screen.pages.pointFromPin(.screen, top).?.screen.y;
    const pin_y = screen.pages.pointFromPin(.screen, pin).?.screen.y;
    return @as(i64, @intCast(pin_y)) - @as(i64, @intCast(top_y));
}

const testing = std.testing;

test "replay: the Kitty image generation follows image changes only" {
    const alloc = testing.allocator;
    var t = try Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();

    const g0 = t.kittyImageGeneration();
    stream.nextSlice("hello\r\n");
    try testing.expectEqual(g0, t.kittyImageGeneration());

    // Transmit.
    stream.nextSlice("\x1b_Ga=t,q=2,f=32,s=1,v=1,i=1;AAAAAA==\x1b\\");
    const g1 = t.kittyImageGeneration();
    try testing.expect(g1 > g0);

    // Place.
    stream.nextSlice("\x1b_Ga=p,q=2,i=1,c=1,r=1\x1b\\");
    const g2 = t.kittyImageGeneration();
    try testing.expect(g2 > g1);

    // Plain output that scrolls the placement does not change it.
    for (0..20) |_| stream.nextSlice("output\r\n");
    try testing.expectEqual(g2, t.kittyImageGeneration());

    // Delete.
    stream.nextSlice("\x1b_Ga=d,q=2,d=I,i=1\x1b\\");
    const g3 = t.kittyImageGeneration();
    try testing.expect(g3 > g2);

    // The alternate screen's storage counts too.
    stream.nextSlice("\x1b[?1049h\x1b_Ga=t,q=2,f=32,s=1,v=1,i=2;AAAAAA==\x1b\\");
    const g4 = t.kittyImageGeneration();
    try testing.expect(g4 > g3);

    // A reset starts the storages over and still changes it.
    stream.nextSlice("\x1bc");
    try testing.expect(t.kittyImageGeneration() > g4);
}

test "replay: both screens round trip without moving the cursor" {
    const alloc = testing.allocator;
    var owner = try Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 5 });
    defer owner.deinit(alloc);
    var owner_stream = owner.vtStream();
    defer owner_stream.deinit();

    // Primary: an image near the top, then output that moves its
    // placement one row above the active area (it still shows).
    owner_stream.nextSlice("\x1b_Ga=t,q=2,f=32,s=1,v=1,i=3;AAAAAA==\x1b\\");
    owner_stream.nextSlice("\x1b[1;2H\x1b_Ga=p,q=2,i=3,p=1,c=2,r=3,C=1\x1b\\");
    owner_stream.nextSlice("\x1b[5;1H\r\n");
    // Alternate: a numbered image.
    owner_stream.nextSlice("\x1b[?1049h\x1b_Ga=t,q=2,f=24,s=1,v=1,I=4;AAAA\x1b\\");
    owner_stream.nextSlice("\x1b[4;6H\x1b_Ga=p,q=2,I=4,c=1,r=1,z=2,C=1\x1b\\\x1b[2;3H");

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const stats = try encode(alloc, &owner, std.math.maxInt(u64), &out.writer);
    try testing.expectEqual(@as(u64, 2), stats.images);
    try testing.expectEqual(@as(u64, 2), stats.placements);

    // The viewer has the same rows (a snapshot restore would give it
    // them) and the alternate screen active.
    var viewer = try Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 5 });
    defer viewer.deinit(alloc);
    var viewer_stream = viewer.vtStream();
    defer viewer_stream.deinit();
    viewer_stream.nextSlice("\x1b[5;1H\r\n\x1b[?1049h\x1b[2;3H");
    const cursor = viewer.screens.active.cursor;
    viewer_stream.nextSlice(out.written());
    try testing.expectEqual(cursor.x, viewer.screens.active.cursor.x);
    try testing.expectEqual(cursor.y, viewer.screens.active.cursor.y);
    try testing.expectEqual(ScreenSet.Key.alternate, viewer.screens.active_key);

    for (screen_keys) |key| {
        const want = &owner.screens.get(key).?.kitty_images;
        const got = &viewer.screens.get(key).?.kitty_images;
        try testing.expectEqual(want.images.count(), got.images.count());
        var it = want.images.iterator();
        while (it.next()) |entry| {
            const g = got.images.get(entry.key_ptr.*) orelse return error.TestExpectedImage;
            try testing.expectEqual(entry.value_ptr.number, g.number);
            try testing.expectEqualSlices(u8, entry.value_ptr.data.bytes().?, g.data.bytes().?);
        }
        try testing.expectEqual(want.placements.count(), got.placements.count());
        var pit = want.placements.iterator();
        while (pit.next()) |entry| {
            const g = got.placements.get(entry.key_ptr.*) orelse continue;
            const want_pt = owner.screens.get(key).?.pages.pointFromPin(.screen, entry.value_ptr.location.pin.*).?;
            const got_pt = viewer.screens.get(key).?.pages.pointFromPin(.screen, g.location.pin.*).?;
            try testing.expectEqual(want_pt.screen, got_pt.screen);
            try testing.expectEqual(entry.value_ptr.z, g.z);
        }
    }
    // The alternate image kept its number.
    try testing.expectEqual(@as(u32, 4), viewer.screens.get(.alternate).?.kitty_images.imageById(1).?.number);
}
