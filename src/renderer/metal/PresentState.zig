//! The state a surface's off-main present (DrawablePresenter) shares between
//! the renderer thread, the GPU completion thread and the main thread. Only
//! atomics: no thread waits for another here.
//!
//! The renderer writes frames only into drawables of its `CAMetalLayer`
//! (the overlay). The main thread writes only layers of the view's tree: the
//! overlay's `hidden` and `drawableSize`, and the root layer's `contents`
//! for a frame it presents itself (a synchronous draw or the resize
//! pre-commit). So two writers decide what the surface shows, and both go
//! through one monotonic frame sequence:
//!
//!   * Every frame gets its id from `begin` under the draw lock, so ids follow
//!     draw order whichever thread drew.
//!   * A writer shows a frame only after `commit` of its id succeeded, a
//!     compare-and-swap that refuses an id older than the newest committed
//!     one. The renderer commits when it encodes the drawable present; main
//!     commits in `cover`, before it hides the overlay behind its frame.
//!   * `cover` starts a new hide generation before its commit. A renderer frame
//!     committed after main's sees that generation when it completes and asks
//!     main to show the overlay again (`presented` returns the generation; the
//!     renderer posts it to the app mailbox). A renderer frame committed before
//!     main's makes main's commit fail, and main changes nothing.
//!   * Main shows the overlay again (`takeReveal`) only when it holds a frame
//!     newer than the one main covered it with.
//!
//! So neither writer shows a frame older than one the other already showed.
//! Chromium keeps the same rule with one producer for each surface and frames
//! activated in order (components/viz/service/surfaces/surface.h); the main
//! thread here never posts or waits for the renderer (cc's ProxyMain/ProxyImpl
//! split, cc/trees/proxy_main.h).
const PresentState = @This();

const std = @import("std");

/// The overlay drawables' pixel size, `pack`ed, as the main thread last set
/// `drawableSize`. 0: no size yet, nothing is presented off main. Main
/// writes, the renderer reads.
drawable_size: std.atomic.Value(u64) = .init(0),

/// False while the embedder hides the presentation
/// (`ghostty_surface_set_presentation`): the renderer encodes no present
/// and the main thread shows nothing. Main writes.
presenting: std.atomic.Value(bool) = .init(true),

/// Bumped by each main-thread hide of the overlay (a main present, a
/// hidden or purged presentation). The overlay starts hidden in generation 1.
/// Main writes.
hide_generation: std.atomic.Value(u64) = .init(1),

/// The hide generation the main thread last showed the overlay in. Main writes.
shown_generation: std.atomic.Value(u64) = .init(0),

/// The hide generation the renderer last asked main to show the overlay in.
/// GPU completion thread writes.
posted_generation: std.atomic.Value(u64) = .init(0),

/// The id of the last frame begun (monotonic, from 1). Draw lock.
sequence: std.atomic.Value(u64) = .init(0),

/// The id of the newest frame either writer committed to show (`commit`).
committed: std.atomic.Value(u64) = .init(0),

/// The id of the frame main last showed in place of the overlay (or, for a
/// hidden presentation, the newest committed then): the overlay shows again
/// only with a newer frame. Main writes.
covered: std.atomic.Value(u64) = .init(0),

/// The id of the newest frame the overlay presented. GPU completion thread
/// writes.
overlay_sequence: std.atomic.Value(u64) = .init(0),

/// The pixel size, `pack`ed, of the newest frame presented off main. GPU
/// completion thread writes, main reads.
shown_size: std.atomic.Value(u64) = .init(0),

/// What the renderer read when it encoded a frame.
pub const Ticket = extern struct {
    /// The frame id (`begin`).
    sequence: u64 = 0,
    /// The frame's copy into a drawable and its present are encoded.
    encoded: bool = false,
};

pub fn pack(width: usize, height: usize) u64 {
    return (@as(u64, @intCast(width)) << 32) | @as(u64, @intCast(height));
}

pub fn packedWidth(size: u64) usize {
    return @intCast(size >> 32);
}

