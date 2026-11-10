//! A wrapper around a CALayer with a utility method
//! for settings its `contents` to an IOSurface.
const IOSurfaceLayer = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const macos = @import("macos");
const apprt = @import("../../apprt.zig");

const IOSurface = macos.iosurface.IOSurface;

const log = std.log.scoped(.IOSurfaceLayer);

/// We subclass CALayer with a custom display handler, we only need
/// to make the subclass once, and then we can use it as a singleton.
var Subclass: ?objc.Class = null;

/// The underlying CALayer
layer: objc.Object,

pub fn init() !IOSurfaceLayer {
    // The layer returned by `[CALayer layer]` is autoreleased, which means
    // that at the end of the current autorelease pool it will be deallocated
    // if it isn't retained, so we retain it here manually an extra time.
    const layer = (try getSubclass()).msgSend(
        objc.Object,
        objc.sel("layer"),
        .{},
    ).retain();
    errdefer layer.release();

    // The layer gravity is set to top-left so that the contents aren't
    // stretched during resize operations before a new frame has been drawn.
    layer.setProperty("contentsGravity", macos.animation.kCAGravityTopLeft);

    layer.setInstanceVariable("display_cb", .{ .value = null });
    layer.setInstanceVariable("display_ctx", .{ .value = null });
    layer.setInstanceVariable("host_size", .{ .value = null });
    layer.setInstanceVariable("present_seq", .{ .value = null });
    layer.setInstanceVariable("main_pending", .{ .value = null });
    layer.setInstanceVariable("present_cb", .{ .value = null });
    layer.setInstanceVariable("present_ctx", .{ .value = null });
    layer.setInstanceVariable("commit_observer", .{ .value = null });
    layer.setInstanceVariable("pending_scale", .{ .value = null });

    return .{ .layer = layer };
}

pub fn release(self: *IOSurfaceLayer) void {
    // The layer may be retained by the view after we release our reference.
    // Clear the callback first so that a later display pass can't access the
    // renderer that owned this wrapper after it has been freed.
    self.setDisplayCallback(null, null);
    // An observer still waiting for main's commit holds the layer: remove it,
    // so it never fires for a released wrapper and does not keep the layer.
    const CATransaction = objc.getClass("CATransaction").?;
    CATransaction.msgSend(void, objc.sel("lock"), .{});
    const observer = commitObserver(self.layer);
    setCommitObserver(self.layer, null);
    CATransaction.msgSend(void, objc.sel("unlock"), .{});
    if (observer) |o| {
        // Invalidate on main: invalidating releases the layer the observer
        // holds, and a fire may be reading it on main now. A fire before the
        // block sees the cleared ivar and does nothing.
        if (objc.getClass("NSThread").?.msgSend(bool, "isMainThread", .{})) {
            dropCommitObserver(o);
        } else {
            var block = DropObserverBlock.init(.{ .observer = @ptrCast(o) }, &dropObserverCallback);
            macos.dispatch.dispatch_async(
                @ptrCast(macos.dispatch.queue.getMain()),
                @ptrCast(&block),
            );
        }
    }
    self.layer.release();
}

const DropObserverBlock = objc.Block(struct {
    observer: *anyopaque,
}, .{}, void);

fn dropObserverCallback(block: *const DropObserverBlock.Context) callconv(.c) void {
    dropCommitObserver(@ptrCast(block.observer));
}

/// Removes an observer of `clearAfterMainCommit` that has not fired and
/// releases the layer's reference to it. Main thread.
fn dropCommitObserver(observer: macos.c.CFRunLoopObserverRef) void {
    macos.c.CFRunLoopObserverInvalidate(observer);
    macos.c.CFRelease(observer);
}

/// Detach this layer from its host (the embedder's view layer) if its
/// display callback still belongs to `display_cb`/`display_ctx`: clear
/// the callback, the contents, and remove it from its superlayer. Runs
/// synchronously on the main queue, because Core Animation calls the
/// display callback from main thread transactions while the renderer is
/// being destroyed.
pub fn detachFromHostIfDisplayCallbackOwned(
    self: *IOSurfaceLayer,
    display_cb: DisplayCallback,
    display_ctx: ?*anyopaque,
) void {
    var block = DetachFromHostBlock.init(.{
        .layer = self.layer.value,
        .display_cb = @ptrCast(@constCast(display_cb)),
        .display_ctx = display_ctx,
    }, &detachFromHostCallback);

    const NSThread = objc.getClass("NSThread").?;
    if (NSThread.msgSend(bool, "isMainThread", .{})) {
        detachFromHostCallback(&block);
    } else {
        macos.dispatch.dispatch_sync(
            @ptrCast(macos.dispatch.queue.getMain()),
            @ptrCast(&block),
        );
    }
}

/// Installs the embedder's present callback (`ghostty_surface_set_present_callback`), or with null removes it: each
/// frame that becomes the layer's contents is reported on the thread that sets them. Written under the Core
/// Animation lock, which every present holds when it reads the callback. Main thread.
pub fn setPresentCallback(self: *IOSurfaceLayer, cb: ?apprt.PresentCallback, ctx: ?*anyopaque) void {
    const CATransaction = objc.getClass("CATransaction").?;
    CATransaction.msgSend(void, objc.sel("lock"), .{});
    defer CATransaction.msgSend(void, objc.sel("unlock"), .{});
    setPacked(self.layer, "present_cb", if (cb) |f| @intFromPtr(f) else 0);
    setPacked(self.layer, "present_ctx", @intFromPtr(ctx));
}

/// Stores `value`, a pointer value or a number, in an object-typed ivar, shifted left by 3 like `setHostSize`: the
/// ivar then holds an 8-aligned value whatever the alignment of `value` (a C function pointer is 4-aligned on arm64),
/// so safe builds' alignment checks pass. Never retained or released (no ARC layout on this class).
fn setPacked(layer: objc.Object, comptime name: [:0]const u8, value: usize) void {
    layer.setInstanceVariable(name, .{ .value = @ptrFromInt(value << 3) });
}

/// The value `setPacked` stored.
fn getPacked(layer: objc.Object, comptime name: [:0]const u8) usize {
    return @intFromPtr(layer.getInstanceVariable(name).value) >> 3;
}

extern "c" fn mach_absolute_time() u64;

