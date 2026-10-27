//! Who paces a renderer's frames to its display.
//!
//! Standalone, each renderer owns a display link (a CVDisplayLink on macOS, a
//! CADisplayLink on iOS) that ticks its thread's `draw_now` while it has a
//! frame or an animation to show. With external vsync
//! (`ghostty_surface_config_s.vsync_external`) the renderer makes no link: it
//! tells the embedder when it wants ticks, and the embedder's one clock per
//! display delivers them (`ghostty_surface_vsync`). This is Chromium's shape:
//! one `DisplayLinkMac` per display (ui/display/mac/display_link_mac.h) fans
//! its VSync out to every frame sink that asked for BeginFrames
//! (components/viz/service/frame_sinks/external_begin_frame_source_mac.h).
const std = @import("std");

const log = std.log.scoped(.renderer_vsync);

/// ghostty_surface_vsync_wanted_cb: userdata, then whether the surface wants
/// ticks.
pub const WantedCallback = *const fn (?*anyopaque, bool) callconv(.c) void;

/// The embedder paces this renderer. Owned by the renderer thread.
pub const External = struct {
    wanted_cb: WantedCallback,
    userdata: ?*anyopaque,

    /// What the embedder was last told.
    wanted: bool = false,

    /// The pacing a surface is configured with
    /// (`ghostty_surface_config_s` `vsync_external`, `vsync_wanted_cb`,
    /// `vsync_userdata`): null without the flag; the flag needs the
    /// callback.
    pub fn fromConfig(
        enabled: bool,
        wanted_cb: ?WantedCallback,
        userdata: ?*anyopaque,
    ) error{MissingVsyncWantedCallback}!?External {
        if (!enabled) return null;
        return .{
            .wanted_cb = wanted_cb orelse return error.MissingVsyncWantedCallback,
            .userdata = userdata,
        };
    }

    /// Tells the embedder on a change only, so calls alternate.
    fn want(self: *External, on: bool) void {
        if (self.wanted == on) return;
        self.wanted = on;
        self.wanted_cb(self.userdata, on);
    }
};

/// The vsync state of one renderer. `Link` is the platform's display link
/// pointer type (void where there is none): it has `start`, `stop`,
/// `isRunning` and `release`, and on macOS `setCurrentCGDisplay`.
pub fn Pacer(comptime Link: type) type {
    return struct {
        const Self = @This();

        /// The renderer's own link; never made while `external` is set.
        link: ?Link = null,

        /// Set when the embedder paces the renderer.
        external: ?External = null,

        /// Display links made or tried (`factory.create()` calls). Stays 0
        /// with `external` set.
        link_creates: u32 = 0,

        /// Whether ticks are coming: the renderer then draws only on a
        /// tick or when it must draw now (renderer.Thread `drawFrame`).
        pub fn running(self: *const Self) bool {
            if (self.external) |e| return e.wanted;
            if (comptime Link == void) return false;
            const link = self.link orelse return false;
            return link.isRunning();
        }

        /// Matches the pacing to the renderer: ticks while `should_run`.
        /// `enabled` is the `window-vsync` config. `factory.create()`
        /// makes the link (null: none now; a later sync tries again) and
        /// is called only without external vsync.
        ///
        /// Must be called on the renderer thread.
        pub fn sync(
            self: *Self,
            enabled: bool,
            should_run: bool,
            display_id: ?u32,
            factory: anytype,
        ) void {
            if (self.external) |*e| {
                e.want(enabled and should_run);
                return;
            }

            if (comptime Link == void) return;

            const link = self.link orelse link: {
                if (!enabled) return;
                self.link_creates += 1;
                const created = factory.create() orelse return;
                self.link = created;
                break :link created;
            };

            if (comptime @hasDecl(std.meta.Child(Link), "setCurrentCGDisplay")) {
                if (display_id) |id| {
                    log.info("updating display link display id={}", .{id});
                    link.setCurrentCGDisplay(id) catch |err| {
                        log.warn("error setting display link display id err={}", .{err});
                    };
                }
            }

            if (should_run) {
                if (!link.isRunning()) link.start() catch {};
            } else {
                link.stop() catch {};
            }
        }

        /// The renderer thread is leaving: no more ticks to its
        /// `draw_now`. The link is kept (see `releaseLink`).
        pub fn stop(self: *Self) void {
            if (self.external) |*e| {
                e.want(false);
                return;
            }
            if (comptime Link == void) return;
            const link = self.link orelse return;
            link.stop() catch {};
        }

        /// Stops and frees the renderer's own link, if it has one.
        pub fn releaseLink(self: *Self) void {
            if (comptime Link == void) return;
            const link = self.link orelse return;
            link.stop() catch {};
            link.release();
            self.link = null;
        }
    };
}