pub fn packedHeight(size: u64) usize {
    return @intCast(size & 0xffff_ffff);
}

// ---------------------------------------------------------------- both writers

/// Under the draw lock, for each frame either thread draws: its id.
pub fn begin(self: *PresentState) Ticket {
    return .{ .sequence = self.sequence.fetchAdd(1, .acq_rel) + 1 };
}

/// Either writer, before it shows frame `id`: true unless a newer frame is
/// committed. The same id again succeeds (main covering the overlay with the
/// frame the overlay already has).
pub fn commit(self: *PresentState, id: u64) bool {
    var current = self.committed.load(.seq_cst);
    while (current < id) {
        current = self.committed.cmpxchgWeak(current, id, .seq_cst, .seq_cst) orelse return true;
    }
    return current == id;
}

// ---------------------------------------------------------------- renderer

/// Renderer thread: whether a frame of `width` x `height` may be copied into
/// a drawable of `drawable_width` x `drawable_height`. Both must equal the
/// size main last set: a frame drawn for an older size, or a drawable taken
/// before main changed the size, is dropped (the layer keeps its last frame
/// from the top-left corner until a frame of the new size comes).
pub fn accepts(
    self: *const PresentState,
    width: usize,
    height: usize,
    drawable_width: usize,
    drawable_height: usize,
) bool {
    if (!self.presenting.load(.acquire)) return false;
    const want = self.drawable_size.load(.acquire);
    return want != 0 and
        want == pack(width, height) and
        want == pack(drawable_width, drawable_height);
}

/// GPU completion thread: the frame of `ticket` (`size`, packed), which the
/// renderer committed, was presented into a drawable. Returns the hide
/// generation to ask main to show the overlay in (one request for each), or
/// null when the overlay shows already or main's frame is newer. Call
/// `revealPostFailed` if the request could not be queued.
pub fn presented(self: *PresentState, ticket: Ticket, size: u64) ?u64 {
    if (self.overlay_sequence.fetchMax(ticket.sequence, .seq_cst) < ticket.sequence) {
        self.shown_size.store(size, .release);
    }
    const generation = self.hide_generation.load(.seq_cst);
    if (self.shown_generation.load(.seq_cst) >= generation) return null;
    if (ticket.sequence <= self.covered.load(.seq_cst)) return null;
    var posted = self.posted_generation.load(.acquire);
    while (posted < generation) {
        posted = self.posted_generation.cmpxchgWeak(
            posted,
            generation,
            .acq_rel,
            .acquire,
        ) orelse return generation;
    }
    return null;
}

/// The request for `generation` was not queued (the app mailbox is full):
/// the next frame of that generation asks again.
pub fn revealPostFailed(self: *PresentState, generation: u64) void {
    _ = self.posted_generation.cmpxchgStrong(generation, generation - 1, .acq_rel, .acquire);
}

// ---------------------------------------------------------------- main thread

/// Main thread, for a frame `id` it presents itself: true when main shows it
/// as the root's contents and hides the overlay in this transaction; false
/// when a newer frame is committed (the renderer's, which shows when it
/// completes), and main changes no layer.
pub fn cover(self: *PresentState, id: u64) bool {
    const shown = self.overlayShown();
    // Before the commit: a renderer frame committed after it sees the overlay
    // hidden when it completes, and asks for the reveal.
    const generation = self.hide_generation.fetchAdd(1, .seq_cst) + 1;
    if (!self.commit(id)) {
        if (shown) self.shown_generation.store(generation, .seq_cst);
        return false;
    }
    self.covered.store(id, .seq_cst);
    return true;
}

/// Main thread: the overlay is hidden in this transaction, and shows again
/// only with a frame newer than `through` (the frame the root shows instead,
/// or the newest committed one for a hidden presentation).
pub fn hide(self: *PresentState, through: u64) void {
    self.covered.store(through, .seq_cst);
    _ = self.hide_generation.fetchAdd(1, .seq_cst);
}

