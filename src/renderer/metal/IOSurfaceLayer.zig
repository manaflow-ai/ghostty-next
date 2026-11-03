//! A wrapper around a CALayer with a utility method
//! for settings its `contents` to an IOSurface.
const IOSurfaceLayer = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const macos = @import("macos");

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
    layer.setInstanceVariable("embedder_presents", .{ .value = null });
    layer.setInstanceVariable("main_pending", .{ .value = null });

    return .{ .layer = layer };
}

pub fn release(self: *IOSurfaceLayer) void {
    // The layer may be retained by the view after we release our reference.
    // Clear the callback first so that a later display pass can't access the
    // renderer that owned this wrapper after it has been freed.
    self.setDisplayCallback(null, null);
    self.layer.release();
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

/// Records the host-set target size (`Metal.setHostDrawableSize`, packed
/// width << 32 | height; 0 when the target follows the bounds), which
/// `setSurfaceCallback` checks frames against. Main thread.
pub fn setHostSize(self: *IOSurfaceLayer, value: u64) void {
    // Stored shifted left by 3 so the object-typed ivar holds an 8-aligned
    // pointer value (safe builds check the alignment of @ptrFromInt). The
    // ivar is never retained or released (no ARC layout on this class).
    const stored: usize = @intCast(value << 3);
    self.layer.setInstanceVariable("host_size", .{ .value = @ptrFromInt(stored) });
}

/// The value `setHostSize` stored.
fn hostSize(layer: objc.Object) u64 {
    return @as(u64, @intFromPtr(layer.getInstanceVariable("host_size").value)) >> 3;
}

/// Records whether the embedder presents the frames of a new host size
/// (`Metal.setEmbedderPresents`, ghostty_surface_set_host_present), which
/// `setSurfaceCallback` checks frames against. Main thread.
pub fn setEmbedderPresents(self: *IOSurfaceLayer, enabled: bool) void {
    // Stored like `setHostSize`: an 8-aligned value in an object-typed ivar,
    // never retained or released.
    const stored: usize = @as(usize, @intFromBool(enabled)) << 3;
    self.layer.setInstanceVariable("embedder_presents", .{ .value = @ptrFromInt(stored) });
    // A mode change starts with nothing of the embedder's pending.
    self.setEmbedderCommitted();
}

/// The value `setEmbedderPresents` stored.
fn embedderPresents(layer: objc.Object) bool {
    return @intFromPtr(layer.getInstanceVariable("embedder_presents").value) != 0;
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

/// Shows `surface`, the frame of present sequence `seq`, in the caller's
/// Core Animation transaction (the embedder's, which gives the view its new
/// bounds), unless the layer shows a newer frame (`setSurface`,
/// `setSurfaceOffMain`). Returns whether it did. Main thread.
pub fn setSurfacePresented(self: *IOSurfaceLayer, surface: *IOSurface, seq: u64) bool {
    const CATransaction = objc.getClass("CATransaction").?;
    CATransaction.msgSend(void, objc.sel("lock"), .{});
    defer CATransaction.msgSend(void, objc.sel("unlock"), .{});
    if (seq <= presentSeq(self.layer)) return false;
    setPresentSeq(self.layer, seq);
    setMainPending(self.layer, true);
    self.layer.setProperty("contents", surface);
    return true;
}

/// The embedder committed the transaction of its last present or bounds change
/// (`ghostty_surface_host_frame_committed`): frames at the shown size go to the
/// screen off the main thread again. Main thread.
pub fn setEmbedderCommitted(self: *IOSurfaceLayer) void {
    const CATransaction = objc.getClass("CATransaction").?;
    CATransaction.msgSend(void, objc.sel("lock"), .{});
    defer CATransaction.msgSend(void, objc.sel("unlock"), .{});
    setMainPending(self.layer, false);
}

/// Whether, while the embedder presents host sizes, the main thread changed
/// the layer's contents in a transaction the embedder has not reported
/// committed (`setEmbedderCommitted`). Ghostty cannot see the main thread's
/// commit: until the embedder reports it, a frame committed off the main
/// thread in its own transaction could reach the screen ahead of the view's
/// new bounds, so frames go through main. Read and written under the Core
/// Animation lock.
fn mainPending(layer: objc.Object) bool {
    return @intFromPtr(layer.getInstanceVariable("main_pending").value) != 0;
}

fn setMainPending(layer: objc.Object, pending: bool) void {
    // Stored like `setHostSize`: an 8-aligned value in an object-typed ivar, never retained.
    const stored: usize = @as(usize, @intFromBool(pending)) << 3;
    layer.setInstanceVariable("main_pending", .{ .value = @ptrFromInt(stored) });
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
    // Main thread (a display pass, ghostty_surface_draw): with the embedder
    // presenting host sizes, frames go through main until its commit.
    if (embedderPresents(self.layer)) {
        const CATransaction = objc.getClass("CATransaction").?;
        CATransaction.msgSend(void, objc.sel("lock"), .{});
        defer CATransaction.msgSend(void, objc.sel("unlock"), .{});
        setMainPending(self.layer, true);
    }
    self.layer.setProperty("contents", surface);
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
/// presents it through the main thread (`setSurface`).
pub fn setSurfaceOffMain(self: *IOSurfaceLayer, surface: *IOSurface, seq: u64) bool {
    const width = surface.getWidth();
    const height = surface.getHeight();
    const host = hostSize(self.layer);
    if (host == 0 or (host >> 32) != width or (host & 0xffff_ffff) != height) return false;
    const CATransaction = objc.getClass("CATransaction").?;
    CATransaction.msgSend(void, objc.sel("begin"), .{});
    defer CATransaction.msgSend(void, objc.sel("commit"), .{});
    // The Core Animation lock orders this against `setSurfaceCallback` on main.
    CATransaction.msgSend(void, objc.sel("lock"), .{});
    defer CATransaction.msgSend(void, objc.sel("unlock"), .{});
    const shown = self.layer.getProperty(?*anyopaque, "contents") orelse return false;
    const shown_surface: *IOSurface = @ptrCast(shown);
    if (shown_surface.getWidth() != width or shown_surface.getHeight() != height) return false;
    if (seq <= presentSeq(self.layer)) return true;
    // The main thread changed the contents in a transaction the embedder has
    // not reported committed: a transaction committed here could reach the
    // screen ahead of the view's new bounds. The frame goes through main.
    if (embedderPresents(self.layer) and mainPending(self.layer)) return false;
    setPresentSeq(self.layer, seq);
    self.layer.setProperty("contents", surface);
    return true;
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
    defer CATransaction.msgSend(void, objc.sel("unlock"), .{});
    if (block.seq != 0 and block.seq <= presentSeq(layer)) return;

    // An embedder that presents host sizes shows a frame of another size
    // than the shown one itself, in the transaction that gives the view its
    // bounds (`Metal.hostFrame`): such a frame shows here only if the bounds
    // already have its size (the embedder set them without a present), so a
    // commit never carries new pixels in the old bounds. A first frame
    // (nothing shown) presents itself.
    if (embedderPresents(layer)) embedder: {
        const shown = layer.getProperty(?*anyopaque, "contents") orelse break :embedder;
        const shown_surface: *IOSurface = @ptrCast(shown);
        if (shown_surface.getWidth() == surface.getWidth() and
            shown_surface.getHeight() == surface.getHeight()) break :embedder;
        const bounds_width: usize = @intFromFloat(bounds.size.width * scale);
        const bounds_height: usize = @intFromFloat(bounds.size.height * scale);
        if (bounds_width != surface.getWidth() or bounds_height != surface.getHeight()) return;
    }

    if (block.seq != 0) setPresentSeq(layer, block.seq);
    if (embedderPresents(layer)) setMainPending(layer, true);
    layer.setProperty("contents", surface);
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
    if (!subclass.addIvar("embedder_presents")) return error.ObjCFailed;
    if (!subclass.addIvar("main_pending")) return error.ObjCFailed;

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

test "host present: a frame of a new host size on main keeps the shown frame while the embedder presents sizes" {
    const testing = std.testing;
    // setSurface runs the main-thread present at once only on the main thread.
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
    layer.setEmbedderPresents(true);

    // A frame of the new size that reached the main thread (queued before the
    // embedder took over size changes): the embedder shows a new size with its
    // bounds in its own transaction, so this frame does not replace the shown one.
    try layer.setSurface(drawn, 1);
    try testing.expectEqual(@as(?usize, 80), testShownWidth(&layer));
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

test "host present: a frame of a new host size on main is shown when the layer's bounds already have that size" {
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
    layer.setEmbedderPresents(true);
    // The embedder gave the view its new bounds without a present (a hidden
    // surface, a frame that came too late): the new frame fits them.
    layer.layer.setProperty("contentsScale", @as(f64, 1));
    layer.layer.setProperty("bounds", macos.graphics.Rect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 120, .height = 60 },
    });

    try layer.setSurface(drawn, 1);
    try testing.expectEqual(@as(?usize, 120), testShownWidth(&layer));
}

test "host present: an off-main frame never joins a present the embedder has not committed yet" {
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    var layer = try IOSurfaceLayer.init();
    defer layer.release();
    const shown = try testSurface(80, 60);
    defer shown.release();
    const presented = try testSurface(120, 60);
    defer presented.release();
    const next = try testSurface(120, 60);
    defer next.release();
    const after = try testSurface(120, 60);
    defer after.release();
    layer.setSurfaceSync(shown);
    layer.setHostSize((120 << 32) | 60);
    layer.setEmbedderPresents(true);

    // The embedder showed the new size; its transaction (with the view's new
    // bounds) is not committed yet.
    try testing.expect(layer.setSurfacePresented(presented, 5));
    // A newer frame at that size completes: an off-main transaction would
    // commit it, alone, before the embedder's bounds. It goes through main.
    try testing.expect(!layer.setSurfaceOffMain(next, 6));
    const contents = layer.layer.getProperty(?*anyopaque, "contents");
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(presented)), contents);
    // On main it shows; once the embedder committed, frames go off main again.
    try layer.setSurface(next, 6);
    layer.setEmbedderCommitted();
    try testing.expect(layer.setSurfaceOffMain(after, 7));
    const later = layer.layer.getProperty(?*anyopaque, "contents");
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(after)), later);
}