/// A display link that counts what is done to it.
const TestLink = struct {
    running: bool = false,
    starts: u32 = 0,
    stops: u32 = 0,
    releases: u32 = 0,
    display_id: ?u32 = null,

    fn start(self: *TestLink) !void {
        self.running = true;
        self.starts += 1;
    }

    fn stop(self: *TestLink) !void {
        self.running = false;
        self.stops += 1;
    }

    fn isRunning(self: *TestLink) bool {
        return self.running;
    }

    fn release(self: *TestLink) void {
        self.releases += 1;
    }

    fn setCurrentCGDisplay(self: *TestLink, id: u32) !void {
        self.display_id = id;
    }
};

/// Stands in for `createWithActiveCGDisplays`: counts its calls.
const TestFactory = struct {
    link: *TestLink,
    creates: *u32,
    available: bool = true,

    fn create(self: TestFactory) ?*TestLink {
        self.creates.* += 1;
        if (!self.available) return null;
        return self.link;
    }
};

/// The wanted calls an embedder received.
const TestEmbedder = struct {
    calls: [8]bool = undefined,
    len: usize = 0,

    fn wanted(ud: ?*anyopaque, on: bool) callconv(.c) void {
        const self: *TestEmbedder = @ptrCast(@alignCast(ud.?));
        self.calls[self.len] = on;
        self.len += 1;
    }

    fn received(self: *const TestEmbedder) []const bool {
        return self.calls[0..self.len];
    }
};

test "vsync external: no display link is made, the embedder is asked on each edge" {
    const testing = std.testing;
    var embedder: TestEmbedder = .{};
    var link: TestLink = .{};
    var creates: u32 = 0;
    const factory: TestFactory = .{ .link = &link, .creates = &creates };

    var pacer: Pacer(*TestLink) = .{ .external = .{
        .wanted_cb = &TestEmbedder.wanted,
        .userdata = &embedder,
    } };

    // Every state a renderer syncs from: dirty or idle, vsync on or off,
    // with and without a display id.
    for ([_]bool{ true, false }) |enabled| {
        for ([_]bool{ true, false, true, true, false, false }) |should_run| {
            pacer.sync(enabled, should_run, 7, factory);
            try testing.expectEqual(enabled and should_run, pacer.running());
        }
    }
    pacer.sync(true, true, null, factory);
    pacer.stop();
    pacer.releaseLink();

    try testing.expectEqual(@as(u32, 0), creates);
    try testing.expectEqual(@as(u32, 0), pacer.link_creates);
    try testing.expectEqual(@as(u32, 0), link.starts + link.stops + link.releases);
    try testing.expectEqual(@as(?u32, null), link.display_id);
    try testing.expectEqualSlices(
        bool,
        &.{ true, false, true, false, true, false },
        embedder.received(),
    );
    try testing.expect(!pacer.running());
}

test "vsync external: stop says false only after true" {
    const testing = std.testing;
    var embedder: TestEmbedder = .{};
    var link: TestLink = .{};
    var creates: u32 = 0;
    const factory: TestFactory = .{ .link = &link, .creates = &creates };

    var pacer: Pacer(*TestLink) = .{ .external = .{
        .wanted_cb = &TestEmbedder.wanted,
        .userdata = &embedder,
    } };

    // Hidden or idle the whole time: the embedder is never asked.
    pacer.sync(true, false, null, factory);
    pacer.stop();
    try testing.expectEqual(@as(usize, 0), embedder.len);
    try testing.expectEqual(@as(u32, 0), creates);
}

