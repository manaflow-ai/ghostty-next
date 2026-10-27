//! The GPU copy of a font atlas, shared by every frame that samples it.
//!
//! Where the graphics API lets every surface sample one texture (Metal: one
//! device for the app), the textures live on the `font.SharedGrid`, so all
//! surfaces drawing one font share one texture per atlas and a changed atlas
//! is uploaded once. Skia does the same with one glyph atlas per GPU context
//! and a generation that tells its users a new texture replaced the old one
//! (src/gpu/ganesh/GrDrawOpAtlas.h, `atlasGeneration`); Chrome's GPU process
//! shares that context across every tab it rasterizes. OpenGL contexts are
//! per surface, so there each renderer holds its own copy for its frames.
//!
//! Atlas regions are written once and growth makes a new, larger texture,
//! so an in-place upload changes no texel that an encoded frame samples.
const std = @import("std");
const Allocator = std.mem.Allocator;
const font = @import("../font/main.zig");

/// One texture per atlas of a `font.SharedGrid`. The caller holds the grid's
/// lock exclusively for `sync`; references are released without it.
pub fn Set(comptime Texture: type) type {
    return struct {
        const Self = @This();

        pub const Shared = AtlasTexture(Texture);

        grayscale: Shared = .{},
        color: Shared = .{},

        pub fn deinit(self: *Self) void {
            self.grayscale.deinit();
            self.color.deinit();
        }
    };
}

/// The texture of one atlas. `Texture` is a graphics API texture (`width`,
/// `replaceRegion`, `deinit`).
pub fn AtlasTexture(comptime Texture: type) type {
    return struct {
        const Self = @This();

        /// The newest texture, null before the first `sync`. Holds one
        /// reference.
        current: ?*Node = null,

        /// Bumped each time a new texture replaces the old one (atlas
        /// growth); a reference of an older generation moves to the new
        /// texture on its next `sync`.
        generation: u64 = 0,

        /// The atlas `modified` count the current texture holds.
        uploaded: usize = 0,

        const Node = struct {
            alloc: Allocator,
            texture: Texture,
            generation: u64,
            refs: std.atomic.Value(u32),

            fn retain(self: *Node) void {
                _ = self.refs.fetchAdd(1, .monotonic);
            }

            fn release(self: *Node) void {
                if (self.refs.fetchSub(1, .acq_rel) != 1) return;
                self.texture.deinit();
                self.alloc.destroy(self);
            }
        };

        /// A frame's reference to the texture it samples. An older
        /// generation stays alive until every frame holding it moved on.
        pub const Ref = struct {
            node: ?*Node = null,

            /// The atlas `modified` count this reference's texture held
            /// when it was taken.
            modified: usize = 0,

            /// Whether `sync` must run before a frame samples the atlas.
            /// Lock-free: the count is atomic.
            pub fn stale(self: Ref, atlas: *const font.Atlas) bool {
                return self.node == null or
                    atlas.modified.load(.monotonic) > self.modified;
            }

            /// The texture to sample; only after a successful `sync`.
            pub fn texture(self: Ref) Texture {
                return self.node.?.texture;
            }

            pub fn generation(self: Ref) u64 {
                const node = self.node orelse return 0;
                return node.generation;
            }

            pub fn release(self: *Ref) void {
                if (self.node) |node| node.release();
                self.* = .{};
            }
        };

        /// Drops this owner's reference; frames still holding the texture
        /// keep it until they release it.
        pub fn deinit(self: *Self) void {
            if (self.current) |node| node.release();
            self.* = .{};
        }

        /// Brings the texture up to `atlas` (a new texture if the atlas
        /// grew past it, else one upload for every user) and points `ref`
        /// at it. The caller holds the grid lock exclusively.
        pub fn sync(
            self: *Self,
            alloc: Allocator,
            api: anytype,
            atlas: *const font.Atlas,
            ref: *Ref,
        ) !void {
            const grows = if (self.current) |node|
                atlas.size > node.texture.width
            else
                true;
            if (grows) {
                const texture = try api.initAtlasTexture(atlas);
                errdefer texture.deinit();
                const node = try alloc.create(Node);
                node.* = .{
                    .alloc = alloc,
                    .texture = texture,
                    .generation = self.generation + 1,
                    .refs = .init(1),
                };
                if (self.current) |old| old.release();
                self.current = node;
                self.generation = node.generation;
                self.uploaded = 0;
            }

            const node = self.current.?;
            const modified = atlas.modified.load(.monotonic);
            if (modified > self.uploaded) {
                try node.texture.replaceRegion(0, 0, atlas.size, atlas.size, atlas.data);
                self.uploaded = modified;
            }

            if (ref.node != node) {
                node.retain();
                if (ref.node) |old| old.release();
                ref.node = node;
            }
            ref.modified = self.uploaded;
        }
    };
}

const testing = std.testing;