/// One frame that became the layer's contents, for the embedder's present callback (`setPresentCallback`). Read
/// under the Core Animation lock just before the contents change (`presentReportLocked`), called after the lock is
/// released (`call`): the callback never runs under the lock.
const PresentReport = struct {
    cb: apprt.PresentCallback,
    ctx: ?*anyopaque,
    present: apprt.Present,

    /// Reports the frame, stamped now.
    fn call(self: *PresentReport) void {
        self.present.host_time = mach_absolute_time();
        self.cb(self.ctx, &self.present);
    }
};

/// The report of `surface` (present sequence `seq`, 0 for a main-thread draw) becoming the layer's contents, or null
/// without a callback. Call under the Core Animation lock, before the contents change: the reason compares the
/// frame with the one the layer shows now.
fn presentReportLocked(layer: objc.Object, surface: *IOSurface, seq: u64) ?PresentReport {
    const cb_value = getPacked(layer, "present_cb");
    if (cb_value == 0) return null;
    const width = surface.getWidth();
    const height = surface.getHeight();
    const reason: apprt.PresentReason = if (layer.getProperty(?*anyopaque, "contents")) |shown| reason: {
        const shown_surface: *IOSurface = @ptrCast(shown);
        break :reason if (shown_surface.getWidth() == width and shown_surface.getHeight() == height) .content else .resize;
    } else .resize;
    return .{
        .cb = @ptrFromInt(cb_value),
        .ctx = @ptrFromInt(getPacked(layer, "present_ctx")),
        .present = .{
            .width_px = @intCast(width),
            .height_px = @intCast(height),
            .reason = reason,
            .seq = seq,
            .host_time = 0,
        },
    };
}

/// Records the host-set target size (`Metal.setHostDrawableSize`, packed
/// width << 32 | height; 0 when the target follows the bounds), which
/// `setSurfaceCallback` checks frames against. Main thread.
pub fn setHostSize(self: *IOSurfaceLayer, value: u64) void {
    // Stored shifted left by 3 so the object-typed ivar holds an 8-aligned
    // pointer value (safe builds check the alignment of @ptrFromInt). The
    // ivar is never retained or released (no ARC layout on this class).
    const stored: usize = @intCast(value << 3);
    self.layer.setInstanceVariable("host_size", .{ .value = @ptrFromInt(stored) });
    if (value != 0) return;
    // The target follows the bounds again: the bounds and the scale give the frame's size, so a content scale that
    // waits for a frame at the host size (`setContentScale`) goes to the layer now.
    const CATransaction = objc.getClass("CATransaction").?;
    CATransaction.msgSend(void, objc.sel("lock"), .{});
    defer CATransaction.msgSend(void, objc.sel("unlock"), .{});
    const scale = getPacked(self.layer, "pending_scale");
    if (scale == 0) return;
    setPacked(self.layer, "pending_scale", 0);
    self.layer.setProperty("contentsScale", @as(f64, @floatFromInt(scale)) / scale_one);
}

/// The value `setHostSize` stored.
fn hostSize(layer: objc.Object) u64 {
    return @as(u64, @intFromPtr(layer.getInstanceVariable("host_size").value)) >> 3;
}

/// One, in the fixed point `pending_scale` holds (an object-typed ivar holds no f64: `setPacked`). Exact for 1x, 2x
/// and every scale with at most 20 binary places.
const scale_one: f64 = 1 << 20;

/// The embedder's display scale for a host-sized surface (`ghostty_surface_set_content_scale`; the embedder then
/// leaves the layer's `contentsScale` to Ghostty). The frame the layer shows was drawn at the old scale, so the layer
/// keeps its scale until the first frame at the host size shows: that frame and the scale change in one Core
/// Animation transaction (`applyPendingScaleLocked`), and until then frames go through main
/// (`offMainDecisionLocked`). It goes to the layer at once when no frame can show at another scale: the layer shows
/// none, or its target follows its bounds (no host size; the bounds and this scale then give the frame's size).
/// Known limit: a frame at the host size that the renderer drew before it applied the new scale's font grid also
/// lands the scale (the embedder sets the scale and then the size in one main-thread turn, and the renderer thread
/// takes both in that order, so this needs a frame drawn between the two). Main thread.
pub fn setContentScale(self: *IOSurfaceLayer, scale: f64) void {
    if (!(scale > 0)) return;
    const CATransaction = objc.getClass("CATransaction").?;
    CATransaction.msgSend(void, objc.sel("lock"), .{});
    defer CATransaction.msgSend(void, objc.sel("unlock"), .{});
    const layer = self.layer;
    if (layer.getProperty(f64, "contentsScale") == scale) {
        setPacked(layer, "pending_scale", 0);
        return;
    }
    if (hostSize(layer) == 0 or layer.getProperty(?*anyopaque, "contents") == null) {
        setPacked(layer, "pending_scale", 0);
        layer.setProperty("contentsScale", scale);
        return;
    }
    setPacked(layer, "pending_scale", @intFromFloat(@round(scale * scale_one)));
}

/// `surface` is about to become the layer's contents on the main thread: a content scale that waits
/// (`setContentScale`) goes to the layer with it, in the same transaction, when the frame has the host size (a frame
/// of another size was drawn before the change). Frames then go through main until main's commit, like after a
/// change of the shown size: a frame committed off main must not reach the screen ahead of the scale. Main thread,
/// under the Core Animation lock.
fn applyPendingScaleLocked(layer: objc.Object, surface: *IOSurface) void {
    const stored = getPacked(layer, "pending_scale");
    if (stored == 0) return;
    const host = hostSize(layer);
    if (host != 0 and ((host >> 32) != surface.getWidth() or (host & 0xffff_ffff) != surface.getHeight())) return;
    setPacked(layer, "pending_scale", 0);
    layer.setProperty("contentsScale", @as(f64, @floatFromInt(stored)) / scale_one);
    setMainPending(layer, true);
    clearAfterMainCommit(layer);
}

/// Whether showing `surface` changes the size of the frame the layer shows
/// (or shows a first frame): only such a change can leave the view's bounds
/// behind. Call under the Core Animation lock.
fn changesShownSize(layer: objc.Object, surface: *IOSurface) bool {
    const shown = layer.getProperty(?*anyopaque, "contents") orelse return true;
    const shown_surface: *IOSurface = @ptrCast(shown);
    return shown_surface.getWidth() != surface.getWidth() or shown_surface.getHeight() != surface.getHeight();
}