test "host present: a main-thread frame after the embedder's present keeps frames on main until the embedder committed" {
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    var layer = try IOSurfaceLayer.init();
    defer layer.release();
    const shown = try testSurface(80, 60);
    defer shown.release();
    const presented = try testSurface(120, 60);
    defer presented.release();
    const queued = try testSurface(120, 60);
    defer queued.release();
    const next = try testSurface(120, 60);
    defer next.release();
    const later = try testSurface(120, 60);
    defer later.release();
    layer.setSurfaceSync(shown);
    layer.setHostSize((120 << 32) | 60);
    layer.setEmbedderPresents(true);

    try testing.expect(layer.setSurfacePresented(presented, 5));
    // A main-queue block runs before the embedder's commit (CFRunLoop runs
    // main-queue blocks before the before-waiting observers): it shows a
    // newer frame at that size in main's open transaction.
    try layer.setSurface(queued, 6);
    // An off-main commit now would still go out ahead of the embedder's bounds.
    try testing.expect(!layer.setSurfaceOffMain(next, 7));
    // The embedder committed: frames go off main again.
    layer.setEmbedderCommitted();
    try testing.expect(layer.setSurfaceOffMain(later, 8));
}

test "host present: a frame shown because the bounds already fit keeps frames on main until the embedder committed" {
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
    layer.setSurfaceSync(shown);
    layer.setHostSize((120 << 32) | 60);
    layer.setEmbedderPresents(true);
    layer.setEmbedderCommitted();
    // The embedder gave the view its new bounds without a present.
    layer.layer.setProperty("contentsScale", @as(f64, 1));
    layer.layer.setProperty("bounds", macos.graphics.Rect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 120, .height = 60 },
    });
    try layer.setSurface(drawn, 1);
    try testing.expectEqual(@as(?usize, 120), testShownWidth(&layer));
    // Those bounds are not committed yet either.
    try testing.expect(!layer.setSurfaceOffMain(next, 2));
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
    layer.setSurfaceSync(shown);
    layer.setHostSize((120 << 32) | 60);
    layer.setEmbedderPresents(true);
    layer.setEmbedderCommitted();

    // A frame of the shown size on main changes no geometry: terminal echo
    // after it still goes off main.
    try layer.setSurface(queued, 1);
    try testing.expect(layer.setSurfaceOffMain(next, 2));
    const contents = layer.layer.getProperty(?*anyopaque, "contents");
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(next)), contents);
}

