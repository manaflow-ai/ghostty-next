//! Kitty graphics replay: a Kitty graphics APC byte stream that recreates
//! the images and placements of a terminal's active areas in another
//! terminal (a snapshot viewer) that restored the same snapshot. The
//! GHOSTSNP format carries no images; the owner sends this stream after
//! the snapshot.
//!
//! C API: ghostty_terminal_kitty_replay_encode writes the stream (`encode`);
//! ghostty_terminal_kitty_replay_apply (libghostty-vt) and
//! ghostty_surface_apply_kitty_replay (embedded MANUAL surfaces) apply it
//! (`apply`). The stream must never go through the program output path
//! (vt_write, ghostty_surface_process_output): there its private keys are
//! ignored, so it does not recreate the state, and the parser may be in
//! the middle of a sequence that a READY restored.
//!
//! The stream, in order:
//!
//! 1. For each screen the owner has: a reset (a=d,R=<cursor>) that clears
//!    the screen's images, placements and any in-progress upload in the
//!    viewer and sets the owner's implicit image-ID cursor. So images that
//!    a local-history restore carried, or that the owner deleted, and
//!    internal-ID placements cannot double.
//! 2. Every stored image of the owner with its image ID and image number:
//!    first the images that are not selected (below), metadata only (M=1:
//!    ID, number, size, format, no pixels; the viewer stores a pending
//!    image that holds no bytes and is not drawn), then the selected ones
//!    in full, each group oldest first (by generation, the transmission
//!    order). So the viewer has the same image IDs, a later numbered
//!    transmission (I=) picks the same free ID on both sides, and a viewer
//!    with a smaller image count limit evicts metadata entries (older,
//!    without placements) before a full image. A number that a metadata
//!    entry and a full image share finds the full image in the viewer.
//! 3. The placements that show in the active areas of the selected
//!    images: pinned and virtual ones first, then relative ones, parents
//!    before children.
//!
//! Selected images: those that a placement showing in the primary active
//! area or on the alternate screen uses. A placement shows when it is
//! pinned to a cell and its rectangle reaches into the active area (a
//! placement only in scrollback does not), when it is virtual (U=1,
//! unicode placeholder), or when it is relative (P=) and its parent chain
//! ends at such a placement. A relative placement whose parent has an
//! internal ID is replayed only when the parent image has exactly one
//! placement (an internal ID cannot be named, and the viewer resolves
//! Q=0 to that one placement); otherwise it is skipped. A chain with an
//! image whose data is still loading is skipped. A placement keeps its
//! image ID, external placement ID (an internal p=0 ID is assigned again),
//! z-index, cell offsets, source rectangle, columns and rows, parent and
//! parent offsets.
//!
//! Byte cap: candidates are taken newest first while their decoded pixel
//! bytes (RGB or RGBA as stored, grayscale counted as RGBA) fit the cap;
//! the first that does not fit and every older one go as metadata only,
//! with their placements skipped, and are counted as skipped.
//!
//! Wire format. Every command is quiet (q=2). A full image goes inline
//! (t=d) as zlib (o=z, fastest level) raw pixels: the storage holds
//! decoded pixels only (a PNG was decoded at load, so f=100 never occurs),
//! RGB as f=24 and RGBA as f=32 (grayscale is widened to f=32). Its base64
//! payload is cut into chunks of at most 4096 bytes. The private keys of
//! Command.Replay (E screen on every command, J number, B/L position, R
//! reset, M metadata) mean the stream moves no cursor and switches no
//! screen. Only a trusted parser reads them.
//!
//! Not replayed: animation frames and state (only the root frame), the
//! data of images still loading (metadata only), an in-progress chunked
//! upload, and the internal placement ID values. A pinned placement above
//! the active area needs its row in the viewer (history restored before
//! the stream); the viewer drops it otherwise.
//!
//! Encoding only reads the terminal and holds one compressed image at a
//! time. The caller holds the terminal's lock.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