/// Main thread, at the renderer's request: true when the overlay may show
/// now, because it presented a frame newer than the root's and the
/// presentation is not hidden. Records the reveal.
pub fn takeReveal(self: *PresentState) bool {
    if (!self.presenting.load(.acquire)) return false;
    const generation = self.hide_generation.load(.seq_cst);
    if (self.shown_generation.load(.seq_cst) >= generation) return false;
    if (self.overlay_sequence.load(.seq_cst) <= self.covered.load(.seq_cst)) return false;
    self.shown_generation.store(generation, .seq_cst);
    return true;
}

/// Main thread: the overlay shows the renderer's frames (not hidden since
/// the last reveal).
pub fn overlayShown(self: *const PresentState) bool {
    return self.shown_generation.load(.seq_cst) == self.hide_generation.load(.seq_cst);
}

test "a frame of the drawable size is accepted; any other size is dropped" {
    var s: PresentState = .{};
    try std.testing.expect(!s.accepts(800, 600, 800, 600)); // no size set yet
    s.drawable_size.store(pack(800, 600), .release);
    try std.testing.expect(s.accepts(800, 600, 800, 600));
    // A frame drawn for the size before a resize.
    try std.testing.expect(!s.accepts(640, 600, 800, 600));
    // A drawable taken before main set the new size.
    s.drawable_size.store(pack(1024, 600), .release);
    try std.testing.expect(!s.accepts(1024, 600, 800, 600));
    try std.testing.expect(s.accepts(1024, 600, 1024, 600));
    // A hidden presentation takes no frame.
    s.presenting.store(false, .release);
    try std.testing.expect(!s.accepts(1024, 600, 1024, 600));
}

test "frame ids are monotonic and a commit refuses an older id" {
    var s: PresentState = .{};
    const a = s.begin();
    const b = s.begin();
    try std.testing.expect(a.sequence == 1 and b.sequence == 2);
    try std.testing.expect(s.commit(b.sequence));
    try std.testing.expect(!s.commit(a.sequence));
    // The same frame again (main covering with the overlay's own frame).
    try std.testing.expect(s.commit(b.sequence));
    try std.testing.expectEqual(@as(u64, 2), s.committed.load(.seq_cst));
}

test "one reveal for each hide, only for a frame newer than main's" {
    var s: PresentState = .{};
    s.drawable_size.store(pack(10, 10), .release);

    // The overlay starts hidden; the first frame asks once.
    const first = s.begin();
    try std.testing.expect(s.commit(first.sequence));
    try std.testing.expect(s.presented(first, pack(10, 10)) != null);
    const second = s.begin();
    try std.testing.expect(s.commit(second.sequence));
    try std.testing.expect(s.presented(second, pack(10, 10)) == null);
    try std.testing.expect(s.takeReveal());
    try std.testing.expect(s.overlayShown());
    try std.testing.expect(!s.takeReveal());

    // Main covers the overlay with a frame of its own (a sync draw).
    const main_frame = s.begin();
    try std.testing.expect(s.cover(main_frame.sequence));
    try std.testing.expect(!s.overlayShown());
    // A stale request shows nothing: the overlay holds only older frames.
    try std.testing.expect(!s.takeReveal());
    // The renderer's next frame asks, and shows.
    const next = s.begin();
    try std.testing.expect(s.commit(next.sequence));
    try std.testing.expect(s.presented(next, pack(10, 10)) != null);
    try std.testing.expect(s.takeReveal());
}

test "main's present of a frame older than the renderer's committed one changes nothing" {
    var s: PresentState = .{};
    s.drawable_size.store(pack(10, 10), .release);
    const fresh = s.begin();
    try std.testing.expect(s.commit(fresh.sequence));
    try std.testing.expect(s.presented(fresh, pack(10, 10)) != null);
    try std.testing.expect(s.takeReveal());
    // The renderer encodes a newer frame before main's pre-commit present
    // takes `fresh`.
    const newer = s.begin();
    try std.testing.expect(s.commit(newer.sequence));
    try std.testing.expect(!s.cover(fresh.sequence));
    // The overlay stays shown, so the newer frame shows when it completes.
    try std.testing.expect(s.overlayShown());
    try std.testing.expect(s.presented(newer, pack(10, 10)) == null);
}

