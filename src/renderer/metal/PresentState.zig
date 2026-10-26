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
//! it only while that generation is current (`takeReveal`). So the overlay
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

/// The pixel size, `pack`ed, of the last frame presented off main. GPU
/// completion thread writes, main reads.
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

/// GPU completion thread: the frame of `ticket` (`size`, packed) was
/// presented into a drawable. True when the renderer must ask main to show
/// the overlay (one request for each hide generation); then call
/// `revealPostFailed` if the request could not be queued.
pub fn presented(self: *PresentState, ticket: Ticket, size: u64) bool {
    self.shown_size.store(size, .release);
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

test "one reveal for each hide, only for a frame encoded after the hide" {
    var s: PresentState = .{};
    s.drawable_size.store(pack(10, 10), .release);

    // The overlay starts hidden; the first frame asks once.
    const first = s.begin();
    try std.testing.expect(s.presented(first, pack(10, 10)));
    try std.testing.expect(!s.presented(s.begin(), pack(10, 10)));
    try std.testing.expect(s.takeReveal());
    try std.testing.expect(s.overlayShown());
    try std.testing.expect(!s.takeReveal());
    // Shown: later frames ask nothing.
    try std.testing.expect(!s.presented(s.begin(), pack(10, 10)));

    // A frame encoded before main's present completes after it: no request,
    // and a stale request does not show the overlay.
    const before = s.begin();
    _ = s.hide();
    try std.testing.expect(!s.overlayShown());
    try std.testing.expect(!s.presented(before, pack(10, 10)));
    try std.testing.expect(!s.takeReveal());
    // The next frame does ask.
    try std.testing.expect(s.presented(s.begin(), pack(10, 10)));
    // Main hid again before the request ran: it shows nothing.
    _ = s.hide();
    try std.testing.expect(!s.takeReveal());
    try std.testing.expect(s.presented(s.begin(), pack(10, 10)));
    try std.testing.expect(s.takeReveal());
}

test "a request that was not queued is sent with the next frame" {
    var s: PresentState = .{};
    const t = s.begin();
    try std.testing.expect(s.presented(t, pack(4, 4)));
    s.revealPostFailed(t.generation);
    try std.testing.expect(s.presented(s.begin(), pack(4, 4)));
    try std.testing.expect(s.takeReveal());
}

test "a hidden presentation is not revealed" {
    var s: PresentState = .{};
    try std.testing.expect(s.presented(s.begin(), pack(4, 4)));
    s.presenting.store(false, .release);
    try std.testing.expect(!s.takeReveal());
}

test "frame ids are monotonic" {
    var s: PresentState = .{};
    const a = s.begin();
    const b = s.begin();
    try std.testing.expect(a.sequence == 1 and b.sequence == 2);
}