const Terminal = @import("../Terminal.zig");
const Screen = @import("../Screen.zig");
const ScreenSet = @import("../ScreenSet.zig");
const PageList = @import("../PageList.zig");
const command = @import("graphics_command.zig");
const exec = @import("graphics_exec.zig");
const Image = @import("graphics_image.zig").Image;
const ImageStorage = @import("graphics_storage.zig").ImageStorage;
const Placement = ImageStorage.Placement;
const PlacementKey = ImageStorage.PlacementKey;
const Replay = command.Command.Replay;

/// The Kitty limit for the base64 payload of one chunk.
pub const chunk_len = 4096;

/// Raw bytes per chunk: 4096 base64 bytes.
const chunk_raw_len = chunk_len / 4 * 3;

/// What one encode wrote.
pub const Stats = struct {
    /// Images transmitted with their pixels.
    images: u64 = 0,
    /// Placements written.
    placements: u64 = 0,
    /// Images that a showing placement uses but that the byte cap
    /// skipped (sent as metadata only; their placements are skipped).
    skipped_images: u64 = 0,
    /// Decoded pixel bytes of the transmitted images (what the cap
    /// limits).
    image_bytes: u64 = 0,
    /// All bytes written.
    bytes: u64 = 0,
};

pub const Error = Allocator.Error || std.Io.Writer.Error;

/// Write the replay stream of `t` to `writer`. `max_image_bytes` caps the
/// decoded pixel bytes of the full images (std.math.maxInt(u64) for no
/// cap).
pub fn encode(
    alloc: Allocator,
    t: *const Terminal,
    max_image_bytes: u64,
    writer: *std.Io.Writer,
) Error!Stats {
    var stats: Stats = .{};
    var out: Counting = .{ .w = writer, .stats = &stats };

    // 1. Resets.
    for (screen_keys) |key| {
        const screen = t.screens.get(key) orelse continue;
        try out.print("\x1b_Ga=d,q=2,{c}={d},{c}={d}\x1b\\", .{
            Replay.screen_key,
            screenValue(key),
            Replay.reset_key,
            screen.kitty_images.imageIdCursor(),
        });
    }

    // The showing placements and the images they use, per screen.
    var selections: [screen_keys.len]Selection = undefined;
    var selected: usize = 0;
    defer for (selections[0..selected]) |*s| s.deinit(alloc);
    for (screen_keys, 0..) |key, i| {
        selections[i] = try .init(alloc, t, key);
        selected += 1;
    }

    // Every stored image, and which ones placements use.
    var images: std.ArrayList(Candidate) = .empty;
    defer images.deinit(alloc);
    for (screen_keys, 0..) |key, si| {
        const screen = t.screens.get(key) orelse continue;
        var it = screen.kitty_images.images.iterator();
        while (it.next()) |entry| try images.append(alloc, .{
            .screen = si,
            .id = entry.key_ptr.*,
            .generation = entry.value_ptr.generation,
            .used = selections[si].images.contains(entry.key_ptr.*),
        });
    }

    // Select used images newest first while their decoded bytes fit.
    std.mem.sort(Candidate, images.items, {}, Candidate.newerFirst);
    var full = true;
    for (images.items) |*c| {
        if (!c.used) continue;
        const img = imageOf(t, c.*);
        const len = decodedLen(img);
        if (full and len <= max_image_bytes - stats.image_bytes) {
            c.send = true;
            stats.image_bytes += len;
        } else {
            full = false;
            stats.skipped_images += 1;
        }
    }

    // 2. Images, oldest first: every metadata-only entry, then every full
    // image. A viewer that stores fewer images than the owner evicts the
    // oldest image without placements first, so a full image (newer than
    // every metadata entry) never makes room for a metadata entry.
    for ([_]bool{ false, true }) |full_pass| {
        var next = images.items.len;
        while (next > 0) {
            next -= 1;
            const c = images.items[next];
            if (c.send != full_pass) continue;
            const img = imageOf(t, c);
            if (c.send) {
                try writeImage(alloc, &out, screen_keys[c.screen], img);
                stats.images += 1;
                try selections[c.screen].sent.put(alloc, c.id, {});
            } else {
                try writeMetadata(&out, screen_keys[c.screen], img);
            }
        }
    }

    // 3. Placements, parents first.
    for (selections[0..selected], 0..) |*s, si| {
        const screen = t.screens.get(screen_keys[si]) orelse continue;
        const storage = &screen.kitty_images;
        for (s.placements.items) |entry| {
            if (!s.chainSent(storage, entry.key)) continue;
            const p = storage.placements.get(entry.key).?;
            // A relative placement needs its parent written.
            if (p.location == .relative and !s.written.contains(p.location.relative.parent)) continue;
            try writePlacement(&out, screen, screen_keys[si], entry.key, p);
            stats.placements += 1;
            try s.written.put(alloc, entry.key, {});
        }
    }

    return stats;
}

