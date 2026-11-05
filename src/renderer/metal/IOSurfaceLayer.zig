//! A wrapper around a CALayer with a utility method
//! for settings its `contents` to an IOSurface.
const IOSurfaceLayer = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const macos = @import("macos");

const IOSurface = macos.iosurface.IOSurface;
const mtl = @import("api.zig");
const Device = @import("Device.zig");

const log = std.log.scoped(.IOSurfaceLayer);

/// We subclass CALayer with a custom display handler, we only need
/// to make the subclass once, and then we can use it as a singleton.
var Subclass: ?objc.Class = null;

/// The underlying CALayer
layer: objc.Object,

/// A frame for the layer: its IOSurface and the pixel size it was drawn at,
/// from the surface's top-left corner. The surface is larger than that only
/// while the host sets a capacity (`Metal.setHostCapacity`): the layer then
/// shows only the drawn pixels (`contentsRect`, `showLocked`).
pub const Drawn = struct {
    surface: *IOSurface,
    width: usize,
    height: usize,

    /// A frame drawn over the whole of `surface`.
    pub fn whole(surface: *IOSurface) Drawn {
        return .{ .surface = surface, .width = surface.getWidth(), .height = surface.getHeight() };
    }
};

/// A pixel size.
pub const Size = struct { width: usize, height: usize };

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
    const CATransaction = objc.getClass("CATransaction").?;
    CATransaction.msgSend(void, objc.sel("lock"), .{});
    defer CATransaction.msgSend(void, objc.sel("unlock"), .{});
    self.layer.setInstanceVariable("embedder_presents", .{ .value = @ptrFromInt(stored) });
    // The mode starts closed: a change the main thread made before it may
    // still be in its open transaction. Leaving it, nothing is pending.
    setMainPending(self.layer, enabled);
}

/// Whether showing a frame drawn at `width` x `height` changes the size of
/// the frame the layer shows (or shows a first frame): only such a change can
/// leave the view's bounds behind. Call under the Core Animation lock.
fn changesShownSize(layer: objc.Object, width: usize, height: usize) bool {
    const shown = shownSizeLocked(layer) orelse return true;
    return shown.width != width or shown.height != height;
}

/// The pixel size of the frame the layer shows, or null while it shows none:
/// the part of its contents (an IOSurface) that `contentsRect` selects, which
/// is the whole surface unless the frame was drawn in a larger target (a host
/// capacity, `showLocked`). Read from the layer itself, so a change of its
/// contents by the embedder counts too. Call under the Core Animation lock:
/// `contents` and `contentsRect` change together under it.
fn shownSizeLocked(layer: objc.Object) ?Size {
    const shown = layer.getProperty(?*anyopaque, "contents") orelse return null;
    const surface: *IOSurface = @ptrCast(shown);
    const rect = layer.getProperty(macos.graphics.Rect, "contentsRect");
    return .{
        .width = @intFromFloat(@round(rect.size.width * @as(f64, @floatFromInt(surface.getWidth())))),
        .height = @intFromFloat(@round(rect.size.height * @as(f64, @floatFromInt(surface.getHeight())))),
    };
}

/// The `contentsRect` (unit coordinates of the contents) that shows exactly
/// the drawn pixels of `frame`: its top-left `width` x `height` pixels. The
/// unit rect (the whole surface) for a frame drawn over its whole surface.
pub fn drawnRect(frame: Drawn) macos.graphics.Rect {
    const surface_width: f64 = @floatFromInt(frame.surface.getWidth());
    const surface_height: f64 = @floatFromInt(frame.surface.getHeight());
    const width = @as(f64, @floatFromInt(frame.width)) / surface_width;
    const height = @as(f64, @floatFromInt(frame.height)) / surface_height;
    return .{
        .origin = .{ .x = 0, .y = if (contents_rect_y_up) 1 - height else 0 },
        .size = .{ .width = width, .height = height },
    };
}

/// Whether a `contentsRect` y of 0 is the bottom row of an IOSurface contents
/// (true) or its top row, the row Metal draws first (false). Proved by the
/// test "host present: a capacity frame shows only its drawn pixels,
/// top-left", which renders the layer.
const contents_rect_y_up = true;