/// The pixel size of the frame the layer shows, or null while it shows
/// none. Read under the Core Animation lock: a frame presented off the main
/// thread (`setSurfaceOffMain`) can replace the shown one.
pub fn shownSize(self: *IOSurfaceLayer) ?struct { width: usize, height: usize } {
    const CATransaction = objc.getClass("CATransaction").?;
    CATransaction.msgSend(void, objc.sel("lock"), .{});
    defer CATransaction.msgSend(void, objc.sel("unlock"), .{});
    const shown = self.layer.getProperty(?*anyopaque, "contents") orelse return null;
    const surface: *IOSurface = @ptrCast(shown);
    return .{ .width = surface.getWidth(), .height = surface.getHeight() };
}

/// Whether the main thread changed the size of the frame a host-sized layer
/// shows in a transaction main has not committed yet: until then, a frame
/// committed off the main thread in its own transaction could reach the
/// screen ahead of the view's new bounds, so frames go through main. Set by
/// a main-thread present that changes the shown size (`markMainSizeChange`),
/// cleared right after main's commit (`clearAfterMainCommit`): it lasts one
/// main run loop pass, and no report of the embedder is needed. Read and
/// written under the Core Animation lock.
fn mainPending(layer: objc.Object) bool {
    return @intFromPtr(layer.getInstanceVariable("main_pending").value) != 0;
}

fn setMainPending(layer: objc.Object, pending: bool) void {
    // Stored like `setHostSize`: an 8-aligned value in an object-typed ivar, never retained.
    const stored: usize = @as(usize, @intFromBool(pending)) << 3;
    layer.setInstanceVariable("main_pending", .{ .value = @ptrFromInt(stored) });
}

/// The main thread is about to show `surface` in its open transaction: if
/// the layer is host-sized and this changes the shown size, frames go
/// through main until main's commit. Main thread, under the Core Animation
/// lock.
fn markMainSizeChange(layer: objc.Object, surface: *IOSurface) void {
    if (hostSize(layer) == 0 or !changesShownSize(layer, surface)) return;
    setMainPending(layer, true);
    clearAfterMainCommit(layer);
}

/// The observer `clearAfterMainCommit` added that has not fired, or null.
/// The ivar holds the one reference this layer owns (Create's), never
/// retained by the runtime. Under the Core Animation lock.
fn commitObserver(layer: objc.Object) macos.c.CFRunLoopObserverRef {
    return @ptrCast(layer.getInstanceVariable("commit_observer").value);
}

fn setCommitObserver(layer: objc.Object, observer: macos.c.CFRunLoopObserverRef) void {
    layer.setInstanceVariable("commit_observer", objc.Object.fromId(observer));
}

/// Core Animation commits the main thread's implicit transaction in its run
/// loop observer of this order (before waiting, and at a run loop's exit);
/// the observer of `clearAfterMainCommit` runs right after it.
const main_commit_order: macos.c.CFIndex = 2_000_000;

/// The main thread set `main_pending`: a one-shot observer of the main run
/// loop, right after Core Animation's commit observer, clears it. One
/// observer per layer at a time: a second change before it fires is in the
/// same transaction. Off the main thread nothing is added (main's commit
/// does not carry that thread's change; no caller does this). Known limit:
/// the exit of a nested run loop inside an explicit transaction that is
/// still open also fires it, before that transaction commits (no Ghostty or
/// cmux path changes the shown size in one). Call under the Core Animation
/// lock.
fn clearAfterMainCommit(layer: objc.Object) void {
    if (!objc.getClass("NSThread").?.msgSend(bool, "isMainThread", .{})) {
        log.warn("clearAfterMainCommit(): called off the main thread", .{});
        setMainPending(layer, false);
        return;
    }
    if (commitObserver(layer) != null) return;
    var context: macos.c.CFRunLoopObserverContext = .{
        .version = 0,
        .info = @ptrCast(layer.value),
        .retain = &retainObserverLayer,
        .release = &releaseObserverLayer,
        .copyDescription = null,
    };
    const activities: macos.c.CFRunLoopActivity = @intCast(macos.c.kCFRunLoopBeforeWaiting | macos.c.kCFRunLoopExit);
    // repeats false: the run loop removes the observer after its one fire.
    const observer = macos.c.CFRunLoopObserverCreate(
        null,
        activities,
        0,
        main_commit_order + 1,
        &mainCommitted,
        &context,
    ) orelse {
        // No observer: nothing would clear the flag, so frames keep going off main as before the change.
        setMainPending(layer, false);
        return;
    };
    setCommitObserver(layer, observer);
    macos.c.CFRunLoopAddObserver(macos.c.CFRunLoopGetMain(), observer, macos.c.kCFRunLoopCommonModes);
}

/// Main's commit ran (`clearAfterMainCommit`): frames go off main again. Main thread.
fn mainCommitted(
    observer: macos.c.CFRunLoopObserverRef,
    activity: macos.c.CFRunLoopActivity,
    info: ?*anyopaque,
) callconv(.c) void {
    _ = activity;
    // The run loop keeps the observer, and so the layer it holds, alive for this call.
    const layer = objc.Object.fromId(info);
    const CATransaction = objc.getClass("CATransaction").?;
    CATransaction.msgSend(void, objc.sel("lock"), .{});
    // A released wrapper took the observer back (`release`): nothing to do.
    if (commitObserver(layer) != observer) {
        CATransaction.msgSend(void, objc.sel("unlock"), .{});
        return;
    }
    setCommitObserver(layer, null);
    setMainPending(layer, false);
    CATransaction.msgSend(void, objc.sel("unlock"), .{});
    macos.c.CFRelease(observer);
}

fn retainObserverLayer(info: ?*const anyopaque) callconv(.c) ?*const anyopaque {
    _ = objc.Object.fromId(@constCast(info)).retain();
    return info;
}

fn releaseObserverLayer(info: ?*const anyopaque) callconv(.c) void {
    objc.Object.fromId(@constCast(info)).release();
}

