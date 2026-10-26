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

/// The embedder's latest request. Written on the main thread only; read on
/// any thread (the renderer thread, and the main thread's display pass).
requested: std.atomic.Value(bool) = .init(true),

/// Bumped by each change of `requested`. A release and a restore that reach
/// the renderer thread as one coalesced message still change the epoch, so
/// the renderer redraws (the main thread cleared the layer in between).
epoch: std.atomic.Value(u32) = .init(0),

/// Main thread. Records the request; false when it is already the current
/// one, so repeated calls do nothing.
pub fn request(self: *Residency, resident: bool) bool {
    if (self.requested.load(.acquire) == resident) return false;
    self.requested.store(resident, .release);
    _ = self.epoch.fetchAdd(1, .acq_rel);
    return true;
}

/// The latest request. Any thread.
pub fn isResident(self: *const Residency) bool {
    return self.requested.load(.acquire);
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
        const epoch = residency.epoch.load(.acquire);
        if (epoch == self.epoch) return .none;
        self.epoch = epoch;
        self.resident = residency.isResident();
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
    try testing.expectEqual(@as(u32, 0), r.epoch.load(.acquire));

    try testing.expect(r.request(false));
    try testing.expect(!r.request(false));
    try testing.expect(!r.isResident());
    try testing.expectEqual(@as(u32, 1), r.epoch.load(.acquire));

    try testing.expect(r.request(true));
    try testing.expectEqual(@as(u32, 2), r.epoch.load(.acquire));
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