/// Shows `frame`: the layer's contents becomes its surface, and
/// `contentsRect` selects its drawn pixels, in the same Core Animation lock
/// span, so no reader sees one without the other. Every present sets both
/// here. Call under the Core Animation lock.
fn showLocked(layer: objc.Object, frame: Drawn) void {
    layer.setProperty("contents", frame.surface);
    const rect = drawnRect(frame);
    const current = layer.getProperty(macos.graphics.Rect, "contentsRect");
    if (current.origin.x != rect.origin.x or current.origin.y != rect.origin.y or
        current.size.width != rect.size.width or current.size.height != rect.size.height)
    {
        layer.setProperty("contentsRect", rect);
    }
}

/// The value `setEmbedderPresents` stored.
fn embedderPresents(layer: objc.Object) bool {
    return @intFromPtr(layer.getInstanceVariable("embedder_presents").value) != 0;
}

/// The pixel size of the frame the layer shows (its drawn size, not its
/// surface's: a capacity target is larger, `shownSizeLocked`), or null while
/// it shows none. Read under the Core Animation lock: a frame presented off
/// the main thread (`setSurfaceOffMain`) can replace the shown one.
pub fn shownSize(self: *IOSurfaceLayer) ?Size {
    const CATransaction = objc.getClass("CATransaction").?;
    CATransaction.msgSend(void, objc.sel("lock"), .{});
    defer CATransaction.msgSend(void, objc.sel("unlock"), .{});
    return shownSizeLocked(self.layer);
}

