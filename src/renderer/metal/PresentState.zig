//! The state a surface's off-main present (DrawablePresenter) shares between
//! the renderer thread, the GPU completion thread and the main thread. Only
//! atomics: no thread waits for another here.
//!
//! The renderer writes frames only into drawables of its `CAMetalLayer`
//! (the overlay). The main thread writes only layers of the view's tree: the
//! overlay's `hidden` and `drawableSize`, and the root layer's `contents`
//! for a frame it presents itself (a synchronous draw or the resize
//! pre-commit). Such a main present hides the overlay and starts a new hide
//! generation. The first frame the renderer encodes in that generation asks
//! the main thread to show the overlay again (`presented` returns true; the
//! renderer posts the request to the app mailbox), and the main thread does
//! it only while that generation is current (`takeReveal`). The request is
//! made when that frame's drawable is on the overlay (its presented handler),
//! not when its command buffer completed: drawables show in order, so an
//! older one still queued then cannot show after the reveal. So the overlay
//! never comes back with a frame older than the one main presented.
//!
//! Chromium keeps the same rule with one producer for each surface and a
//! frame sequence (components/viz/service/surfaces/surface.h); the main
//! thread here never posts or waits for the renderer (cc's
//! ProxyMain/ProxyImpl split, cc/trees/proxy_main.h).
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
hide_generation: std.atomic.Value(u64) = .init(1),

/// The hide generation the main thread last showed the overlay in. Main writes.
shown_generation: std.atomic.Value(u64) = .init(0),

/// The hide generation the renderer last asked main to show the overlay in.
/// GPU completion thread writes.
posted_generation: std.atomic.Value(u64) = .init(0),

/// The id of the last frame the renderer encoded (monotonic, from 1).
sequence: std.atomic.Value(u64) = .init(0),

/// The pixel size, `pack`ed, of the last frame the overlay showed. The
/// drawables' presented handlers write, main reads.
shown_size: std.atomic.Value(u64) = .init(0),