/// Sets the layer's `contents` to the provided IOSurface.
///
/// Makes sure to do so on the main thread to avoid visual artifacts.
pub inline fn setSurface(self: *IOSurfaceLayer, surface: *IOSurface, seq: u64) !void {
    // We retain the surface to make sure it's not GC'd
    // before we can set it as the contents of the layer.
    //
    // We release in the callback after setting the contents.
    surface.retain();
    // NOTE: Since `self.layer` is passed as an `objc.c.id`, it's
    //       automatically retained when the block is copied, so we
    //       don't need to retain it ourselves like with the surface.

    var block = SetSurfaceBlock.init(.{
        .layer = self.layer.value,
        .surface = surface,
        .seq = seq,
    }, &setSurfaceCallback);

    // We check if we're on the main thread and run the block directly if so.
    const NSThread = objc.getClass("NSThread").?;
    if (NSThread.msgSend(bool, "isMainThread", .{})) {
        setSurfaceCallback(&block);
    } else {
        // NOTE: The block will be copied when we pass it to dispatch_async,
        //       and then automatically be deallocated by the objc runtime
        //       once it's executed.

        macos.dispatch.dispatch_async(
            @ptrCast(macos.dispatch.queue.getMain()),
            @ptrCast(&block),
        );
    }
}

/// Sets the layer's `contents` to the provided IOSurface.
///
/// Does not ensure this happens on the main thread.
pub inline fn setSurfaceSync(self: *IOSurfaceLayer, surface: *IOSurface) void {
    // Main thread (a display pass, ghostty_surface_draw): a new size on a
    // host-sized layer goes with main's commit, so frames go through main
    // until that commit. The present callback's report is read under the
    // lock too (an off-main present can change the shown frame).
    const CATransaction = objc.getClass("CATransaction").?;
    CATransaction.msgSend(void, objc.sel("lock"), .{});
    markMainSizeChange(self.layer, surface);
    applyPendingScaleLocked(self.layer, surface);
    var report = presentReportLocked(self.layer, surface, 0);
    self.layer.setProperty("contents", surface);
    CATransaction.msgSend(void, objc.sel("unlock"), .{});
    if (report) |*r| r.call();
}

const SetSurfaceBlock = objc.Block(struct {
    layer: objc.c.id,
    surface: *IOSurface,
    seq: u64,
}, .{}, void);

/// Presents `surface`, a frame that changes only content, from the calling
/// (GPU completion) thread in its own Core Animation transaction, without the
/// main thread: a terminal echo reaches the screen while main is busy. Only
/// when the frame has the host size (`setHostSize`, nonzero) and the layer
/// already shows a frame of that size, so no geometry change of the main
/// thread is pending for it, and only if no newer frame was presented
/// (`seq`). Returns false, and changes nothing, otherwise: the caller then
/// presents it through the main thread (`setSurface`) or holds it.
pub fn setSurfaceOffMain(self: *IOSurfaceLayer, surface: *IOSurface, seq: u64) bool {
    const width = surface.getWidth();
    const height = surface.getHeight();
    const host = hostSize(self.layer);
    if (host == 0 or (host >> 32) != width or (host & 0xffff_ffff) != height) return false;
    const CATransaction = objc.getClass("CATransaction").?;
    // The Core Animation lock orders this against `setSurfaceCallback` on main.
    CATransaction.msgSend(void, objc.sel("lock"), .{});
    switch (offMainDecisionLocked(self.layer, width, height, seq)) {
        // A transaction begins only for a frame shown here: a frame that goes through main, or an older one, commits
        // nothing on this thread (cmux S4 profile 4b41c42c: each such empty transaction cost a commit on the GPU
        // completion thread against main's own).
        .through_main => {
            CATransaction.msgSend(void, objc.sel("unlock"), .{});
            return false;
        },
        .superseded => {
            CATransaction.msgSend(void, objc.sel("unlock"), .{});
            return true;
        },
        .show => {},
    }
    // Invariant: no thread commits a Core Animation transaction (or flushes) while it holds [CATransaction lock]. A
    // commit waits for locks another thread's commit holds while that commit's work takes [CATransaction lock]
    // (cmux S4 films, 2026-11-03: main in commit_transaction, this thread in a present that committed under the
    // lock). The transaction begins under the lock (a begin takes no other lock and commits nothing), the frame
    // becomes its contents, and it commits after the unlock.
    CATransaction.msgSend(void, objc.sel("begin"), .{});
    setPresentSeq(self.layer, seq);
    var report = presentReportLocked(self.layer, surface, seq);
    self.layer.setProperty("contents", surface);
    CATransaction.msgSend(void, objc.sel("unlock"), .{});
    CATransaction.msgSend(void, objc.sel("commit"), .{});
    // After the commit: the frame is on its way to the screen.
    if (report) |*r| r.call();
    return true;
}

/// What `setSurfaceOffMain` does with a frame of `width` x `height`, present sequence `seq`, at the host size.
const OffMainDecision = enum { show, through_main, superseded };

/// The off-main checks, read-only: the layer shows a frame of this size (else the size change goes through main),
/// no newer frame was presented, no main-thread change of the shown size waits for main's commit and no content
/// scale waits for its frame. Call under the Core Animation lock.
fn offMainDecisionLocked(layer: objc.Object, width: usize, height: usize, seq: u64) OffMainDecision {
    const shown = layer.getProperty(?*anyopaque, "contents") orelse return .through_main;
    const shown_surface: *IOSurface = @ptrCast(shown);
    if (shown_surface.getWidth() != width or shown_surface.getHeight() != height) return .through_main;
    if (seq <= presentSeq(layer)) return .superseded;
    // The main thread changed the shown size in a transaction it has not committed: a transaction committed here
    // could reach the screen ahead of the view's new bounds. The frame goes through main, after that commit; the
    // flag clears right after it (`clearAfterMainCommit`), one main run loop pass at most.
    if (mainPending(layer)) return .through_main;
    // A content scale waits for its frame (`setContentScale`): it lands on main, with the frame, in one transaction.
    if (getPacked(layer, "pending_scale") != 0) return .through_main;
    return .show;
}

/// The sequence number of the newest frame presented (`setSurface`,
/// `setSurfaceOffMain`). Read and written under the Core Animation lock.
fn presentSeq(layer: objc.Object) u64 {
    return @as(u64, @intFromPtr(layer.getInstanceVariable("present_seq").value)) >> 3;
}

fn setPresentSeq(layer: objc.Object, seq: u64) void {
    // Shifted like `setHostSize`: the object-typed ivar holds an 8-aligned value, never retained.
    const stored: usize = @intCast(seq << 3);
    layer.setInstanceVariable("present_seq", .{ .value = @ptrFromInt(stored) });
}