/// Shows `frame`, the frame of present sequence `seq`, in the caller's
/// Core Animation transaction (the embedder's, which gives the view its new
/// bounds), unless the layer shows a newer frame (`setSurface`,
/// `setSurfaceOffMain`). Returns whether it did. Main thread.
pub fn setSurfacePresented(self: *IOSurfaceLayer, frame: Drawn, seq: u64) bool {
    const CATransaction = objc.getClass("CATransaction").?;
    CATransaction.msgSend(void, objc.sel("lock"), .{});
    defer CATransaction.msgSend(void, objc.sel("unlock"), .{});
    if (seq <= presentSeq(self.layer)) return false;
    setPresentSeq(self.layer, seq);
    setMainPending(self.layer, true);
    showLocked(self.layer, frame);
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

/// Shows `frame` (its surface as the layer's `contents`, `showLocked`).
///
/// Makes sure to do so on the main thread to avoid visual artifacts.
pub inline fn setSurface(self: *IOSurfaceLayer, frame: Drawn, seq: u64) !void {
    // We retain the surface to make sure it's not GC'd
    // before we can set it as the contents of the layer.
    //
    // We release in the callback after setting the contents.
    frame.surface.retain();
    // NOTE: Since `self.layer` is passed as an `objc.c.id`, it's
    //       automatically retained when the block is copied, so we
    //       don't need to retain it ourselves like with the surface.

    var block = SetSurfaceBlock.init(.{
        .layer = self.layer.value,
        .surface = frame.surface,
        .width = frame.width,
        .height = frame.height,
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

/// Shows `frame` (its surface as the layer's `contents`, `showLocked`).
///
/// Does not ensure this happens on the main thread.
pub inline fn setSurfaceSync(self: *IOSurfaceLayer, frame: Drawn) void {
    // The contents and the contents rect change in one lock span (an
    // off-main present reads both under the lock).
    const CATransaction = objc.getClass("CATransaction").?;
    CATransaction.msgSend(void, objc.sel("lock"), .{});
    defer CATransaction.msgSend(void, objc.sel("unlock"), .{});
    // Main thread (a display pass, ghostty_surface_draw): with the embedder
    // presenting host sizes, a new size goes with main's commit, so frames go
    // through main until the embedder reports it.
    if (embedderPresents(self.layer) and changesShownSize(self.layer, frame.width, frame.height)) {
        setMainPending(self.layer, true);
    }
    showLocked(self.layer, frame);
}

const SetSurfaceBlock = objc.Block(struct {
    layer: objc.c.id,
    surface: *IOSurface,
    /// The drawn size of the frame (`Drawn`).
    width: usize,
    height: usize,
    seq: u64,
}, .{}, void);

/// Presents `frame`, a frame that changes only content, from the calling
/// (GPU completion) thread in its own Core Animation transaction, without the
/// main thread: a terminal echo reaches the screen while main is busy. Only
/// when the frame was drawn at the host size (`setHostSize`, nonzero) and the
/// layer already shows a frame of that size, so no geometry change of the
/// main thread is pending for it, and only if no newer frame was presented
/// (`seq`). Returns false, and changes nothing, otherwise: the caller then
/// presents it through the main thread (`setSurface`).
pub fn setSurfaceOffMain(self: *IOSurfaceLayer, frame: Drawn, seq: u64) bool {
    const width = frame.width;
    const height = frame.height;
    const host = hostSize(self.layer);
    if (host == 0 or (host >> 32) != width or (host & 0xffff_ffff) != height) return false;
    const CATransaction = objc.getClass("CATransaction").?;
    // The Core Animation lock orders this against `setSurfaceCallback` on main.
    CATransaction.msgSend(void, objc.sel("lock"), .{});
    switch (offMainDecisionLocked(self.layer, width, height, seq)) {
        // A transaction begins only for a frame shown here: a frame that goes through main, or an older one, commits
        // nothing on this thread (cmux S4 profile 4b41c42c: while the embedder presents host sizes every frame of a
        // new size goes through main, and each one's empty transaction cost a commit on the GPU completion thread
        // against main's own).
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
    // (cmux S4 films, 2026-11-03: main in commit_transaction, this thread in an embedder-mode present that
    // committed under the lock). The transaction begins under the lock (a begin takes no other lock and commits
    // nothing), the frame becomes its contents, and it commits after the unlock.
    CATransaction.msgSend(void, objc.sel("begin"), .{});
    setPresentSeq(self.layer, seq);
    showLocked(self.layer, frame);
    CATransaction.msgSend(void, objc.sel("unlock"), .{});
    CATransaction.msgSend(void, objc.sel("commit"), .{});
    return true;
}

/// What `setSurfaceOffMain` does with a frame of `width` x `height`, present sequence `seq`, at the host size.
const OffMainDecision = enum { show, through_main, superseded };

/// The off-main checks, read-only: the layer shows a frame drawn at this size (else the size change goes through
/// main), no newer frame was presented, and no main-thread change waits for the embedder's commit. Call under the
/// Core Animation lock.
fn offMainDecisionLocked(layer: objc.Object, width: usize, height: usize, seq: u64) OffMainDecision {
    const shown = shownSizeLocked(layer) orelse return .through_main;
    if (shown.width != width or shown.height != height) return .through_main;
    if (seq <= presentSeq(layer)) return .superseded;
    // The embedder presents host sizes and the main thread changed the shown size in a transaction the embedder
    // has not reported committed: a transaction committed here could reach the screen ahead of the view's new
    // bounds. The frame goes through main (`setSurface`), after that commit.
    if (embedderPresents(layer) and mainPending(layer)) return .through_main;
    return .show;
}

/// While the embedder presents host sizes (`setEmbedderPresents`): whether
/// the layer cannot show `frame`, drawn at the host size, in its bounds now, so `setSurfaceCallback` would drop it and the embedder
/// presents it with its bounds (`Metal.hostFrame`). True when the layer shows
/// a frame of another size and its bounds do not have this frame's size.
/// False for a first frame (nothing shown), a frame at the shown size (it
/// waits for the embedder's commit, through main) and bounds the embedder
/// already set (it presents itself through main). Call under the Core
/// Animation lock, which orders it against main's changes
/// (`Metal.embedderShowsKeptFrame`).
pub fn embedderShowsFrameLocked(self: *IOSurfaceLayer, frame: Drawn) bool {
    return embedderDrops(self.layer, frame.width, frame.height);
}

/// The one rule of `setSurfaceCallback` and `embedderShowsFrameLocked`: with
/// the embedder presenting host sizes, whether the main-thread present must
/// not show a frame drawn at `width` x `height` now, because the layer shows a
/// frame of another size and its bounds do not have that size (the embedder
/// shows it with its bounds). A first frame (nothing shown), a frame at the
/// shown size and a frame for bounds the embedder already set are shown. Sizes
/// are drawn sizes (`Drawn`), never a capacity surface's. Call under the Core
/// Animation lock.
fn embedderDrops(layer: objc.Object, width: usize, height: usize) bool {
    if (!embedderPresents(layer)) return false;
    const shown = shownSizeLocked(layer) orelse return false;
    if (shown.width == width and shown.height == height) return false;
    const bounds = layer.getProperty(macos.graphics.Rect, "bounds");
    const scale = layer.getProperty(f64, "contentsScale");
    const bounds_width: usize = @intFromFloat(bounds.size.width * scale);
    const bounds_height: usize = @intFromFloat(bounds.size.height * scale);
    return bounds_width != width or bounds_height != height;
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
    const frame: Drawn = .{ .surface = surface, .width = block.width, .height = block.height };

    // See explanation of why we retain and release in `setSurface`.
    defer surface.release();

    // We check to see if the surface is the appropriate size for
    // the layer, if it's not then we discard it. This is because
    // asynchronously drawn frames can sometimes finish just after
    // a synchronously drawn frame during a resize, and if we don't
    // discard the improperly sized surface it creates jank.
    // A host-sized layer expects the host's size, not its bounds (which
    // move ahead of it during a drag). The frame's drawn size, not its
    // surface's (a capacity target is larger).
    const host = hostSize(layer);
    const bounds = layer.getProperty(macos.graphics.Rect, "bounds");
    const scale = layer.getProperty(f64, "contentsScale");
    const width: usize = if (host != 0) @intCast(host >> 32) else @intFromFloat(bounds.size.width * scale);
    const height: usize = if (host != 0) @intCast(host & 0xffff_ffff) else @intFromFloat(bounds.size.height * scale);
    if (width != frame.width or height != frame.height) {
        log.debug(
            "setSurfaceCallback(): frame is wrong size for layer, discarding. frame = {d}x{d}, layer = {d}x{d}",
            .{ frame.width, frame.height, width, height },
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
    if (embedderDrops(layer, frame.width, frame.height)) return;

    if (block.seq != 0) setPresentSeq(layer, block.seq);
    if (embedderPresents(layer) and changesShownSize(layer, frame.width, frame.height)) setMainPending(layer, true);
    showLocked(layer, frame);
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
    layer.setSurfaceSync(.whole(shown));
    layer.setHostSize((120 << 32) | 60);
    layer.setEmbedderPresents(true);

    // A frame of the new size that reached the main thread (queued before the
    // embedder took over size changes): the embedder shows a new size with its
    // bounds in its own transaction, so this frame does not replace the shown one.
    try layer.setSurface(.whole(drawn), 1);
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
    layer.setSurfaceSync(.whole(shown));
    layer.setHostSize((120 << 32) | 60);

    try layer.setSurface(.whole(drawn), 1);
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
    layer.setSurfaceSync(.whole(shown));
    layer.setHostSize((120 << 32) | 60);
    layer.setEmbedderPresents(true);
    // The embedder gave the view its new bounds without a present (a hidden
    // surface, a frame that came too late): the new frame fits them.
    layer.layer.setProperty("contentsScale", @as(f64, 1));
    layer.layer.setProperty("bounds", macos.graphics.Rect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 120, .height = 60 },
    });

    try layer.setSurface(.whole(drawn), 1);
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
    layer.setSurfaceSync(.whole(shown));
    layer.setHostSize((120 << 32) | 60);
    layer.setEmbedderPresents(true);

    // The embedder showed the new size; its transaction (with the view's new
    // bounds) is not committed yet.
    try testing.expect(layer.setSurfacePresented(.whole(presented), 5));
    // A newer frame at that size completes: an off-main transaction would
    // commit it, alone, before the embedder's bounds. It goes through main.
    try testing.expect(!layer.setSurfaceOffMain(.whole(next), 6));
    const contents = layer.layer.getProperty(?*anyopaque, "contents");
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(presented)), contents);
    // On main it shows; once the embedder committed, frames go off main again.
    try layer.setSurface(.whole(next), 6);
    layer.setEmbedderCommitted();
    try testing.expect(layer.setSurfaceOffMain(.whole(after), 7));
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
    layer.setSurfaceSync(.whole(shown));
    layer.setHostSize((120 << 32) | 60);
    layer.setEmbedderPresents(true);

    try testing.expect(layer.setSurfacePresented(.whole(presented), 5));
    // A main-queue block runs before the embedder's commit (CFRunLoop runs
    // main-queue blocks before the before-waiting observers): it shows a
    // newer frame at that size in main's open transaction.
    try layer.setSurface(.whole(queued), 6);
    // An off-main commit now would still go out ahead of the embedder's bounds.
    try testing.expect(!layer.setSurfaceOffMain(.whole(next), 7));
    // The embedder committed: frames go off main again.
    layer.setEmbedderCommitted();
    try testing.expect(layer.setSurfaceOffMain(.whole(later), 8));
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
    layer.setSurfaceSync(.whole(shown));
    layer.setHostSize((120 << 32) | 60);
    layer.setEmbedderPresents(true);
    layer.setEmbedderCommitted();
    // The embedder gave the view its new bounds without a present.
    layer.layer.setProperty("contentsScale", @as(f64, 1));
    layer.layer.setProperty("bounds", macos.graphics.Rect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 120, .height = 60 },
    });
    try layer.setSurface(.whole(drawn), 1);
    try testing.expectEqual(@as(?usize, 120), testShownWidth(&layer));
    // Those bounds are not committed yet either.
    try testing.expect(!layer.setSurfaceOffMain(.whole(next), 2));
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
    layer.setSurfaceSync(.whole(shown));
    layer.setHostSize((120 << 32) | 60);
    layer.setEmbedderPresents(true);
    layer.setEmbedderCommitted();

    // A frame of the shown size on main changes no geometry: terminal echo
    // after it still goes off main.
    try layer.setSurface(.whole(queued), 1);
    try testing.expect(layer.setSurfaceOffMain(.whole(next), 2));
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
    layer.setSurfaceSync(.whole(shown));
    layer.setHostSize((120 << 32) | 60);

    // A change the main thread made before the mode may still be in its open
    // transaction.
    layer.setEmbedderPresents(true);
    try testing.expect(!layer.setSurfaceOffMain(.whole(first), 1));
    layer.setEmbedderCommitted();
    try testing.expect(layer.setSurfaceOffMain(.whole(later), 2));
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
    layer.setSurfaceSync(.whole(shown));
    layer.setHostSize((120 << 32) | 60);
    layer.setEmbedderPresents(true);
    layer.setEmbedderCommitted();

    // ghostty_surface_draw on main at the new size.
    layer.setSurfaceSync(.whole(drawn));
    try testing.expect(!layer.setSurfaceOffMain(.whole(next), 1));
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
    layer.setSurfaceSync(.whole(shown));
    layer.setHostSize((120 << 32) | 60);
    layer.setEmbedderPresents(true);
    layer.setEmbedderCommitted();

    layer.setSurfaceSync(.whole(drawn));
    try testing.expect(layer.setSurfaceOffMain(.whole(next), 1));
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
        presented.* = layer.setSurfaceOffMain(.whole(surface), seq);
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
    // cmux FRAME OWNER REFACTOR S4 profile 4b41c42c (2026-11-05): with the embedder presenting host sizes, every
    // frame of a new size failed the off-main checks and went through main, but its off-main attempt first began and
    // committed a Core Animation transaction: one empty commit on the GPU completion thread per present (405 ms of
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
    layer.setSurfaceSync(.whole(shown));

    // No host size: the frame goes through main.
    var result = try testOffMainCommits(&layer, same, 1);
    try testing.expect(!result.presented);
    try testing.expectEqual(@as(u32, 0), result.commits);

    // A frame of another size than the host's: through main.
    layer.setHostSize((80 << 32) | 60);
    result = try testOffMainCommits(&layer, resized, 2);
    try testing.expect(!result.presented);
    try testing.expectEqual(@as(u32, 0), result.commits);

    // The host has the new size, the layer still shows the old one (the embedder presents it with its bounds).
    layer.setHostSize((120 << 32) | 60);
    layer.setEmbedderPresents(true);
    layer.setEmbedderCommitted();
    result = try testOffMainCommits(&layer, resized, 3);
    try testing.expect(!result.presented);
    try testing.expectEqual(@as(u32, 0), result.commits);

    // The embedder showed the new size in a transaction it has not reported committed: through main.
    try testing.expect(layer.setSurfacePresented(.whole(resized), 4));
    const pending = try testSurface(120, 60);
    defer pending.release();
    result = try testOffMainCommits(&layer, pending, 5);
    try testing.expect(!result.presented);
    try testing.expectEqual(@as(u32, 0), result.commits);

    // An older frame than the one shown: dropped, nothing to commit.
    layer.setEmbedderCommitted();
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

fn testOffMainCommitOrder(embedder: bool) !void {
    const testing = std.testing;
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    var layer = try IOSurfaceLayer.init();
    defer layer.release();
    const shown = try testSurface(80, 60);
    defer shown.release();
    const drawn = try testSurface(80, 60);
    defer drawn.release();
    layer.setSurfaceSync(.whole(shown));
    layer.setHostSize((80 << 32) | 60);
    if (embedder) {
        layer.setEmbedderPresents(true);
        // Its last change is committed: the next frame at the shown size may go off main.
        layer.setEmbedderCommitted();
    }

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

test "host present: an off-main present never commits while it holds the Core Animation lock (embedder)" {
    // cmux FRAME OWNER REFACTOR S4 films, 2026-11-03: with the embedder presenting host sizes, the main thread hung
    // in CA::Transaction::commit and the Metal completion thread in setSurfaceOffMain, whose embedder branch
    // committed while it held [CATransaction lock] (defers run last-first: commit, then unlock).
    try testOffMainCommitOrder(true);
}

test "host present: an off-main present never commits while it holds the Core Animation lock (renderer)" {
    try testOffMainCommitOrder(false);
}

/// Fills `surface` with a picture in which every pixel has its own color: blue from its column, green from its row,
/// and red high inside the top-left `drawn_width` x `drawn_height` pixels (the frame of a capacity target), low outside.
fn testPicture(surface: *IOSurface, drawn_width: usize, drawn_height: usize) void {
    surface.lock();
    defer surface.unlock();
    const base = surface.getBaseAddress().?;
    const bytes_per_row = surface.getBytesPerRow();
    for (0..surface.getHeight()) |y| {
        for (0..surface.getWidth()) |x| {
            const pixel = base + y * bytes_per_row + x * 4;
            pixel[0] = @intCast(x * 30 + 10);
            pixel[1] = @intCast(y * 30 + 10);
            pixel[2] = if (x < drawn_width and y < drawn_height) 200 else 20;
            pixel[3] = 255;
        }
    }
}

/// What Core Animation shows of `layer`: its layer tree rendered (CARenderer, on `device`) into a `width` x `height`
/// BGRA texture, read back row by row. The layer has `width` x `height` points at scale 1, nearest filtering, so one
/// point is one surface pixel.
fn testRendered(device: objc.Object, layer: objc.Object, width: usize, height: usize, out: []u32) !void {
    const rect: macos.graphics.Rect = .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) },
    };
    layer.setProperty("contentsScale", @as(f64, 1));
    layer.setProperty("anchorPoint", macos.graphics.Point{ .x = 0, .y = 0 });
    layer.setProperty("position", macos.graphics.Point{ .x = 0, .y = 0 });
    layer.setProperty("bounds", rect);
    const NSString = objc.getClass("NSString").?;
    const nearest = NSString.msgSend(objc.Object, objc.sel("stringWithUTF8String:"), .{"nearest"});
    layer.setProperty("magnificationFilter", nearest.value);
    layer.setProperty("minificationFilter", nearest.value);

    const unified = device.getProperty(bool, "hasUnifiedMemory");
    const descriptor = objc.getClass("MTLTextureDescriptor").?.msgSend(
        objc.Object,
        objc.sel("texture2DDescriptorWithPixelFormat:width:height:mipmapped:"),
        .{ @as(c_ulong, 80), @as(c_ulong, width), @as(c_ulong, height), false },
    );
    descriptor.setProperty("usage", @as(c_ulong, 5)); // shader read | render target
    descriptor.setProperty("storageMode", @as(c_ulong, if (unified) 0 else 1)); // shared | managed
    const texture = objc.Object.fromId(
        device.msgSend(?*anyopaque, objc.sel("newTextureWithDescriptor:"), .{descriptor}) orelse return error.MetalFailed,
    );
    defer texture.release();
    const queue = device.msgSend(objc.Object, objc.sel("newCommandQueue"), .{});
    defer queue.release();

    const TestCA = struct {
        extern "c" const kCARendererMetalCommandQueue: objc.c.id;
        extern "c" fn CACurrentMediaTime() f64;
    };
    const options = objc.getClass("NSDictionary").?.msgSend(
        objc.Object,
        objc.sel("dictionaryWithObject:forKey:"),
        .{ queue.value, TestCA.kCARendererMetalCommandQueue },
    );
    const renderer = objc.getClass("CARenderer").?.msgSend(
        objc.Object,
        objc.sel("rendererWithMTLTexture:options:"),
        .{ texture.value, options.value },
    );
    renderer.setProperty("layer", layer.value);
    renderer.setProperty("bounds", rect);
    // The layer's changes reach the render tree with a commit.
    objc.getClass("CATransaction").?.msgSend(void, objc.sel("flush"), .{});
    renderer.msgSend(void, objc.sel("beginFrameAtTime:timeStamp:"), .{ TestCA.CACurrentMediaTime(), @as(?*anyopaque, null) });
    renderer.msgSend(void, objc.sel("addUpdateRect:"), .{rect});
    renderer.msgSend(void, objc.sel("render"), .{});
    renderer.msgSend(void, objc.sel("endFrame"), .{});
    // The renderer encodes on `queue`: a command buffer after its work completes after it.
    const done = queue.msgSend(objc.Object, objc.sel("commandBuffer"), .{});
    if (!unified) {
        const blit = done.msgSend(objc.Object, objc.sel("blitCommandEncoder"), .{});
        blit.msgSend(void, objc.sel("synchronizeResource:"), .{texture.value});
        blit.msgSend(void, objc.sel("endEncoding"), .{});
    }
    done.msgSend(void, objc.sel("commit"), .{});
    done.msgSend(void, objc.sel("waitUntilCompleted"), .{});
    texture.msgSend(void, objc.sel("getBytes:bytesPerRow:fromRegion:mipmapLevel:"), .{
        @as(*anyopaque, @ptrCast(out.ptr)),
        @as(c_ulong, width * 4),
        mtl.MTLRegion{
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .size = .{ .width = width, .height = height, .depth = 1 },
        },
        @as(c_ulong, 0),
    });
}

