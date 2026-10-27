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
//! The upload goes through the graphics API's `uploadAtlasTexture`, which
//! orders it on the GPU timeline after the frames already submitted and
//! before every frame submitted later (Metal: a blit from a staging buffer
//! on the device's one command queue; OpenGL: the context's own command
//! order). The CPU never writes a texture a submitted frame may be reading,
//! as Skia never writes an atlas plot the GPU still uses: its uploads are
//! deferred into the flush (src/gpu/ganesh/GrOpFlushState.cpp,
//! `doUpload`). Atlas regions are written once, so a frame encoded before
//! an upload still finds its glyphs after it.
//!
//! Locking: `sync` reads the atlas under the grid lock held shared, like
//! every glyph lookup, so an upload never stops another surface's text
//! work. Each texture's own mutex serializes its syncers; a glyph writer
//! (grid lock exclusive) waits only for syncs already reading the atlas.
const std = @import("std");
const Allocator = std.mem.Allocator;
const font = @import("../font/main.zig");

/// One texture per atlas of a `font.SharedGrid`. References are released
/// without any lock.
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

        /// Points both references at textures holding `grid`'s atlases.
        /// `grid` has `lock` (`std.Io.RwLock`), `atlas_grayscale` and
        /// `atlas_color` (a `font.SharedGrid`). Takes the grid lock shared:
        /// glyph lookups on other surfaces run during the upload.
        pub fn sync(
            self: *Self,
            alloc: Allocator,
            io: std.Io,
            api: anytype,
            grid: anytype,
            grayscale: *Shared.Ref,
            color: *Shared.Ref,
        ) !void {
            grid.lock.lockSharedUncancelable(io);
            defer grid.lock.unlockShared(io);
            try self.grayscale.sync(alloc, io, api, &grid.atlas_grayscale, grayscale);
            try self.color.sync(alloc, io, api, &grid.atlas_color, color);
        }
    };
}

/// The texture of one atlas. `Texture` is a graphics API texture (`width`,
/// `deinit`); the API (`initAtlasTexture`, `uploadAtlasTexture`) writes it.
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

        /// Serializes `sync` of this texture across surfaces; guards
        /// `current`, `generation` and `uploaded`. Held only by syncers,
        /// never by glyph lookups.
        mutex: std.Io.Mutex = .init,

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
        /// at it. The caller holds the grid lock at least shared, so the
        /// atlas does not change during the upload.
        pub fn sync(
            self: *Self,
            alloc: Allocator,
            io: std.Io,
            api: anytype,
            atlas: *const font.Atlas,
            ref: *Ref,
        ) !void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

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
                // Published only after the upload is submitted, so every
                // frame that relies on it is submitted after it.
                try api.uploadAtlasTexture(node.texture, atlas);
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

/// A texture that counts what the GPU would do. It has no CPU write
/// (`replaceRegion`): every upload goes through `FakeApi`.
const FakeTexture = struct {
    width: usize,
    stats: *Stats,

    /// Atomic: the two textures of a set sync under different mutexes.
    const Stats = struct {
        created: Count = .init(0),
        uploads: Count = .init(0),
        freed: Count = .init(0),

        const Count = std.atomic.Value(usize);
    };

    pub fn deinit(self: FakeTexture) void {
        _ = self.stats.freed.fetchAdd(1, .monotonic);
    }
};

/// A grid as `Set.sync` reads it: the lock and the two atlases.
const FakeGrid = struct {
    lock: std.Io.RwLock = .init,
    atlas_grayscale: font.Atlas,
    atlas_color: font.Atlas,

    fn init(alloc: Allocator) !FakeGrid {
        var grayscale: font.Atlas = try .init(alloc, 16, .grayscale);
        errdefer grayscale.deinit(alloc);
        return .{
            .atlas_grayscale = grayscale,
            .atlas_color = try .init(alloc, 16, .bgra),
        };
    }

    fn deinit(self: *FakeGrid, alloc: Allocator) void {
        self.atlas_grayscale.deinit(alloc);
        self.atlas_color.deinit(alloc);
    }
};