const DetachFromHostBlock = objc.Block(struct {
    layer: objc.c.id,
    display_cb: ?*anyopaque,
    display_ctx: ?*anyopaque,
}, .{}, void);

fn detachFromHostCallback(
    block: *const DetachFromHostBlock.Context,
) callconv(.c) void {
    const layer = objc.Object.fromId(block.layer);

    // Ownership guard: a layer rebound to another renderer stays as it is.
    const cur_cb: ?*anyopaque = @ptrCast(layer.getInstanceVariable("display_cb").value);
    const cur_ctx: ?*anyopaque = @ptrCast(layer.getInstanceVariable("display_ctx").value);
    if (cur_cb != block.display_cb or cur_ctx != block.display_ctx) return;

    layer.setInstanceVariable("display_cb", .{ .value = null });
    layer.setInstanceVariable("display_ctx", .{ .value = null });
    layer.setProperty("contents", @as(?*anyopaque, null));
    layer.msgSend(void, objc.sel("removeFromSuperlayer"), .{});
}

fn setSurfaceCallback(
    block: *const SetSurfaceBlock.Context,
) callconv(.c) void {
    const layer = objc.Object.fromId(block.layer);
    const surface: *IOSurface = block.surface;

    // See explanation of why we retain and release in `setSurface`.
    defer surface.release();

    // We check to see if the surface is the appropriate size for
    // the layer, if it's not then we discard it. This is because
    // asynchronously drawn frames can sometimes finish just after
    // a synchronously drawn frame during a resize, and if we don't
    // discard the improperly sized surface it creates jank.
    // A host-sized layer expects the host's size, not its bounds (which
    // move ahead of it during a drag).
    const host = hostSize(layer);
    const bounds = layer.getProperty(macos.graphics.Rect, "bounds");
    const scale = layer.getProperty(f64, "contentsScale");
    const width: usize = if (host != 0) @intCast(host >> 32) else @intFromFloat(bounds.size.width * scale);
    const height: usize = if (host != 0) @intCast(host & 0xffff_ffff) else @intFromFloat(bounds.size.height * scale);
    if (width != surface.getWidth() or height != surface.getHeight()) {
        log.debug(
            "setSurfaceCallback(): surface is wrong size for layer, discarding. surface = {d}x{d}, layer = {d}x{d}",
            .{ surface.getWidth(), surface.getHeight(), width, height },
        );
        return;
    }

    // A newer frame went to the screen off the main thread meanwhile
    // (`setSurfaceOffMain`): this older one must not replace it.
    const CATransaction = objc.getClass("CATransaction").?;
    CATransaction.msgSend(void, objc.sel("lock"), .{});
    var report = showLocked(layer, surface, block.seq);
    CATransaction.msgSend(void, objc.sel("unlock"), .{});
    // Outside the lock: the callback never runs under it.
    if (report) |*r| r.call();
}

/// The part of `setSurfaceCallback` under the Core Animation lock: shows `surface` (frame `seq`) unless a newer frame
/// is shown. Returns the present callback's report of a frame it showed.
fn showLocked(layer: objc.Object, surface: *IOSurface, seq: u64) ?PresentReport {
    if (seq != 0 and seq <= presentSeq(layer)) return null;

    if (seq != 0) setPresentSeq(layer, seq);
    // A new size shows in main's open transaction, with any bounds change of
    // this pass: frames at it go through main until that commit.
    markMainSizeChange(layer, surface);
    applyPendingScaleLocked(layer, surface);
    const report = presentReportLocked(layer, surface, seq);
    layer.setProperty("contents", surface);
    return report;
}

pub const DisplayCallback = ?*align(8) const fn (?*anyopaque) void;

pub fn setDisplayCallback(
    self: *IOSurfaceLayer,
    display_cb: DisplayCallback,
    display_ctx: ?*anyopaque,
) void {
    self.layer.setInstanceVariable(
        "display_cb",
        objc.Object.fromId(@constCast(display_cb)),
    );
    self.layer.setInstanceVariable(
        "display_ctx",
        objc.Object.fromId(display_ctx),
    );
}

fn getSubclass() error{ObjCFailed}!objc.Class {
    if (Subclass) |c| return c;

    const CALayer =
        objc.getClass("CALayer") orelse return error.ObjCFailed;

    var subclass =
        objc.allocateClassPair(CALayer, "IOSurfaceLayer") orelse return error.ObjCFailed;
    errdefer objc.disposeClassPair(subclass);

    if (!subclass.addIvar("display_cb")) return error.ObjCFailed;
    if (!subclass.addIvar("display_ctx")) return error.ObjCFailed;
    if (!subclass.addIvar("host_size")) return error.ObjCFailed;
    if (!subclass.addIvar("present_seq")) return error.ObjCFailed;
    if (!subclass.addIvar("main_pending")) return error.ObjCFailed;
    if (!subclass.addIvar("present_cb")) return error.ObjCFailed;
    if (!subclass.addIvar("present_ctx")) return error.ObjCFailed;
    if (!subclass.addIvar("commit_observer")) return error.ObjCFailed;
    if (!subclass.addIvar("pending_scale")) return error.ObjCFailed;

    subclass.replaceMethod("display", struct {
        fn display(target: objc.c.id, sel: objc.c.SEL) callconv(.c) void {
            _ = sel;
            const self = objc.Object.fromId(target);
            const display_cb: DisplayCallback = @ptrFromInt(@intFromPtr(
                self.getInstanceVariable("display_cb").value,
            ));
            if (display_cb) |cb| cb(
                @ptrCast(self.getInstanceVariable("display_ctx").value),
            );
        }
    }.display);

    // Disable all animations for this layer by returning null for all actions.
    subclass.replaceMethod("actionForKey:", struct {
        fn actionForKey(
            target: objc.c.id,
            sel: objc.c.SEL,
            key: objc.c.id,
        ) callconv(.c) objc.c.id {
            _ = target;
            _ = sel;
            _ = key;
            return objc.getClass("NSNull").?.msgSend(objc.c.id, "null", .{});
        }
    }.actionForKey);

    objc.registerClassPair(subclass);

    Subclass = subclass;

    return subclass;
}

fn testSurface(width: c_int, height: c_int) !*IOSurface {
    return try IOSurface.init(.{
        .width = width,
        .height = height,
        .pixel_format = .@"32BGRA",
        .bytes_per_element = 4,
        .colorspace = null,
    });
}