test "host present: a capacity frame shows only its drawn pixels, top-left" {
    // cmux FRAME OWNER S4, plan B: while the host sets a capacity, a frame is drawn in the top-left corner of a larger
    // target, and the layer shows only that part (contentsRect). Rendered by Core Animation, the layer must show
    // exactly the drawn pixels: none of the rest of the surface, unscaled, and the right way up (the surface's first
    // row, the one Metal draws first, at the top, as when a frame fills its surface). This also settles which way
    // the unit rect's y runs for an IOSurface (`contents_rect_y_up`).
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    var device = try Device.initForTest();
    defer device.deinit();

    // A capacity target of 8 x 8 pixels with a frame drawn at 6 x 4.
    const surface = try testSurface(8, 8);
    defer surface.release();
    testPicture(surface, 6, 4);

    // The whole surface, as a frame that fills its target shows: surface row y is layer row y from the top. Which
    // way the rendered texture runs is the renderer's; the red marks of the drawn rows tell it.
    var whole = try IOSurfaceLayer.init();
    defer whole.release();
    whole.setSurfaceSync(.whole(surface));
    var reference: [8 * 8]u32 = undefined;
    try testRendered(device.device, whole.layer, 8, 8, &reference);
    const red = struct {
        fn of(pixel: u32) u32 {
            return (pixel >> 16) & 0xff;
        }
    }.of;
    const first_drawn = red(reference[0]) > 100;
    const last_drawn = red(reference[7 * 8]) > 100;
    // Exactly one end of the texture holds the drawn rows: the picture is not stretched or empty.
    try testing.expect(first_drawn != last_drawn);
    const texture_row_0_is_top = first_drawn;

    // The capacity frame, in a layer of its own size.
    var layer = try IOSurfaceLayer.init();
    defer layer.release();
    layer.setSurfaceSync(.{ .surface = surface, .width = 6, .height = 4 });
    try testing.expectEqual(@as(?Size, .{ .width = 6, .height = 4 }), layer.shownSize());
    var shown: [6 * 4]u32 = undefined;
    try testRendered(device.device, layer.layer, 6, 4, &shown);
    // Layer row r from the top shows surface row r, column c shows column c: the pixel the whole surface showed there.
    for (0..4) |row| {
        for (0..6) |column| {
            const shown_row = if (texture_row_0_is_top) row else 3 - row;
            const whole_row = if (texture_row_0_is_top) row else 7 - row;
            testing.expectEqual(reference[whole_row * 8 + column], shown[shown_row * 6 + column]) catch |err| {
                std.debug.print("layer pixel ({d}, {d}) from the top-left is not surface pixel ({d}, {d})\n", .{ column, row, column, row });
                return err;
            };
        }
    }

    // In bounds larger than the frame (a drag ahead of it), the frame stays in the top-left corner, unscaled.
    var ahead = try IOSurfaceLayer.init();
    defer ahead.release();
    ahead.setSurfaceSync(.{ .surface = surface, .width = 6, .height = 4 });
    var wide: [8 * 8]u32 = undefined;
    try testRendered(device.device, ahead.layer, 8, 8, &wide);
    for (0..4) |row| {
        for (0..6) |column| {
            const texture_row = if (texture_row_0_is_top) row else 7 - row;
            try testing.expectEqual(reference[texture_row * 8 + column], wide[texture_row * 8 + column]);
        }
    }
}