/// A texture that counts what the GPU would do.
const FakeTexture = struct {
    width: usize,
    stats: *Stats,

    const Stats = struct {
        created: usize = 0,
        uploads: usize = 0,
        freed: usize = 0,
    };

    pub fn deinit(self: FakeTexture) void {
        self.stats.freed += 1;
    }

    pub fn replaceRegion(
        self: FakeTexture,
        x: usize,
        y: usize,
        width: usize,
        height: usize,
        data: []const u8,
    ) error{}!void {
        _ = .{ x, y, height, data };
        std.debug.assert(width <= self.width);
        self.stats.uploads += 1;
    }
};

const FakeApi = struct {
    stats: FakeTexture.Stats = .{},

    pub fn initAtlasTexture(self: *FakeApi, atlas: *const font.Atlas) error{}!FakeTexture {
        self.stats.created += 1;
        return .{ .width = atlas.size, .stats = &self.stats };
    }
};

const FakeShared = AtlasTexture(FakeTexture);

fn addGlyph(alloc: Allocator, atlas: *font.Atlas) !void {
    const region = try atlas.reserve(alloc, 2, 2);
    atlas.set(region, &.{ 1, 2, 3, 4 });
}

test "two surfaces with one font share the texture, uploaded once per change" {
    const alloc = testing.allocator;
    var atlas: font.Atlas = try .init(alloc, 16, .grayscale);
    defer atlas.deinit(alloc);
    var api: FakeApi = .{};

    var shared: FakeShared = .{};
    var a: FakeShared.Ref = .{};
    var b: FakeShared.Ref = .{};

    try shared.sync(alloc, &api, &atlas, &a);
    try testing.expect(b.stale(&atlas));
    try shared.sync(alloc, &api, &atlas, &b);
    try testing.expectEqual(a.node, b.node);
    try testing.expectEqual(@as(usize, 1), api.stats.created);
    try testing.expectEqual(@as(usize, 1), api.stats.uploads);

    // A new glyph: the first surface to draw uploads it, the second finds
    // it already on the GPU.
    try addGlyph(alloc, &atlas);
    try testing.expect(a.stale(&atlas));
    try testing.expect(b.stale(&atlas));
    try shared.sync(alloc, &api, &atlas, &a);
    try shared.sync(alloc, &api, &atlas, &b);
    try testing.expectEqual(@as(usize, 2), api.stats.uploads);
    try testing.expect(!a.stale(&atlas));
    try testing.expect(!b.stale(&atlas));

    a.release();
    b.release();
    try testing.expectEqual(@as(usize, 0), api.stats.freed);
    shared.deinit();
    try testing.expectEqual(@as(usize, 1), api.stats.freed);
}

test "atlas growth reaches every user through the generation" {
    const alloc = testing.allocator;
    var atlas: font.Atlas = try .init(alloc, 16, .grayscale);
    defer atlas.deinit(alloc);
    var api: FakeApi = .{};

    var shared: FakeShared = .{};
    defer shared.deinit();
    var a: FakeShared.Ref = .{};
    defer a.release();
    var b: FakeShared.Ref = .{};
    defer b.release();

    try shared.sync(alloc, &api, &atlas, &a);
    try shared.sync(alloc, &api, &atlas, &b);
    try testing.expectEqual(@as(u64, 1), a.generation());

    try atlas.grow(alloc, 32);
    try testing.expect(a.stale(&atlas));
    try testing.expect(b.stale(&atlas));

    // The first user makes the larger texture; the old one stays alive for
    // the second, which may have frames sampling it.
    try shared.sync(alloc, &api, &atlas, &a);
    try testing.expectEqual(@as(u64, 2), a.generation());
    try testing.expectEqual(@as(u64, 1), b.generation());
    try testing.expectEqual(@as(usize, 2), api.stats.created);
    try testing.expectEqual(@as(usize, 0), api.stats.freed);

    // The second user moves to it on its next sync, without an upload, and
    // the old texture goes with the last reference.
    try shared.sync(alloc, &api, &atlas, &b);
    try testing.expectEqual(@as(u64, 2), b.generation());
    try testing.expectEqual(a.node, b.node);
    try testing.expectEqual(@as(usize, 2), api.stats.uploads);
    try testing.expectEqual(@as(usize, 1), api.stats.freed);
    try testing.expectEqual(@as(usize, 32), a.texture().width);
}

test "a released reference syncs again from the start" {
    const alloc = testing.allocator;
    var atlas: font.Atlas = try .init(alloc, 16, .bgra);
    defer atlas.deinit(alloc);
    var api: FakeApi = .{};

    var shared: FakeShared = .{};
    defer shared.deinit();
    var a: FakeShared.Ref = .{};
    defer a.release();

    try shared.sync(alloc, &api, &atlas, &a);
    try testing.expect(!a.stale(&atlas));
    a.release();
    try testing.expect(a.stale(&atlas));
    try shared.sync(alloc, &api, &atlas, &a);
    try testing.expectEqual(@as(usize, 1), api.stats.created);
    try testing.expectEqual(@as(usize, 1), api.stats.uploads);
}