/// The width of the frame the layer shows; null while it shows none.
fn testShownWidth(self: *const IOSurfaceLayer) ?usize {
    const shown = self.layer.getProperty(?*anyopaque, "contents") orelse return null;
    const surface: *IOSurface = @ptrCast(shown);
    return surface.getWidth();
}

fn testIsMainThread() bool {
    return objc.getClass("NSThread").?.msgSend(bool, "isMainThread", .{});
}

test "host present: a frame of a new host size on main is shown by default" {
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    var layer = try IOSurfaceLayer.init();
    defer layer.release();
    const shown = try testSurface(80, 60);
    defer shown.release();
    const drawn = try testSurface(120, 60);
    defer drawn.release();
    layer.setSurfaceSync(shown);
    layer.setHostSize((120 << 32) | 60);

    try layer.setSurface(drawn, 1);
    try testing.expectEqual(@as(?usize, 120), testShownWidth(&layer));
}

test "host present: a frame of a size the host no longer has is dropped on main" {
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    var layer = try IOSurfaceLayer.init();
    defer layer.release();
    const shown = try testSurface(80, 60);
    defer shown.release();
    const stale = try testSurface(100, 60);
    defer stale.release();
    layer.setSurfaceSync(shown);
    layer.setHostSize((120 << 32) | 60);

    try layer.setSurface(stale, 1);
    try testing.expectEqual(@as(?usize, 80), testShownWidth(&layer));
}

test "host present: a frame at the shown size shown on main keeps frames going off main" {
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    var layer = try IOSurfaceLayer.init();
    defer layer.release();
    const shown = try testSurface(120, 60);
    defer shown.release();
    const queued = try testSurface(120, 60);
    defer queued.release();
    const next = try testSurface(120, 60);
    defer next.release();
    layer.setHostSize((120 << 32) | 60);
    layer.setSurfaceSync(shown);
    testRunMainLoopOnce();

    // A frame of the shown size on main changes no geometry: terminal echo
    // after it still goes off main, in the same main run loop pass.
    try layer.setSurface(queued, 1);
    try testing.expect(layer.setSurfaceOffMain(next, 2));
    const contents = layer.layer.getProperty(?*anyopaque, "contents");
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(next)), contents);
}

test "host present: a sync present at the shown size keeps frames going off main" {
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    var layer = try IOSurfaceLayer.init();
    defer layer.release();
    const shown = try testSurface(120, 60);
    defer shown.release();
    const drawn = try testSurface(120, 60);
    defer drawn.release();
    const next = try testSurface(120, 60);
    defer next.release();
    layer.setHostSize((120 << 32) | 60);
    layer.setSurfaceSync(shown);
    testRunMainLoopOnce();

    layer.setSurfaceSync(drawn);
    try testing.expect(layer.setSurfaceOffMain(next, 1));
}

test "host present: a released layer's observer that waits for main's commit does nothing" {
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    var layer = try IOSurfaceLayer.init();
    const shown = try testSurface(80, 60);
    defer shown.release();
    layer.setHostSize((80 << 32) | 60);
    // A first frame on main: an observer now waits for main's commit, holding the layer.
    layer.setSurfaceSync(shown);
    try testing.expect(commitObserver(layer.layer) != null);
    layer.release();
    // The observer was invalidated with the wrapper: the pass runs no callback on a freed layer.
    testRunMainLoopOnce();
}

/// Counts, per thread, the transaction commits made while the thread holds [CATransaction lock] (the
/// commit-order test): +[CATransaction lock], +unlock and +commit are swapped for counting versions that call the
/// originals.
const CommitOrder = struct {
    const Imp = *const fn (objc.c.id, objc.c.SEL) callconv(.c) void;
    threadlocal var depth: i32 = 0;
    threadlocal var commits: u32 = 0;
    threadlocal var commits_under_lock: u32 = 0;
    var original_lock: ?Imp = null;
    var original_unlock: ?Imp = null;
    var original_commit: ?Imp = null;
    /// The presenting thread's counts, copied out before it ends.
    var seen_commits: u32 = 0;
    var seen_commits_under_lock: u32 = 0;

    fn lock(target: objc.c.id, sel: objc.c.SEL) callconv(.c) void {
        original_lock.?(target, sel);
        depth += 1;
    }

    fn unlock(target: objc.c.id, sel: objc.c.SEL) callconv(.c) void {
        depth -= 1;
        original_unlock.?(target, sel);
    }

    fn commit(target: objc.c.id, sel: objc.c.SEL) callconv(.c) void {
        commits += 1;
        if (depth > 0) commits_under_lock += 1;
        original_commit.?(target, sel);
    }

    fn swap(meta: objc.Class, name: [:0]const u8, imp: Imp) ?Imp {
        const old = objc.c.class_replaceMethod(meta.value, objc.sel(name).value, @ptrCast(imp), null);
        return @ptrCast(old);
    }

    fn install() void {
        const meta = objc.getMetaClass("CATransaction").?;
        original_lock = swap(meta, "lock", &lock);
        original_unlock = swap(meta, "unlock", &unlock);
        original_commit = swap(meta, "commit", &commit);
    }

    fn remove() void {
        const meta = objc.getMetaClass("CATransaction").?;
        _ = swap(meta, "lock", original_lock.?);
        _ = swap(meta, "unlock", original_unlock.?);
        _ = swap(meta, "commit", original_commit.?);
    }

    /// The GPU completion thread's role: one off-main present of a frame at the shown size.
    fn present(layer: *IOSurfaceLayer, surface: *IOSurface, presented: *bool) void {
        presentAt(layer, surface, 1, presented);
    }

    /// One off-main present of `surface` as frame `seq`, from a thread of its own.
    fn presentAt(layer: *IOSurfaceLayer, surface: *IOSurface, seq: u64, presented: *bool) void {
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        presented.* = layer.setSurfaceOffMain(surface, seq);
        seen_commits = commits;
        seen_commits_under_lock = commits_under_lock;
    }
};

/// The commits one off-main present of `surface` (frame `seq`) makes on its own thread, and whether it showed it.
fn testOffMainCommits(layer: *IOSurfaceLayer, surface: *IOSurface, seq: u64) !struct { presented: bool, commits: u32 } {
    CommitOrder.install();
    defer CommitOrder.remove();
    var presented = false;
    const thread = try std.Thread.spawn(.{}, CommitOrder.presentAt, .{ layer, surface, seq, &presented });
    thread.join();
    return .{ .presented = presented, .commits = CommitOrder.seen_commits };
}