test "host present: the mode starts with frames on main until the embedder committed" {
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    var layer = try IOSurfaceLayer.init();
    defer layer.release();
    const shown = try testSurface(120, 60);
    defer shown.release();
    const first = try testSurface(120, 60);
    defer first.release();
    const later = try testSurface(120, 60);
    defer later.release();
    layer.setSurfaceSync(shown);
    layer.setHostSize((120 << 32) | 60);

    // A change the main thread made before the mode may still be in its open
    // transaction.
    layer.setEmbedderPresents(true);
    try testing.expect(!layer.setSurfaceOffMain(first, 1));
    layer.setEmbedderCommitted();
    try testing.expect(layer.setSurfaceOffMain(later, 2));
}

test "host present: a sync present of a new size keeps frames on main until the embedder committed" {
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
    layer.setSurfaceSync(shown);
    layer.setHostSize((120 << 32) | 60);
    layer.setEmbedderPresents(true);
    layer.setEmbedderCommitted();

    // ghostty_surface_draw on main at the new size.
    layer.setSurfaceSync(drawn);
    try testing.expect(!layer.setSurfaceOffMain(next, 1));
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
    layer.setSurfaceSync(shown);
    layer.setHostSize((120 << 32) | 60);
    layer.setEmbedderPresents(true);
    layer.setEmbedderCommitted();

    layer.setSurfaceSync(drawn);
    try testing.expect(layer.setSurfaceOffMain(next, 1));
}