test "a renderer frame committed after main's cover asks for the reveal" {
    var s: PresentState = .{};
    s.drawable_size.store(pack(10, 10), .release);
    const fresh = s.begin();
    try std.testing.expect(s.commit(fresh.sequence));
    try std.testing.expect(s.presented(fresh, pack(10, 10)) != null);
    try std.testing.expect(s.takeReveal());
    try std.testing.expect(s.cover(fresh.sequence));
    const newer = s.begin();
    try std.testing.expect(s.commit(newer.sequence));
    try std.testing.expect(s.presented(newer, pack(10, 10)) != null);
    try std.testing.expect(s.takeReveal());
}

test "a request that was not queued is sent with the next frame" {
    var s: PresentState = .{};
    const t = s.begin();
    try std.testing.expect(s.commit(t.sequence));
    const generation = s.presented(t, pack(4, 4)).?;
    s.revealPostFailed(generation);
    const u = s.begin();
    try std.testing.expect(s.commit(u.sequence));
    try std.testing.expect(s.presented(u, pack(4, 4)) != null);
    try std.testing.expect(s.takeReveal());
}

test "a hidden presentation is not revealed, and shows again only with a newer frame" {
    var s: PresentState = .{};
    const t = s.begin();
    try std.testing.expect(s.commit(t.sequence));
    try std.testing.expect(s.presented(t, pack(4, 4)) != null);
    s.presenting.store(false, .release);
    s.hide(s.committed.load(.seq_cst));
    try std.testing.expect(!s.takeReveal());
    s.presenting.store(true, .release);
    // The overlay holds nothing newer than the hide.
    try std.testing.expect(!s.takeReveal());
}

/// A model of what a surface shows, for the interleaving test: the overlay's
/// last presented frame, the root's contents, and whether the overlay is
/// hidden. A frame shows at the step that changes these (a drawable present
/// completing, main's transaction).
const Screen = struct {
    hidden: bool = true,
    overlay: u64 = 0,
    root: u64 = 0,
    newest_shown: u64 = 0,

    fn shown(self: Screen) u64 {
        return if (self.hidden) self.root else self.overlay;
    }

    fn check(self: *Screen) !void {
        const now = self.shown();
        if (now == 0 and self.newest_shown == 0) return;
        try std.testing.expect(now >= self.newest_shown);
        self.newest_shown = now;
    }
};

const Event = enum {
    /// Renderer: begin and commit the next frame, and encode its present.
    encode,
    /// Renderer: the GPU completed the oldest encoded frame.
    complete,
    /// Main: the pre-commit present of the newest completed frame.
    present_fresh,
    /// Main: a synchronous draw presented in its transaction.
    sync_draw,
    /// Main: `ghostty_app_tick` runs one reveal request.
    tick,
};

const Model = struct {
    state: PresentState = .{},
    screen: Screen = .{},
    /// Encoded frames not completed yet (ids; 0 for a frame dropped at encode).
    in_flight: [8]Ticket = undefined,
    in_flight_len: usize = 0,
    fresh: u64 = 0,
    mailbox: [8]u64 = undefined,
    mailbox_len: usize = 0,

    fn run(self: *Model, event: Event, drop: bool) !void {
        switch (event) {
            .encode => {
                var ticket = self.state.begin();
                ticket.encoded = !drop and self.state.commit(ticket.sequence);
                self.in_flight[self.in_flight_len] = ticket;
                self.in_flight_len += 1;
            },
            .complete => {
                const ticket = self.in_flight[0];
                std.mem.copyForwards(Ticket, self.in_flight[0 .. self.in_flight_len - 1], self.in_flight[1..self.in_flight_len]);
                self.in_flight_len -= 1;
                self.fresh = ticket.sequence;
                if (!ticket.encoded) return;
                self.screen.overlay = ticket.sequence;
                try self.screen.check();
                if (self.state.presented(ticket, pack(4, 4))) |generation| {
                    self.mailbox[self.mailbox_len] = generation;
                    self.mailbox_len += 1;
                }
            },
            .present_fresh => {
                if (self.fresh == 0) return;
                const id = self.fresh;
                self.fresh = 0;
                self.mainPresent(id);
                try self.screen.check();
            },
            .sync_draw => {
                self.mainPresent(self.state.begin().sequence);
                try self.screen.check();
            },
            .tick => {
                if (self.mailbox_len == 0) return;
                self.mailbox_len -= 1;
                if (self.state.takeReveal()) {
                    self.screen.hidden = false;
                    self.screen.root = 0;
                }
                try self.screen.check();
            },
        }
    }

    fn mainPresent(self: *Model, id: u64) void {
        if (!self.state.cover(id)) return;
        self.screen.root = id;
        self.screen.hidden = true;
    }
};