pub const ApplyError = Allocator.Error || error{InvalidReplay};

/// The largest replay command that `apply` takes.
const max_command_bytes = 1024 * 1024;

/// Apply a complete replay stream to `t` (the trusted path: the private
/// keys work here). Each command is parsed by its own trusted parser; the
/// terminal's VT parser state is not used or changed, and nothing is
/// written anywhere (every reply is dropped). Only these commands run:
/// transmit (a=t, direct medium only; M=1 for metadata only), display
/// (a=p) and the reset (a=d with R). Anything else (another action, a=T,
/// bytes outside `ESC _ G ... ESC \`, a malformed or truncated command) is
/// skipped and makes the result error.InvalidReplay after the rest of the
/// stream is applied. The caller holds the terminal's lock.
pub fn apply(
    io: std.Io,
    alloc: Allocator,
    t: *Terminal,
    bytes: []const u8,
) ApplyError!void {
    // A chunked upload that the stream opened and did not finish (the
    // stream ended after an m=1 chunk, or was cut) is destroyed, so a
    // later chunk from program output cannot finish it with the trusted
    // ID and number.
    var touched: [screen_keys.len]bool = @splat(false);
    const result = applyCommands(io, alloc, t, bytes, &touched);
    var open = false;
    for (screen_keys, touched) |key, was_touched| {
        if (!was_touched) continue;
        const screen = t.screens.get(key) orelse continue;
        const storage = &screen.kitty_images;
        if (storage.loading) |loading| {
            loading.destroy(alloc);
            storage.loading = null;
            open = true;
        }
    }
    try result;
    if (open) return error.InvalidReplay;
}

fn applyCommands(
    io: std.Io,
    alloc: Allocator,
    t: *Terminal,
    bytes: []const u8,
    touched: *[screen_keys.len]bool,
) ApplyError!void {
    var invalid = false;
    var rest = bytes;
    while (rest.len > 0) {
        if (!std.mem.startsWith(u8, rest, "\x1b_G")) return error.InvalidReplay;
        const end = std.mem.indexOfPos(u8, rest, 3, "\x1b\\") orelse return error.InvalidReplay;
        const body = rest[3..end];
        rest = rest[end + 2 ..];

        var parser = command.Parser.init(alloc, max_command_bytes);
        parser.trusted = true;
        defer parser.deinit();
        parser.feedSlice(body) catch |err| {
            if (err == error.OutOfMemory and body.len <= max_command_bytes) return error.OutOfMemory;
            invalid = true;
            continue;
        };
        var cmd = parser.complete(alloc) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            invalid = true;
            continue;
        };
        defer cmd.deinit(alloc);
        if (!try applyCommand(io, alloc, t, &cmd, touched)) invalid = true;
    }
    if (invalid) return error.InvalidReplay;
}