test "vsync standalone: one link, made once, run while dirty" {
    const testing = std.testing;
    var link: TestLink = .{};
    var creates: u32 = 0;
    const factory: TestFactory = .{ .link = &link, .creates = &creates };

    var pacer: Pacer(*TestLink) = .{};
    try testing.expect(!pacer.running());

    pacer.sync(true, true, 3, factory);
    try testing.expectEqual(@as(u32, 1), creates);
    try testing.expectEqual(@as(u32, 1), pacer.link_creates);
    try testing.expectEqual(@as(?u32, 3), link.display_id);
    try testing.expect(pacer.running());

    // Already running: not started again.
    pacer.sync(true, true, null, factory);
    try testing.expectEqual(@as(u32, 1), link.starts);

    pacer.sync(true, false, 5, factory);
    try testing.expect(!pacer.running());
    try testing.expectEqual(@as(?u32, 5), link.display_id);

    // window-vsync off later keeps the link it has (as before).
    pacer.sync(false, true, null, factory);
    try testing.expect(pacer.running());
    try testing.expectEqual(@as(u32, 1), creates);

    pacer.stop();
    try testing.expect(!pacer.running());
    pacer.releaseLink();
    try testing.expectEqual(@as(u32, 1), link.releases);
    try testing.expect(pacer.link == null);
}

test "vsync standalone: no link with window-vsync off, retried when none could be made" {
    const testing = std.testing;
    var link: TestLink = .{};
    var creates: u32 = 0;

    var pacer: Pacer(*TestLink) = .{};
    pacer.sync(false, true, null, TestFactory{ .link = &link, .creates = &creates });
    try testing.expectEqual(@as(u32, 0), creates);
    try testing.expect(!pacer.running());

    // No active display (a locked session): no link, the next sync retries.
    pacer.sync(true, true, null, TestFactory{ .link = &link, .creates = &creates, .available = false });
    try testing.expectEqual(@as(u32, 1), creates);
    try testing.expect(pacer.link == null);
    try testing.expect(!pacer.running());

    pacer.sync(true, true, null, TestFactory{ .link = &link, .creates = &creates });
    try testing.expectEqual(@as(u32, 2), creates);
    try testing.expect(pacer.running());
}

test "vsync: no link type, no ticks unless external" {
    const testing = std.testing;
    var embedder: TestEmbedder = .{};
    const NoFactory = struct {
        fn create(_: @This()) ?void {
            unreachable;
        }
    };

    var standalone: Pacer(void) = .{};
    standalone.sync(true, true, null, NoFactory{});
    try testing.expect(!standalone.running());

    var external: Pacer(void) = .{ .external = .{
        .wanted_cb = &TestEmbedder.wanted,
        .userdata = &embedder,
    } };
    external.sync(true, true, null, NoFactory{});
    try testing.expect(external.running());
    external.stop();
    try testing.expectEqualSlices(bool, &.{ true, false }, embedder.received());
}

test "vsync external: the flag needs the wanted callback" {
    const testing = std.testing;
    var embedder: TestEmbedder = .{};

    try testing.expectEqual(@as(?External, null), try External.fromConfig(false, null, null));
    try testing.expectEqual(
        @as(?External, null),
        try External.fromConfig(false, &TestEmbedder.wanted, &embedder),
    );
    try testing.expectError(
        error.MissingVsyncWantedCallback,
        External.fromConfig(true, null, &embedder),
    );

    const external = (try External.fromConfig(true, &TestEmbedder.wanted, &embedder)).?;
    try testing.expect(external.wanted_cb == &TestEmbedder.wanted);
    try testing.expect(external.userdata == @as(?*anyopaque, &embedder));
    try testing.expect(!external.wanted);
}