test "host present: a frame that fills its surface keeps the whole surface as its contents rect" {
    // No capacity (the default): every present sets the unit contentsRect, as the layer had before.
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    var layer = try IOSurfaceLayer.init();
    defer layer.release();
    const capacity = try testSurface(160, 60);
    defer capacity.release();
    const whole = try testSurface(80, 60);
    defer whole.release();

    layer.setSurfaceSync(.{ .surface = capacity, .width = 120, .height = 60 });
    try testing.expectEqual(@as(?Size, .{ .width = 120, .height = 60 }), layer.shownSize());
    layer.setSurfaceSync(.whole(whole));
    const rect = layer.layer.getProperty(macos.graphics.Rect, "contentsRect");
    try testing.expectEqual(@as(f64, 0), rect.origin.x);
    try testing.expectEqual(@as(f64, 0), rect.origin.y);
    try testing.expectEqual(@as(f64, 1), rect.size.width);
    try testing.expectEqual(@as(f64, 1), rect.size.height);
    try testing.expectEqual(@as(?Size, .{ .width = 80, .height = 60 }), layer.shownSize());
}

test "host present: an off-main frame of a capacity target compares its drawn size, not its surface's" {
    // Every size rule of the S4 present mode compares drawn sizes: a capacity target's IOSurface is larger than the
    // frame drawn in it. A content-only frame at the host size goes off main into a layer that shows a frame of that
    // drawn size, and a frame of another drawn size in the same surface does not.
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    var layer = try IOSurfaceLayer.init();
    defer layer.release();
    const shown = try testSurface(160, 60);
    defer shown.release();
    const next = try testSurface(160, 60);
    defer next.release();
    layer.setSurfaceSync(.{ .surface = shown, .width = 120, .height = 60 });
    layer.setHostSize((120 << 32) | 60);
    layer.setEmbedderPresents(true);
    layer.setEmbedderCommitted();

    try testing.expect(layer.setSurfaceOffMain(.{ .surface = next, .width = 120, .height = 60 }, 1));
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(next)), layer.layer.getProperty(?*anyopaque, "contents"));
    // The host moved on: a frame drawn at 130 in the same surface is a new size; it goes through main.
    layer.setHostSize((130 << 32) | 60);
    try testing.expect(!layer.setSurfaceOffMain(.{ .surface = shown, .width = 130, .height = 60 }, 2));
    // The embedder shows it with its bounds: the layer's bounds (80 points) have neither size.
    layer.layer.setProperty("contentsScale", @as(f64, 1));
    layer.layer.setProperty("bounds", macos.graphics.Rect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 80, .height = 60 },
    });
    try testing.expect(layer.embedderShowsFrameLocked(.{ .surface = shown, .width = 130, .height = 60 }));
    try testing.expect(!layer.embedderShowsFrameLocked(.{ .surface = shown, .width = 120, .height = 60 }));
}