/// Run one trusted replay command. False if it is not a replay command.
fn applyCommand(
    io: std.Io,
    alloc: Allocator,
    t: *Terminal,
    cmd: *command.Command,
    touched: *[screen_keys.len]bool,
) Allocator.Error!bool {
    const key: ScreenSet.Key = if (cmd.replay.screen) |screen| switch (screen) {
        .primary => .primary,
        .alternate => .alternate,
    } else t.screens.active_key;
    touched[switch (key) {
        .primary => 0,
        .alternate => 1,
    }] = true;

    switch (cmd.control) {
        .delete => {
            if (cmd.replay.reset == 0) return false;
            const screen = t.screens.get(key) orelse return true;
            screen.kitty_images.clearAll(io, alloc, screen, cmd.replay.reset);
            return true;
        },

        .transmit => |tr| {
            if (tr.medium != .direct) return false;
            if (cmd.replay.metadata) {
                if (tr.image_id == 0 or tr.image_number != 0) return false;
                const screen = t.screens.get(key) orelse return true;
                if (!screen.kitty_images.enabled()) return true;
                const format: command.Transmission.Format = switch (tr.format) {
                    .rgb, .rgba => tr.format,
                    else => return false,
                };
                _ = screen.kitty_images.addPendingImage(io, alloc, screen, .{
                    .id = tr.image_id,
                    .number = cmd.replay.number,
                    .width = tr.width,
                    .height = tr.height,
                    .format = format,
                    .data = .{ .pending = 0 },
                }) catch |err| switch (err) {
                    error.OutOfMemory => return true, // limits refused it, as a transmit would be
                };
                return true;
            }
        },

        // A replayed placement never moves the cursor (C=1 always).
        .display => |*d| {
            d.cursor_movement = .none;
        },

        else => return false,
    }

    _ = exec.execute(io, alloc, t, cmd);
    return true;
}

const screen_keys = [_]ScreenSet.Key{ .primary, .alternate };

const Candidate = struct {
    /// Index into screen_keys.
    screen: usize,
    id: u32,
    generation: u64,
    /// A showing placement uses it.
    used: bool,
    /// Sent with its pixels.
    send: bool = false,

    fn newerFirst(_: void, a: Candidate, b: Candidate) bool {
        if (a.generation != b.generation) return a.generation > b.generation;
        if (a.screen != b.screen) return a.screen < b.screen;
        return a.id < b.id;
    }
};

fn imageOf(t: *const Terminal, c: Candidate) Image {
    return t.screens.get(screen_keys[c.screen]).?.kitty_images.images.get(c.id).?;
}

/// Decoded bytes as sent: grayscale is widened to RGBA.
fn decodedLen(img: Image) u64 {
    const data = img.data.bytes() orelse return 0;
    return switch (img.format) {
        .gray => @as(u64, data.len) * 4,
        .gray_alpha => @as(u64, data.len) * 2,
        else => data.len,
    };
}

/// A writer that counts the bytes into the stats.
const Counting = struct {
    w: *std.Io.Writer,
    stats: *Stats,

    fn writeAll(self: *Counting, bytes: []const u8) std.Io.Writer.Error!void {
        try self.w.writeAll(bytes);
        self.stats.bytes += bytes.len;
    }

    fn print(self: *Counting, comptime fmt: []const u8, args: anytype) std.Io.Writer.Error!void {
        var buf: [256]u8 = undefined;
        var fixed: std.Io.Writer = .fixed(&buf);
        fixed.print(fmt, args) catch unreachable; // commands are short
        try self.writeAll(fixed.buffered());
    }
};