const FakeApi = struct {
    stats: FakeTexture.Stats = .{},

    /// Fails the next upload, as a GPU submission can.
    fail_upload: bool = false,

    /// A grid whose lock another surface's glyph lookup takes shared
    /// while the upload runs; `readers_ran` counts the lookups that got in.
    grid: ?*FakeGrid = null,
    readers_ran: usize = 0,

    pub fn initAtlasTexture(self: *FakeApi, atlas: *const font.Atlas) error{}!FakeTexture {
        _ = self.stats.created.fetchAdd(1, .monotonic);
        return .{ .width = atlas.size, .stats = &self.stats };
    }

    pub fn uploadAtlasTexture(
        self: *FakeApi,
        texture: FakeTexture,
        atlas: *const font.Atlas,
    ) error{UploadFailed}!void {
        std.debug.assert(atlas.size <= texture.width);
        if (self.fail_upload) {
            self.fail_upload = false;
            return error.UploadFailed;
        }
        if (self.grid) |grid| {
            if (grid.lock.tryLockShared(testing.io)) {
                grid.lock.unlockShared(testing.io);
                self.readers_ran += 1;
            }
        }
        _ = self.stats.uploads.fetchAdd(1, .monotonic);
    }
};

const FakeShared = AtlasTexture(FakeTexture);
const FakeSet = Set(FakeTexture);

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

    try shared.sync(alloc, testing.io, &api, &atlas, &a);
    try testing.expect(b.stale(&atlas));
    try shared.sync(alloc, testing.io, &api, &atlas, &b);
    try testing.expectEqual(a.node, b.node);
    try testing.expectEqual(@as(usize, 1), api.stats.created.load(.monotonic));
    try testing.expectEqual(@as(usize, 1), api.stats.uploads.load(.monotonic));

    // A new glyph: the first surface to draw uploads it, the second finds
    // it already on the GPU.
    try addGlyph(alloc, &atlas);
    try testing.expect(a.stale(&atlas));
    try testing.expect(b.stale(&atlas));
    try shared.sync(alloc, testing.io, &api, &atlas, &a);
    try shared.sync(alloc, testing.io, &api, &atlas, &b);
    try testing.expectEqual(@as(usize, 2), api.stats.uploads.load(.monotonic));
    try testing.expect(!a.stale(&atlas));
    try testing.expect(!b.stale(&atlas));

    a.release();
    b.release();
    try testing.expectEqual(@as(usize, 0), api.stats.freed.load(.monotonic));
    shared.deinit();
    try testing.expectEqual(@as(usize, 1), api.stats.freed.load(.monotonic));
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

    try shared.sync(alloc, testing.io, &api, &atlas, &a);
    try shared.sync(alloc, testing.io, &api, &atlas, &b);
    try testing.expectEqual(@as(u64, 1), a.generation());

    try atlas.grow(alloc, 32);
    try testing.expect(a.stale(&atlas));
    try testing.expect(b.stale(&atlas));

    // The first user makes the larger texture; the old one stays alive for
    // the second, which may have frames sampling it.
    try shared.sync(alloc, testing.io, &api, &atlas, &a);
    try testing.expectEqual(@as(u64, 2), a.generation());
    try testing.expectEqual(@as(u64, 1), b.generation());
    try testing.expectEqual(@as(usize, 2), api.stats.created.load(.monotonic));
    try testing.expectEqual(@as(usize, 0), api.stats.freed.load(.monotonic));

    // The second user moves to it on its next sync, without an upload, and
    // the old texture goes with the last reference.
    try shared.sync(alloc, testing.io, &api, &atlas, &b);
    try testing.expectEqual(@as(u64, 2), b.generation());
    try testing.expectEqual(a.node, b.node);
    try testing.expectEqual(@as(usize, 2), api.stats.uploads.load(.monotonic));
    try testing.expectEqual(@as(usize, 1), api.stats.freed.load(.monotonic));
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

    try shared.sync(alloc, testing.io, &api, &atlas, &a);
    try testing.expect(!a.stale(&atlas));
    a.release();
    try testing.expect(a.stale(&atlas));
    try shared.sync(alloc, testing.io, &api, &atlas, &a);
    try testing.expectEqual(@as(usize, 1), api.stats.created.load(.monotonic));
    try testing.expectEqual(@as(usize, 1), api.stats.uploads.load(.monotonic));
}