test "host present: an off-main present that does not show its frame commits no transaction" {
    // cmux FRAME OWNER REFACTOR S4 profile 4b41c42c (2026-11-05): every frame of a new size failed the off-main
    // checks and went through main, but its off-main attempt first began and committed a Core Animation
    // transaction: one empty commit on the GPU completion thread per present (405 ms of
    // CA::Context::commit_transaction in a held-key round), against main's own commit. A present that shows nothing
    // commits nothing.
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    var layer = try IOSurfaceLayer.init();
    defer layer.release();
    const shown = try testSurface(80, 60);
    defer shown.release();
    const resized = try testSurface(120, 60);
    defer resized.release();
    const same = try testSurface(80, 60);
    defer same.release();
    layer.setSurfaceSync(shown);

    // No host size: the frame goes through main.
    var result = try testOffMainCommits(&layer, same, 1);
    try testing.expect(!result.presented);
    try testing.expectEqual(@as(u32, 0), result.commits);

    // A frame of another size than the host's: through main.
    layer.setHostSize((80 << 32) | 60);
    result = try testOffMainCommits(&layer, resized, 2);
    try testing.expect(!result.presented);
    try testing.expectEqual(@as(u32, 0), result.commits);

    // The host has the new size, the layer still shows the old one: the size change goes through main.
    layer.setHostSize((120 << 32) | 60);
    result = try testOffMainCommits(&layer, resized, 3);
    try testing.expect(!result.presented);
    try testing.expectEqual(@as(u32, 0), result.commits);

    // Main showed the new size in a transaction it has not committed: through main.
    try layer.setSurface(resized, 4);
    const pending = try testSurface(120, 60);
    defer pending.release();
    result = try testOffMainCommits(&layer, pending, 5);
    try testing.expect(!result.presented);
    try testing.expectEqual(@as(u32, 0), result.commits);

    // An older frame than the one shown: dropped, nothing to commit.
    testRunMainLoopOnce();
    const older = try testSurface(120, 60);
    defer older.release();
    result = try testOffMainCommits(&layer, older, 3);
    try testing.expect(result.presented);
    try testing.expectEqual(@as(u32, 0), result.commits);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(resized)), layer.layer.getProperty(?*anyopaque, "contents"));

    // A frame it shows still commits once, outside the lock.
    const next = try testSurface(120, 60);
    defer next.release();
    result = try testOffMainCommits(&layer, next, 6);
    try testing.expect(result.presented);
    try testing.expectEqual(@as(u32, 1), result.commits);
    try testing.expectEqual(@as(u32, 0), CommitOrder.seen_commits_under_lock);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(next)), layer.layer.getProperty(?*anyopaque, "contents"));
}

test "host present: an off-main present never commits while it holds the Core Animation lock" {
    // cmux FRAME OWNER REFACTOR S4 films, 2026-11-03: the main thread hung in CA::Transaction::commit and the Metal
    // completion thread in setSurfaceOffMain, which committed while it held [CATransaction lock] (defers run
    // last-first: commit, then unlock).
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    var layer = try IOSurfaceLayer.init();
    defer layer.release();
    const shown = try testSurface(80, 60);
    defer shown.release();
    const drawn = try testSurface(80, 60);
    defer drawn.release();
    layer.setHostSize((80 << 32) | 60);
    layer.setSurfaceSync(shown);
    // Main's commit of the first frame: the next frame at the shown size may go off main.
    testRunMainLoopOnce();

    CommitOrder.install();
    defer CommitOrder.remove();
    var presented = false;
    const thread = try std.Thread.spawn(.{}, CommitOrder.present, .{ &layer, drawn, &presented });
    thread.join();

    // The present ran off the main thread and committed its frame, once.
    try testing.expect(presented);
    const contents = layer.layer.getProperty(?*anyopaque, "contents");
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(drawn)), contents);
    try testing.expectEqual(@as(u32, 1), CommitOrder.seen_commits);
    // The invariant, on the presenting thread: no commit while it holds [CATransaction lock] (the off-main present
    // calls no flush, so the test counts commits only).
    try testing.expectEqual(@as(u32, 0), CommitOrder.seen_commits_under_lock);
}

/// Turns the main run loop once, so the observers of a pass run: Core Animation's commit, then the one
/// `clearAfterMainCommit` adds right after it.
fn testRunMainLoopOnce() void {
    _ = macos.c.CFRunLoopRunInMode(macos.c.kCFRunLoopDefaultMode, 0, 0);
}

test "resize sync: a main-thread frame of a new size keeps frames on main only until main's commit" {
    // S-P3 (cmux NIGHTLY REGRESSION, IOSurfaceLayer.zig:297 at b3a5ebfdf): a main-thread change of the shown size set
    // `main_pending`, and only the embedder's report (`ghostty_surface_host_frame_committed`) cleared it. When cmux
    // dropped its watch after 240 ticks without that report, every later frame of the terminal, scroll and output
    // too, went through main. Ghostty now clears it itself after main's commit: no report of the embedder exists.
    // Before main's commit, an off-main transaction could reach the screen ahead of the view's new bounds.
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    var layer = try IOSurfaceLayer.init();
    defer layer.release();
    const shown = try testSurface(80, 60);
    defer shown.release();
    const drawn = try testSurface(120, 60);
    defer drawn.release();
    const next = try testSurface(120, 60);
    defer next.release();
    const after = try testSurface(120, 60);
    defer after.release();
    layer.setSurfaceSync(shown);
    layer.setHostSize((120 << 32) | 60);
    testRunMainLoopOnce();

    // The renderer's frame of the new size, on main (setSurface runs its block at once on the main thread).
    try layer.setSurface(drawn, 1);
    try testing.expectEqual(@as(?usize, 120), testShownWidth(&layer));
    // Main has not committed that change: a frame at that size goes through main.
    try testing.expect(!layer.setSurfaceOffMain(next, 2));
    // Main's commit: frames at the shown size go off main again, with no report from the embedder.
    testRunMainLoopOnce();
    try testing.expect(layer.setSurfaceOffMain(after, 3));
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(after)), layer.layer.getProperty(?*anyopaque, "contents"));
}