/// Runs every interleaving of the renderer's events (`renderer`, in order)
/// with main's (`main`, in order), then drains the mailbox, and checks that
/// no step shows an older frame than an earlier step did and that the
/// newest committed frame shows at the end.
fn interleave(
    renderer: []const Event,
    main: []const Event,
    drop_mask: u32,
    model: Model,
    encoded: u32,
) !void {
    if (renderer.len == 0 and main.len == 0) {
        var end = model;
        while (end.mailbox_len > 0) try end.run(.tick, false);
        try std.testing.expectEqual(end.state.committed.load(.seq_cst), end.screen.shown());
        return;
    }
    if (renderer.len > 0) {
        var next = model;
        const drop = renderer[0] == .encode and (drop_mask >> @intCast(encoded)) & 1 == 1;
        try next.run(renderer[0], drop);
        try interleave(renderer[1..], main, drop_mask, next, encoded + @intFromBool(renderer[0] == .encode));
    }
    if (main.len > 0) {
        var next = model;
        try next.run(main[0], false);
        try interleave(renderer, main[1..], drop_mask, next, encoded);
    }
}

test "the two writers interleaved never show an older frame after a newer one" {
    var start: Model = .{};
    start.state.drawable_size.store(pack(4, 4), .release);
    // Three renderer frames, the second encoded before the first completes.
    const renderers = [_][]const Event{
        &.{ .encode, .complete, .encode, .complete, .encode, .complete },
        &.{ .encode, .encode, .complete, .complete, .encode, .complete },
        &.{ .encode, .encode, .complete, .encode, .complete, .complete },
    };
    const mains = [_][]const Event{
        &.{ .present_fresh, .tick, .present_fresh, .tick, .tick },
        &.{ .sync_draw, .present_fresh, .tick, .present_fresh, .tick },
        &.{ .present_fresh, .sync_draw, .tick, .tick, .present_fresh },
    };
    for (renderers) |renderer| {
        for (mains) |main| {
            // Every combination of frames dropped at encode (a drawable of another size).
            var drop_mask: u32 = 0;
            while (drop_mask < 8) : (drop_mask += 1) {
                try interleave(renderer, main, drop_mask, start, 0);
            }
        }
    }
}

test "concurrent commits keep the newest id" {
    const Writer = struct {
        fn run(s: *PresentState, failures: *std.atomic.Value(u32)) void {
            for (0..20_000) |_| {
                const id = s.begin().sequence;
                if (!s.commit(id)) {
                    // Refused only for an id older than the committed one.
                    if (s.committed.load(.seq_cst) <= id) _ = failures.fetchAdd(1, .monotonic);
                }
            }
        }
    };
    var s: PresentState = .{};
    var failures: std.atomic.Value(u32) = .init(0);
    const a = try std.Thread.spawn(.{}, Writer.run, .{ &s, &failures });
    const b = try std.Thread.spawn(.{}, Writer.run, .{ &s, &failures });
    a.join();
    b.join();
    try std.testing.expectEqual(@as(u32, 0), failures.load(.monotonic));
    try std.testing.expectEqual(s.sequence.load(.seq_cst), s.committed.load(.seq_cst));
}