/// The showing placements of one screen and the images they use.
const Selection = struct {
    const Entry = struct { key: PlacementKey, depth: usize };

    placements: std.ArrayList(Entry) = .empty,
    images: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Images sent with pixels and placements written, during the encode.
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
                    break :depth relativeDepth(t, screen, rel) orelse continue;
                },
            };
            try self.placements.append(alloc, .{ .key = entry.key_ptr.*, .depth = depth });
        }

        // The images of every placement and of every parent up its chain.
        for (self.placements.items) |entry| {
            var k = entry.key;
            while (storage.placements.get(k)) |p| {
                try self.images.put(alloc, k.image_id, {});
                if (p.location != .relative) break;
                k = p.location.relative.parent;
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

    /// Whether every image up the placement's chain was sent.
    fn chainSent(self: *const Selection, storage: *const ImageStorage, key: PlacementKey) bool {
        var k = key;
        while (storage.placements.get(k)) |p| {
            if (!self.sent.contains(k.image_id)) return false;
            if (p.location != .relative) return true;
            k = p.location.relative.parent;
        }
        return false;
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

/// The chain depth of a relative placement that shows and can be
/// replayed, or null: its chain must end at a showing pinned or virtual
/// placement, every image on it must have its data, and every parent with
/// an internal ID must be its image's only placement.
fn relativeDepth(t: *const Terminal, screen: *const Screen, rel: Placement.Relative) ?usize {
    const storage = &screen.kitty_images;
    var depth: usize = 0;
    var parent = rel.parent;
    while (true) {
        depth += 1;
        if (depth > ImageStorage.parent_chain_limit) return null;
        const p = storage.placements.get(parent) orelse return null;
        const img = storage.images.get(parent.image_id) orelse return null;
        if (img.data.bytes() == null) return null;
        if (parent.placement_id.tag == .internal and img.metadata.placement_count != 1) return null;
        switch (p.location) {
            .virtual => return depth,
            .pin => return if (pinShows(t, screen, img, p)) depth else null,
            .relative => |next| parent = next.parent,
        }
    }
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

/// The protocol format of an image as sent.
fn wireFormat(img: Image) u8 {
    return switch (img.format) {
        .rgb => 24,
        else => 32,
    };
}

/// A metadata-only image (M=1).
fn writeMetadata(out: *Counting, key: ScreenSet.Key, img: Image) std.Io.Writer.Error!void {
    try out.print("\x1b_Ga=t,q=2,t=d,f={d},s={d},v={d},i={d}", .{
        wireFormat(img),
        img.width,
        img.height,
        img.id,
    });
    if (img.number > 0) try out.print(",{c}={d}", .{ Replay.number_key, img.number });
    try out.print(",{c}={d},{c}=1\x1b\\", .{
        Replay.screen_key,
        screenValue(key),
        Replay.metadata_key,
    });
}

/// The transmission commands of one image. Holds one compressed copy.
fn writeImage(alloc: Allocator, out: *Counting, key: ScreenSet.Key, img: Image) Error!void {
    const data = img.data.bytes().?;

    // RGB and RGBA go as stored; grayscale widens to RGBA.
    var widened: ?[]u8 = null;
    defer if (widened) |w| alloc.free(w);
    const pixels: []const u8 = switch (img.format) {
        .rgb, .rgba => data,
        .gray, .gray_alpha => pixels: {
            const bpp: usize = if (img.format == .gray) 1 else 2;
            const count = data.len / bpp;
            const wide = try alloc.alloc(u8, count * 4);
            widened = wide;
            for (0..count) |px| {
                const v = data[px * bpp];
                wide[px * 4 + 0] = v;
                wide[px * 4 + 1] = v;
                wide[px * 4 + 2] = v;
                wide[px * 4 + 3] = if (bpp == 2) data[px * bpp + 1] else 255;
            }
            break :pixels wide;
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
        compress.* = flate.Compress.init(&deflated.writer, window, .zlib, .fastest) catch
            return error.OutOfMemory;
        compress.writer.writeAll(pixels) catch return error.OutOfMemory;
        compress.finish() catch return error.OutOfMemory;
    }
    const zlib = deflated.written();

    const b64 = std.base64.standard.Encoder;
    const screen = screenValue(key);
    var offset: usize = 0;
    var first = true;
    while (true) {
        const end = @min(offset + chunk_raw_len, zlib.len);
        const more: u8 = if (end < zlib.len) 1 else 0;
        if (first) {
            try out.print("\x1b_Ga=t,q=2,t=d,f={d},o=z,s={d},v={d},i={d}", .{
                wireFormat(img),
                img.width,
                img.height,
                img.id,
            });
            if (img.number > 0) try out.print(",{c}={d}", .{ Replay.number_key, img.number });
            if (img.metadata.transient) try out.writeAll(",N=1");
        } else {
            try out.writeAll("\x1b_Gq=2");
        }
        try out.print(",{c}={d},m={d};", .{ Replay.screen_key, screen, more });
        var encoded: [chunk_len]u8 = undefined;
        try out.writeAll(b64.encode(&encoded, zlib[offset..end]));
        try out.writeAll("\x1b\\");
        first = false;
        offset = end;
        if (more == 0) break;
    }
}

/// Write one placement command.
fn writePlacement(
    out: *Counting,
    screen: *const Screen,
    key: ScreenSet.Key,
    pkey: PlacementKey,
    p: Placement,
) std.Io.Writer.Error!void {
    try out.print("\x1b_Ga=p,q=2,i={d}", .{pkey.image_id});
    if (pkey.placement_id.tag == .external) {
        try out.print(",p={d}", .{pkey.placement_id.id});
    }
    try out.print(",{c}={d}", .{ Replay.screen_key, screenValue(key) });
    switch (p.location) {
        .pin => |pin| try out.print(",{c}={d},{c}={d},C=1", .{
            Replay.row_key,
            rowOffset(screen, pin.*),
            Replay.col_key,
            pin.x,
        }),
        .virtual => try out.writeAll(",U=1"),
        .relative => |rel| {
            try out.print(",P={d}", .{rel.parent.image_id});
            if (rel.parent.placement_id.tag == .external) {
                try out.print(",Q={d}", .{rel.parent.placement_id.id});
            }
            if (rel.horizontal_offset != 0) try out.print(",H={d}", .{rel.horizontal_offset});
            if (rel.vertical_offset != 0) try out.print(",V={d}", .{rel.vertical_offset});
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
        if (f.v != 0) try out.print(",{c}={d}", .{ f.k, f.v });
    }
    if (p.z != 0) try out.print(",z={d}", .{p.z});
    try out.writeAll("\x1b\\");
}

/// Rows from the top of the active area to `pin` (negative above it).
fn rowOffset(screen: *const Screen, pin: PageList.Pin) i64 {
    const top = screen.pages.pin(.{ .active = .{} }).?;
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
    try apply(testing.io, alloc, &viewer, out.written());
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
            const g = got.placements.get(entry.key_ptr.*) orelse return error.TestExpectedPlacement;
            const want_pt = owner.screens.get(key).?.pages.pointFromPin(.screen, entry.value_ptr.location.pin.*).?;
            const got_pt = viewer.screens.get(key).?.pages.pointFromPin(.screen, g.location.pin.*).?;
            try testing.expectEqual(want_pt.screen, got_pt.screen);
            try testing.expectEqual(entry.value_ptr.z, g.z);
        }
    }
    // The alternate image kept its number.
    try testing.expectEqual(@as(u32, 4), viewer.screens.get(.alternate).?.kitty_images.imageById(1).?.number);
}

test "replay: program output ignores the private keys" {
    const alloc = testing.allocator;
    var t = try Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();

    // Enter and leave the alternate screen so it exists.
    stream.nextSlice("\x1b[?1049h\x1b[?1049l");
    stream.nextSlice("\x1b_Ga=t,q=2,f=32,s=1,v=1,i=1,J=9,E=1,M=1;AAAAAA==\x1b\\");
    stream.nextSlice("\x1b_Ga=t,q=2,f=32,s=1,v=1,i=2,E=2;AAAAAA==\x1b\\");
    stream.nextSlice("\x1b[2;3H\x1b_Ga=p,q=2,i=1,p=4,B=3,L=0,E=1,c=1,r=1,C=1\x1b\\");
    stream.nextSlice("\x1b_Ga=p,q=2,i=2,p=5,L=1,c=1,r=1,C=1\x1b\\");
    stream.nextSlice("\x1b_Ga=d,q=2,d=i,i=99,R=5\x1b\\");

    const primary = &t.screens.get(.primary).?.kitty_images;
    try testing.expectEqual(@as(usize, 2), primary.images.count());
    try testing.expectEqual(@as(u32, 0), primary.imageById(1).?.number);
    try testing.expect(!primary.imageById(1).?.data.isPending());
    try testing.expectEqual(@as(usize, 2), primary.placements.count());
    var it = primary.placements.iterator();
    while (it.next()) |entry| {
        const pt = t.screens.get(.primary).?.pages.pointFromPin(.active, entry.value_ptr.location.pin.*).?;
        try testing.expectEqual(@as(u32, 2), pt.active.x);
        try testing.expectEqual(@as(u32, 1), pt.active.y);
    }
    try testing.expectEqual(@as(usize, 0), t.screens.get(.alternate).?.kitty_images.images.count());
}

test "replay: apply skips foreign commands and replaces the storage" {
    const alloc = testing.allocator;
    var t = try Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    // Existing images and an internal-ID placement.
    stream.nextSlice("\x1b_Ga=T,q=2,f=32,s=1,v=1,i=7,c=1,r=1,C=1;AAAAAA==\x1b\\");

    const bytes = "\x1b_Ga=d,q=2,E=0,R=40\x1b\\" ++
        "\x1b_Ga=T,q=2,f=32,s=1,v=1,i=8,E=0;AAAAAA==\x1b\\" ++ // a=T is refused
        "\x1b_Ga=t,q=2,t=f,f=32,s=1,v=1,i=9,E=0;L3RtcC94\x1b\\" ++ // file medium is refused
        "\x1b_Ga=t,q=2,f=32,s=1,v=1,i=3,E=0;AAAAAA==\x1b\\" ++
        "\x1b_Ga=p,q=2,i=3,E=0,B=1,L=2,c=1,r=1,C=1\x1b\\";
    try testing.expectError(error.InvalidReplay, apply(testing.io, alloc, &t, bytes));
    try testing.expectError(error.InvalidReplay, apply(testing.io, alloc, &t, "junk"));

    const storage = &t.screens.get(.primary).?.kitty_images;
    try testing.expectEqual(@as(usize, 1), storage.images.count());
    try testing.expect(storage.imageById(3) != null);
    try testing.expectEqual(@as(usize, 1), storage.placements.count());
    try testing.expectEqual(@as(u32, 40), storage.imageIdCursor());
    var it = storage.placements.iterator();
    const pin = it.next().?.value_ptr.location.pin;
    const pt = t.screens.get(.primary).?.pages.pointFromPin(.active, pin.*).?;
    try testing.expectEqual(@as(u32, 2), pt.active.x);
    try testing.expectEqual(@as(u32, 1), pt.active.y);
    // The cursor did not move.
    try testing.expectEqual(@as(@TypeOf(t.screens.active.cursor.x), 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(@TypeOf(t.screens.active.cursor.y), 0), t.screens.active.cursor.y);
}

test "replay: image IDs stay equal for later transmissions" {
    const alloc = testing.allocator;
    var owner = try Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 5 });
    defer owner.deinit(alloc);
    var owner_stream = owner.vtStream();
    defer owner_stream.deinit();
    // ID 1 placed, ID 2 never placed (not sent with pixels), and an
    // implicit ID.
    owner_stream.nextSlice("\x1b_Ga=T,q=2,f=32,s=1,v=1,i=1,c=1,r=1,C=1;AAAAAA==\x1b\\");
    owner_stream.nextSlice("\x1b_Ga=t,q=2,f=32,s=1,v=1,i=2;AAAAAA==\x1b\\");
    owner_stream.nextSlice("\x1b_Ga=t,q=2,f=32,s=1,v=1;AAAAAA==\x1b\\");

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const stats = try encode(alloc, &owner, std.math.maxInt(u64), &out.writer);
    try testing.expectEqual(@as(u64, 1), stats.images);

    var viewer = try Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 5 });
    defer viewer.deinit(alloc);
    var viewer_stream = viewer.vtStream();
    defer viewer_stream.deinit();
    try apply(testing.io, alloc, &viewer, out.written());

    // A numbered and an implicit transmission pick the same IDs.
    const later = "\x1b_Ga=t,q=2,f=32,s=1,v=1,I=5;AAAAAA==\x1b\\" ++
        "\x1b_Ga=t,q=2,f=32,s=1,v=1;AAAAAA==\x1b\\";
    owner_stream.nextSlice(later);
    viewer_stream.nextSlice(later);
    const want = &owner.screens.get(.primary).?.kitty_images;
    const got = &viewer.screens.get(.primary).?.kitty_images;
    try testing.expectEqual(want.images.count(), got.images.count());
    var it = want.images.iterator();
    while (it.next()) |entry| {
        const g = got.images.get(entry.key_ptr.*) orelse return error.TestExpectedImage;
        try testing.expectEqual(entry.value_ptr.number, g.number);
    }
    try testing.expectEqual(@as(u32, 3), want.imageByNumber(5).?.id);
}

test "replay: an upload that apply opened never joins program output" {
    const alloc = testing.allocator;
    const first = "\x1b_Ga=d,q=2,E=0,R=40\x1b\\" ++
        "\x1b_Ga=t,q=2,f=32,s=1,v=1,i=4,J=6,E=0,m=1;AAAA\x1b\\";
    // A stream that ends after an m=1 chunk, and one cut inside a command.
    const streams = [_][]const u8{ first, first ++ "\x1b_Gq=2,E=0,m=1;AA" };
    for (streams) |bytes| {
        var t = try Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 5 });
        defer t.deinit(alloc);
        var stream = t.vtStream();
        defer stream.deinit();
        try testing.expectError(error.InvalidReplay, apply(testing.io, alloc, &t, bytes));
        const storage = &t.screens.get(.primary).?.kitty_images;
        try testing.expect(storage.loading == null);

        // The final chunk from program output starts nothing it could
        // finish: no image 4, no number 6.
        stream.nextSlice("\x1b_Gm=0,q=2;AA==\x1b\\");
        try testing.expect(storage.imageById(4) == null);
        try testing.expect(storage.imageByNumber(6) == null);
    }
}