/// What the renderer read when it encoded a frame.
pub const Ticket = extern struct {
    /// The frame id (`sequence`); 0 for a frame drawn on the main thread.
    sequence: u64 = 0,
    /// The hide generation the frame was encoded in.
    generation: u64 = 0,
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

// ---------------------------------------------------------------- renderer

/// Renderer thread, when it encodes a frame: the frame's id and generation.
pub fn begin(self: *PresentState) Ticket {
    return .{
        .sequence = self.sequence.fetchAdd(1, .acq_rel) + 1,
        .generation = self.hide_generation.load(.acquire),
    };
}

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

/// A drawable's presented handler, for the frame of `ticket` (`size`,
/// packed): Core Animation put the drawable on the overlay (`shown`,
/// `presentedTime` > 0) or replaced it with a newer one at the same refresh.
/// Either way every older drawable is past. True when the renderer must ask
/// main to show the overlay (one request for each hide generation); then
/// call `revealPostFailed` if the request could not be queued.
pub fn presented(self: *PresentState, ticket: Ticket, size: u64, shown: bool) bool {
    if (shown) self.shown_size.store(size, .release);
    // Main hid the overlay again after this frame was encoded: the request
    // comes with a frame of the newer generation.
    if (ticket.generation != self.hide_generation.load(.acquire)) return false;
    if (self.shown_generation.load(.acquire) >= ticket.generation) return false;
    var posted = self.posted_generation.load(.acquire);
    while (posted < ticket.generation) {
        posted = self.posted_generation.cmpxchgWeak(
            posted,
            ticket.generation,
            .acq_rel,
            .acquire,
        ) orelse return true;
    }
    return false;
}

/// The request for `generation` was not queued (the app mailbox is full):
/// the next frame of that generation asks again.
pub fn revealPostFailed(self: *PresentState, generation: u64) void {
    _ = self.posted_generation.cmpxchgStrong(generation, generation - 1, .acq_rel, .acquire);
}

// ---------------------------------------------------------------- main thread

/// Main thread: the overlay is hidden in this transaction (main presented a
/// frame itself, or the presentation is hidden). Returns the new generation.
pub fn hide(self: *PresentState) u64 {
    return self.hide_generation.fetchAdd(1, .acq_rel) + 1;
}

/// Main thread, at the renderer's request: true when the overlay may show
/// now, because the renderer presented a frame encoded after main's last
/// hide and the presentation is not hidden. Records the reveal.
pub fn takeReveal(self: *PresentState) bool {
    if (!self.presenting.load(.acquire)) return false;
    const generation = self.hide_generation.load(.acquire);
    if (self.posted_generation.load(.acquire) != generation) return false;
    if (self.shown_generation.load(.acquire) >= generation) return false;
    self.shown_generation.store(generation, .release);
    return true;
}

/// Main thread: the overlay shows the renderer's frames (not hidden since
/// the last reveal).
pub fn overlayShown(self: *const PresentState) bool {
    return self.shown_generation.load(.acquire) == self.hide_generation.load(.acquire);
}

/// GPU completion thread: whether the frame of `ticket` may become the frame
/// on screen (`Metal.presentedFrame`). Not after a newer main present, a
/// hide or a purge: each of those started a newer generation.
pub fn current(self: *const PresentState, ticket: Ticket) bool {
    return self.presenting.load(.acquire) and
        ticket.generation == self.hide_generation.load(.acquire);
}

/// Whether the overlay may be `opaque`: only when every frame covers it
/// with alpha 1, so not for a translucent background (`background-opacity`
/// below 1, which cmux-next sets to 0 when its window paints a translucent
/// background) nor for a macOS glass background, whose alpha the renderer
/// sets to 0 (`generic.zig` updateFrame).
pub fn opaqueOverlay(background_opacity: f64, glass: bool) bool {
    return background_opacity >= 1 and !glass;
}

/// The pixel size, packed, the renderer draws at: the host size when the
/// embedder set one, else the layer's bounds (points) times its scale, each
/// side clamped to `max`. Any thread.
pub fn targetSize(host: u64, width_pt: f64, height_pt: f64, scale: f64, max: u32) u64 {
    if (host != 0) return host;
    const limit: f64 = @floatFromInt(max);
    const w: u32 = @intFromFloat(std.math.clamp(width_pt * scale, 0, limit));
    const h: u32 = @intFromFloat(std.math.clamp(height_pt * scale, 0, limit));
    return pack(w, h);
}

/// A frame the renderer encoded into a drawable (test helper).
fn testFrame(s: *PresentState) Ticket {
    return s.begin();
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

test "a scale change with the bounds unchanged: the drawables follow and the frame is accepted" {
    var s: PresentState = .{};
    const max: u32 = 16384;
    // 400 x 300 points at scale 1.
    s.drawable_size.store(targetSize(0, 400, 300, 1, max), .release);
    try std.testing.expect(s.accepts(400, 300, 400, 300));
    // The window moves to a 2x display: the bounds stay 400 x 300 points,
    // and the renderer draws at 800 x 600 (`Metal.surfaceSize`).
    const drawn = targetSize(0, 400, 300, 2, max);
    try std.testing.expectEqual(pack(800, 600), drawn);
    // Before main syncs the drawables to the scale, that frame is dropped...
    try std.testing.expect(!s.accepts(800, 600, 800, 600));
    // ...and after (`Metal.syncPresentGeometry`) it is accepted.
    s.drawable_size.store(targetSize(0, 400, 300, 2, max), .release);
    try std.testing.expect(s.accepts(packedWidth(drawn), packedHeight(drawn), 800, 600));
}

test "targetSize: the host size wins, the bounds are clamped" {
    try std.testing.expectEqual(pack(10, 20), targetSize(pack(10, 20), 400, 300, 2, 100));
    try std.testing.expectEqual(pack(100, 100), targetSize(0, 400, 300, 2, 100));
    try std.testing.expectEqual(pack(0, 0), targetSize(0, -4, 0, 2, 100));
}

test "one reveal for each hide, only for a frame encoded after the hide" {
    var s: PresentState = .{};
    s.drawable_size.store(pack(10, 10), .release);

    // The overlay starts hidden; the first frame asks once.
    const first = testFrame(&s);
    try std.testing.expect(s.presented(first, pack(10, 10), true));
    try std.testing.expect(!s.presented(testFrame(&s), pack(10, 10), true));
    try std.testing.expect(s.takeReveal());
    try std.testing.expect(s.overlayShown());
    try std.testing.expect(!s.takeReveal());
    // Shown: later frames ask nothing.
    try std.testing.expect(!s.presented(testFrame(&s), pack(10, 10), true));

    // A frame encoded before main's present is shown after it: no request,
    // and a stale request does not show the overlay.
    const before = testFrame(&s);
    _ = s.hide();
    try std.testing.expect(!s.overlayShown());
    try std.testing.expect(!s.presented(before, pack(10, 10), true));
    try std.testing.expect(!s.takeReveal());
    // The next frame does ask.
    try std.testing.expect(s.presented(testFrame(&s), pack(10, 10), true));
    // Main hid again before the request ran: it shows nothing.
    _ = s.hide();
    try std.testing.expect(!s.takeReveal());
    try std.testing.expect(s.presented(testFrame(&s), pack(10, 10), true));
    try std.testing.expect(s.takeReveal());
}

test "completed but not yet shown: no reveal until the drawable is on the overlay" {
    var s: PresentState = .{};
    s.drawable_size.store(pack(10, 10), .release);
    // Old-size drawables from before main's present are still queued.
    const old_a = testFrame(&s);
    const old_b = testFrame(&s);
    _ = s.hide();
    // The frame encoded after main's present: its command buffer completed,
    // but its presented handler has not run, so nothing asks main yet.
    const fresh = testFrame(&s);
    try std.testing.expect(!s.takeReveal());
    // The older drawables show first (in order): none of them asks.
    try std.testing.expect(!s.presented(old_a, pack(8, 8), true));
    try std.testing.expect(!s.presented(old_b, pack(8, 8), true));
    try std.testing.expect(!s.takeReveal());
    try std.testing.expectEqual(pack(8, 8), s.shown_size.load(.acquire));
    // The new frame is on the overlay: now main may show it.
    try std.testing.expect(s.presented(fresh, pack(10, 10), true));
    try std.testing.expect(s.takeReveal());
    try std.testing.expectEqual(pack(10, 10), s.shown_size.load(.acquire));
}

test "a drawable replaced before it showed keeps the shown size" {
    var s: PresentState = .{};
    try std.testing.expect(s.presented(testFrame(&s), pack(4, 4), true));
    try std.testing.expect(s.takeReveal());
    // Replaced by a newer drawable at the same refresh: not the shown size.
    try std.testing.expect(!s.presented(testFrame(&s), pack(6, 6), false));
    try std.testing.expectEqual(pack(4, 4), s.shown_size.load(.acquire));
}

test "a request that was not queued is sent with the next frame" {
    var s: PresentState = .{};
    const t = testFrame(&s);
    try std.testing.expect(s.presented(t, pack(4, 4), true));
    s.revealPostFailed(t.generation);
    try std.testing.expect(s.presented(testFrame(&s), pack(4, 4), true));
    try std.testing.expect(s.takeReveal());
}

test "a hidden presentation is not revealed" {
    var s: PresentState = .{};
    try std.testing.expect(s.presented(testFrame(&s), pack(4, 4), true));
    s.presenting.store(false, .release);
    try std.testing.expect(!s.takeReveal());
}

test "a frame encoded before a hide, purge or main present is not the frame on screen" {
    var s: PresentState = .{};
    const t = s.begin();
    try std.testing.expect(s.current(t));
    // A purge (or a hide) hides the overlay: a new generation, not presenting.
    s.presenting.store(false, .release);
    _ = s.hide();
    try std.testing.expect(!s.current(t));
    // Shown again: a frame from before still is not current.
    _ = s.hide();
    s.presenting.store(true, .release);
    try std.testing.expect(!s.current(t));
    try std.testing.expect(s.current(s.begin()));
}

test "the overlay is opaque only for an opaque background" {
    try std.testing.expect(opaqueOverlay(1, false));
    try std.testing.expect(!opaqueOverlay(0.9, false));
    try std.testing.expect(!opaqueOverlay(0, false));
    try std.testing.expect(!opaqueOverlay(1, true));
}

test "frame ids are monotonic" {
    var s: PresentState = .{};
    const a = s.begin();
    const b = s.begin();
    try std.testing.expect(a.sequence == 1 and b.sequence == 2);
}
