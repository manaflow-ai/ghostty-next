//! Whether a surface keeps its GPU resources
//! (`ghostty_surface_set_gpu_resident`).
//!
//! The embedder asks on the main thread; the renderer thread applies the
//! latest request when it drains its mailbox. This is Chromium's hidden-tab
//! rule: a hidden compositor drops its tiles and frame resources and keeps
//! the content that rebuilds them (cc/trees/layer_tree_host_impl.cc
//! `SetVisible`, `ReleaseTreeResources`; on the Mac,
//! content/browser/renderer_host/browser_compositor_view_mac.mm detaches the
//! compositor and its IOSurfaces from a hidden view).
const Residency = @This();

const std = @import("std");

/// The embedder's request and its epoch in one value, so one load reads a
/// consistent pair. Bumped by each change of the request; since the request
/// flips with each change, an even value is resident and an odd one
/// released. A release and a restore that reach the renderer thread as one
/// coalesced message still change it, so the renderer redraws (the main
/// thread cleared the layer in between). Written on the main thread only;
/// read on any thread (the renderer thread, and the main thread's display
/// pass).
state: std.atomic.Value(u32) = .init(0),

/// Whether `state` asks for the GPU resources (even) or not (odd).
fn residentIn(state: u32) bool {
    return state & 1 == 0;
}

/// Main thread. Records the request; false when it is already the current
/// one, so repeated calls do nothing.
pub fn request(self: *Residency, resident: bool) bool {
    if (residentIn(self.state.load(.acquire)) == resident) return false;
    // The main thread is the only writer: the add flips the request.
    _ = self.state.fetchAdd(1, .acq_rel);
    return true;
}

/// The latest request. Any thread.
pub fn isResident(self: *const Residency) bool {
    return residentIn(self.state.load(.acquire));
}

/// What the renderer thread has applied.
pub const Applied = struct {
    epoch: u32 = 0,
    resident: bool = true,
    /// A release found frames in flight and waits for them (retried by a
    /// timer until it succeeds or a restore cancels it).
    release_pending: bool = false,
    /// Retries of the pending release so far (the retry delay backs off).
    release_retries: u8 = 0,

    pub const Step = enum { none, release, restore };

    /// The step that brings the renderer to the latest request in
    /// `residency`. Renderer thread.
    pub fn next(self: *Applied, residency: *const Residency) Step {
        // One load: the request and the epoch it belongs to.
        const state = residency.state.load(.acquire);
        if (state == self.epoch) return .none;
        self.epoch = state;
        self.resident = residentIn(state);
        self.release_pending = false;
        self.release_retries = 0;
        // Both steps run even when the renderer is already in that state:
        // a restore must redraw what the main thread cleared, and a release
        // must free what a main-thread draw rebuilt in between.
        return if (self.resident) .restore else .release;
    }
};

test "residency: a request is idempotent and bumps the epoch once per change" {
    const testing = std.testing;
    var r: Residency = .{};
    try testing.expect(r.isResident());
    try testing.expect(!r.request(true));
    try testing.expectEqual(@as(u32, 0), r.state.load(.acquire));

    try testing.expect(r.request(false));
    try testing.expect(!r.request(false));
    try testing.expect(!r.isResident());
    try testing.expectEqual(@as(u32, 1), r.state.load(.acquire));

    try testing.expect(r.request(true));
    try testing.expectEqual(@as(u32, 2), r.state.load(.acquire));
}

test "residency: the renderer applies each change once, in its latest state" {
    const testing = std.testing;
    var r: Residency = .{};
    var applied: Applied = .{};
    try testing.expectEqual(Applied.Step.none, applied.next(&r));

    _ = r.request(false);
    try testing.expectEqual(Applied.Step.release, applied.next(&r));
    try testing.expect(!applied.resident);
    // The same request again (a repeated message) does nothing.
    try testing.expectEqual(Applied.Step.none, applied.next(&r));

    _ = r.request(true);
    try testing.expectEqual(Applied.Step.restore, applied.next(&r));
    try testing.expect(applied.resident);
}

test "residency: a release and restore coalesced into one message still restores" {
    const testing = std.testing;
    var r: Residency = .{};
    var applied: Applied = .{};
    _ = r.request(false);
    _ = r.request(true);
    try testing.expectEqual(Applied.Step.restore, applied.next(&r));

    // Restore then release, both before the renderer looked: it releases.
    _ = r.request(false);
    _ = r.request(true);
    _ = r.request(false);
    try testing.expectEqual(Applied.Step.release, applied.next(&r));
}

test "residency: a restore cancels a pending release" {
    const testing = std.testing;
    var r: Residency = .{};
    var applied: Applied = .{};
    _ = r.request(false);
    try testing.expectEqual(Applied.Step.release, applied.next(&r));
    applied.release_pending = true;
    _ = r.request(true);
    try testing.expectEqual(Applied.Step.restore, applied.next(&r));
    try testing.expect(!applied.release_pending);
}

test "residency: the applied request always matches the epoch it was read with" {
    const testing = std.testing;
    var r: Residency = .{};
    var applied: Applied = .{};
    // Any sequence of requests and renderer passes: the applied state is the
    // one its epoch encodes, never a newer request under an older epoch.
    const requests = [_]bool{ false, true, false, false, true, true, false };
    for (requests, 0..) |resident, i| {
        _ = r.request(resident);
        if (i % 2 == 0) continue;
        if (applied.next(&r) != .none) {
            try testing.expectEqual(residentIn(applied.epoch), applied.resident);
            try testing.expectEqual(r.isResident(), applied.resident);
        }
    }
    // The epoch wraps without changing what it encodes.
    r.state.store(std.math.maxInt(u32), .release);
    try testing.expect(!r.isResident());
    try testing.expect(r.request(true));
    try testing.expectEqual(@as(u32, 0), r.state.load(.acquire));
    try testing.expect(r.isResident());
}