test "replay: apply never moves the cursor" {
    const alloc = testing.allocator;
    var t = try Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("top\x1b[5;3H");

    // A display without C=1 on the bottom row would move the cursor and
    // scroll.
    try apply(testing.io, alloc, &t, "\x1b_Ga=d,q=2,E=0,R=40\x1b\\" ++
        "\x1b_Ga=t,q=2,f=32,s=1,v=1,i=3,E=0;AAAAAA==\x1b\\" ++
        "\x1b_Ga=p,q=2,i=3,E=0,B=4,L=0,c=2,r=3\x1b\\");
    try testing.expectEqual(@as(@TypeOf(t.screens.active.cursor.x), 2), t.screens.active.cursor.x);
    try testing.expectEqual(@as(@TypeOf(t.screens.active.cursor.y), 4), t.screens.active.cursor.y);
    const text = try t.plainString(alloc);
    defer alloc.free(text);
    try testing.expect(std.mem.startsWith(u8, text, "top"));
    try testing.expectEqual(@as(usize, 1), t.screens.get(.primary).?.kitty_images.placements.count());
}

test "replay: metadata entries never evict a full image" {
    const alloc = testing.allocator;
    var owner = try Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 5 });
    defer owner.deinit(alloc);
    var owner_stream = owner.vtStream();
    defer owner_stream.deinit();
    // Image 1 placed (full); images 2 and 3, newer and unplaced, go as
    // metadata only.
    owner_stream.nextSlice("\x1b_Ga=T,q=2,f=32,s=1,v=1,i=1,c=1,r=1,C=1;AAAAAA==\x1b\\");
    owner_stream.nextSlice("\x1b_Ga=t,q=2,f=32,s=1,v=1,i=2;AAAAAA==\x1b\\");
    owner_stream.nextSlice("\x1b_Ga=t,q=2,f=32,s=1,v=1,i=3;AAAAAA==\x1b\\");
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    _ = try encode(alloc, &owner, std.math.maxInt(u64), &out.writer);

    // The viewer stores at most two images.
    var viewer = try Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 5 });
    defer viewer.deinit(alloc);
    viewer.setKittyGraphicsImageCountLimit(alloc, 2);
    try apply(testing.io, alloc, &viewer, out.written());
    const storage = &viewer.screens.get(.primary).?.kitty_images;
    const one = storage.imageById(1) orelse return error.TestExpectedImage;
    try testing.expect(!one.data.isPending());
    try testing.expectEqual(@as(usize, 1), storage.placements.count());
}