test "resize sync: a sync draw of a new size keeps frames on main only until main's commit" {
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    var layer = try IOSurfaceLayer.init();
    defer layer.release();
    const shown = try testSurface(80, 60);
    defer shown.release();
    const drawn = try testSurface(120, 60);
    defer drawn.release();
    const next = try testSurface(120, 60);
    defer next.release();
    const after = try testSurface(120, 60);
    defer after.release();
    layer.setSurfaceSync(shown);
    layer.setHostSize((120 << 32) | 60);
    testRunMainLoopOnce();

    // ghostty_surface_draw (or a display pass) on main at the new size.
    layer.setSurfaceSync(drawn);
    try testing.expect(!layer.setSurfaceOffMain(next, 1));
    testRunMainLoopOnce();
    try testing.expect(layer.setSurfaceOffMain(after, 2));
}

fn testScale(self: *const IOSurfaceLayer) f64 {
    return self.layer.getProperty(f64, "contentsScale");
}

test "host present: a new content scale goes to the layer with the first frame at the new host size" {
    // cmux P12 (TerminalSurfaceCommitSizeTests "a new display scale lands with the frame drawn at it"): the window
    // moved to a display of another scale and the embedder set the layer's `contentsScale` at once, so the frame
    // drawn at the old scale showed at the new scale (half or double size) for 1-4 refreshes. The scale and the
    // frame drawn at it must change in one Core Animation transaction.
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    var layer = try IOSurfaceLayer.init();
    defer layer.release();
    layer.layer.setProperty("contentsScale", @as(f64, 2));
    const shown = try testSurface(160, 120);
    defer shown.release();
    const stale = try testSurface(160, 120);
    defer stale.release();
    const drawn = try testSurface(80, 60);
    defer drawn.release();
    const next = try testSurface(80, 60);
    defer next.release();
    layer.setHostSize((160 << 32) | 120);
    layer.setSurfaceSync(shown);
    testRunMainLoopOnce();

    // The window is on a 1x display now: the embedder sets the scale, then the size in pixels.
    layer.setContentScale(1);
    // The frame the layer shows was drawn at 2x: it keeps its scale.
    try testing.expectEqual(@as(f64, 2), testScale(&layer));
    // A frame drawn before the change does not go off main while the scale waits, and main drops it: its size is
    // not the host's.
    try testing.expect(!layer.setSurfaceOffMain(stale, 1));
    layer.setHostSize((80 << 32) | 60);
    try layer.setSurface(stale, 1);
    try testing.expectEqual(@as(?usize, 160), testShownWidth(&layer));
    try testing.expectEqual(@as(f64, 2), testScale(&layer));

    // The frame at the new host size: it and the scale change together, in main's transaction.
    try layer.setSurface(drawn, 2);
    try testing.expectEqual(@as(?usize, 80), testShownWidth(&layer));
    try testing.expectEqual(@as(f64, 1), testScale(&layer));
    // Until main's commit a frame goes through main; after it frames go off main again.
    try testing.expect(!layer.setSurfaceOffMain(next, 3));
    testRunMainLoopOnce();
    try testing.expect(layer.setSurfaceOffMain(next, 3));
    try testing.expectEqual(@as(f64, 1), testScale(&layer));
}

test "host present: a new content scale at the same pixel size shows with the next frame, through main" {
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    var layer = try IOSurfaceLayer.init();
    defer layer.release();
    layer.layer.setProperty("contentsScale", @as(f64, 2));
    const shown = try testSurface(160, 120);
    defer shown.release();
    const drawn = try testSurface(160, 120);
    defer drawn.release();
    const next = try testSurface(160, 120);
    defer next.release();
    layer.setHostSize((160 << 32) | 120);
    layer.setSurfaceSync(shown);
    testRunMainLoopOnce();

    // Half the scale and twice the points: the same pixels.
    layer.setContentScale(1);
    try testing.expectEqual(@as(f64, 2), testScale(&layer));
    try testing.expect(!layer.setSurfaceOffMain(drawn, 1));
    try layer.setSurface(drawn, 1);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(drawn)), layer.layer.getProperty(?*anyopaque, "contents"));
    try testing.expectEqual(@as(f64, 1), testScale(&layer));
    // The scale is in main's open transaction: a frame goes through main until main's commit.
    try testing.expect(!layer.setSurfaceOffMain(next, 2));
    testRunMainLoopOnce();
    try testing.expect(layer.setSurfaceOffMain(next, 2));
}

test "host present: a content scale set back before its frame leaves frames going off main" {
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    var layer = try IOSurfaceLayer.init();
    defer layer.release();
    layer.layer.setProperty("contentsScale", @as(f64, 2));
    const shown = try testSurface(160, 120);
    defer shown.release();
    const next = try testSurface(160, 120);
    defer next.release();
    layer.setHostSize((160 << 32) | 120);
    layer.setSurfaceSync(shown);
    testRunMainLoopOnce();

    layer.setContentScale(1);
    layer.setContentScale(2);
    try testing.expectEqual(@as(f64, 2), testScale(&layer));
    try testing.expect(layer.setSurfaceOffMain(next, 1));
    try testing.expectEqual(@as(f64, 2), testScale(&layer));
}

test "host present: a content scale goes to the layer at once when no frame can show at another scale" {
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    // No frame shown yet: nothing can show at the wrong scale.
    var first = try IOSurfaceLayer.init();
    defer first.release();
    first.setHostSize((160 << 32) | 120);
    first.setContentScale(2);
    try testing.expectEqual(@as(f64, 2), testScale(&first));

    // The target follows the bounds (no host size): the bounds and the scale give the frame's size, so the scale
    // cannot wait for a frame.
    var following = try IOSurfaceLayer.init();
    defer following.release();
    const shown = try testSurface(160, 120);
    defer shown.release();
    following.setSurfaceSync(shown);
    following.setContentScale(2);
    try testing.expectEqual(@as(f64, 2), testScale(&following));

    // A scale that waits when the surface stops being host-sized goes to the layer then.
    var released = try IOSurfaceLayer.init();
    defer released.release();
    released.layer.setProperty("contentsScale", @as(f64, 2));
    released.setHostSize((160 << 32) | 120);
    released.setSurfaceSync(shown);
    testRunMainLoopOnce();
    released.setContentScale(1);
    released.setHostSize(0);
    try testing.expectEqual(@as(f64, 1), testScale(&released));
}