test "a failed upload is not published: the next sync uploads again" {
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

    try shared.sync(alloc, testing.io, &api, &atlas, &a);
    try addGlyph(alloc, &atlas);

    // No other surface may take the texture as holding the new glyph
    // before the upload was submitted.
    api.fail_upload = true;
    try testing.expectError(error.UploadFailed, shared.sync(alloc, testing.io, &api, &atlas, &a));
    try testing.expect(a.stale(&atlas));
    try shared.sync(alloc, testing.io, &api, &atlas, &b);
    try testing.expectEqual(@as(usize, 2), api.stats.uploads.load(.monotonic));
    try testing.expect(!b.stale(&atlas));
    try shared.sync(alloc, testing.io, &api, &atlas, &a);
    try testing.expectEqual(@as(usize, 2), api.stats.uploads.load(.monotonic));
}

test "glyph lookups on other surfaces run during an upload" {
    const alloc = testing.allocator;
    var grid: FakeGrid = try .init(alloc);
    defer grid.deinit(alloc);
    var api: FakeApi = .{ .grid = &grid };

    var set: FakeSet = .{};
    defer set.deinit();
    var grayscale: FakeSet.Shared.Ref = .{};
    defer grayscale.release();
    var color: FakeSet.Shared.Ref = .{};
    defer color.release();

    try set.sync(alloc, testing.io, &api, &grid, &grayscale, &color);
    try testing.expectEqual(@as(usize, 2), api.stats.uploads.load(.monotonic));
    try testing.expectEqual(@as(usize, 2), api.readers_ran);
    try testing.expect(!grayscale.stale(&grid.atlas_grayscale));
    try testing.expect(!color.stale(&grid.atlas_color));
}

test "surfaces syncing at once upload a change once" {
    const alloc = testing.allocator;
    var grid: FakeGrid = try .init(alloc);
    defer grid.deinit(alloc);
    var api: FakeApi = .{};
    var set: FakeSet = .{};
    defer set.deinit();

    const surfaces = 8;
    const Surface = struct {
        grayscale: FakeSet.Shared.Ref = .{},
        color: FakeSet.Shared.Ref = .{},
        result: anyerror!void = {},

        fn run(self: *@This(), s: *FakeSet, a: *FakeApi, g: *FakeGrid) void {
            self.result = s.sync(testing.allocator, testing.io, a, g, &self.grayscale, &self.color);
        }
    };
    var all: [surfaces]Surface = @splat(.{});
    defer for (&all) |*surface| {
        surface.grayscale.release();
        surface.color.release();
    };

    var threads: [surfaces]std.Thread = undefined;
    for (&threads, &all) |*thread, *surface| {
        thread.* = try std.Thread.spawn(.{}, Surface.run, .{ surface, &set, &api, &grid });
    }
    for (threads) |thread| thread.join();

    for (all) |surface| {
        try surface.result;
        try testing.expectEqual(all[0].grayscale.node, surface.grayscale.node);
        try testing.expectEqual(all[0].color.node, surface.color.node);
    }
    try testing.expectEqual(@as(usize, 2), api.stats.created.load(.monotonic));
    try testing.expectEqual(@as(usize, 2), api.stats.uploads.load(.monotonic));
}
