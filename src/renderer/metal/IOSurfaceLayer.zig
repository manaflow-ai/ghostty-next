//! A wrapper around a CALayer with a utility method
//! for settings its `contents` to an IOSurface.
const IOSurfaceLayer = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const macos = @import("macos");
const cursorpkg = @import("../cursor.zig");

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
    layer.setInstanceVariable("cursor_layer", .{ .value = null });
    layer.setInstanceVariable("cursor_epoch", .{ .value = null });

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

/// A blinking cursor shown over the contents on a sublayer, in the same
/// Core Animation transaction as the frame it belongs to. A keyframe
/// animation of the sublayer's opacity blinks it, so the render server runs
/// the blink and the renderer wakes for none of it (renderer CursorLayer).
pub const Cursor = extern struct {
    /// The cursor's pixels; null: the frame shows no blinking cursor and
    /// the sublayer hides.
    surface: ?*IOSurface = null,
    /// Where it goes, in pixels from the contents' top-left corner.
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// A new value restarts the blink in its shown phase (a key press).
    epoch: u64 = 0,
    /// One blink, shown then hidden, in seconds.
    period: f64 = 1.2,
};

/// The animation key of the cursor sublayer's blink.
const cursor_blink_key = "ghosttyCursorBlink";

/// Shows `cursor` on the cursor sublayer, or hides it. Main thread, or
/// inside an explicit transaction under the Core Animation lock (as
/// `setSurfaceOffMain`).
fn applyCursor(layer: objc.Object, cursor: Cursor) void {
    const existing = cursorSublayer(layer);
    if (cursor.surface == null and existing == null) return;

    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const key = nsString(cursor_blink_key);

    const surface = cursor.surface orelse {
        const sub = existing.?;
        sub.msgSend(void, objc.sel("removeAnimationForKey:"), .{key.value});
        sub.setProperty("contents", @as(?*anyopaque, null));
        sub.setProperty("hidden", true);
        return;
    };
    const sub = existing orelse createCursorSublayer(layer) orelse return;

    // The contents sit at the layer's top-left corner (contentsGravity):
    // the cursor goes there too, whichever way the layer's y axis points,
    // and stays there when the bounds change before the next frame.
    const scale = layer.getProperty(f64, "contentsScale");
    if (!(scale > 0)) return;
    const bounds = layer.getProperty(macos.graphics.Rect, "bounds");
    const placed = cursorpkg.layerFrame(
        .{ .x = cursor.x, .y = cursor.y, .width = cursor.width, .height = cursor.height },
        scale,
        .{
            .x = bounds.origin.x,
            .y = bounds.origin.y,
            .width = bounds.size.width,
            .height = bounds.size.height,
        },
        layer.msgSend(bool, objc.sel("isGeometryFlipped"), .{}),
    );
    sub.setProperty("contentsScale", scale);
    sub.setProperty("autoresizingMask", @as(c_uint, placed.autoresizing_mask));
    sub.setProperty("frame", macos.graphics.Rect{
        .origin = .{ .x = placed.x, .y = placed.y },
        .size = .{ .width = placed.width, .height = placed.height },
    });
    sub.setProperty("contents", surface);
    sub.setProperty("hidden", false);

    // A running blink keeps its phase across frames; a new epoch (a key
    // press) or a cursor that was hidden starts it again, shown.
    const running = sub.msgSend(?*anyopaque, objc.sel("animationForKey:"), .{key.value}) != null;
    if (running and cursorEpoch(layer) == cursor.epoch) return;
    setCursorEpoch(layer, cursor.epoch);
    sub.msgSend(void, objc.sel("removeAnimationForKey:"), .{key.value});
    sub.msgSend(void, objc.sel("addAnimation:forKey:"), .{ blinkAnimation(cursor.period).value, key.value });
}

/// Opacity 1 for the first half of `period`, 0 for the second, forever
/// (discrete keyframes: no fade, as Ghostty's own blink).
fn blinkAnimation(period: f64) objc.Object {
    const CAKeyframeAnimation = objc.getClass("CAKeyframeAnimation").?;
    const animation = CAKeyframeAnimation.msgSend(
        objc.Object,
        objc.sel("animationWithKeyPath:"),
        .{nsString("opacity").value},
    );
    animation.setProperty("values", nsArray(&.{ nsNumber(1), nsNumber(0) }));
    animation.setProperty("keyTimes", nsArray(&.{ nsNumber(0), nsNumber(0.5), nsNumber(1) }));
    animation.setProperty("calculationMode", macos.animation.kCAAnimationDiscrete);
    animation.setProperty("duration", period);
    animation.setProperty("repeatCount", std.math.inf(f32));
    animation.setProperty("removedOnCompletion", false);
    return animation;
}

/// Autoreleased; callers hold a pool.
fn nsString(comptime value: [:0]const u8) objc.Object {
    const NSString = objc.getClass("NSString").?;
    return NSString.msgSend(objc.Object, objc.sel("stringWithUTF8String:"), .{value.ptr});
}

/// Autoreleased; callers hold a pool.
fn nsNumber(value: f64) objc.c.id {
    const NSNumber = objc.getClass("NSNumber").?;
    return NSNumber.msgSend(objc.c.id, objc.sel("numberWithDouble:"), .{value});
}

/// Autoreleased; callers hold a pool.
fn nsArray(items: []const objc.c.id) objc.Object {
    const NSArray = objc.getClass("NSArray").?;
    return NSArray.msgSend(objc.Object, objc.sel("arrayWithObjects:count:"), .{
        items.ptr,
        @as(c_ulong, items.len),
    });
}

/// The cursor sublayer, once `createCursorSublayer` made it. Its superlayer
/// retains it; the ivar does not.
fn cursorSublayer(layer: objc.Object) ?objc.Object {
    const value = layer.getInstanceVariable("cursor_layer").value orelse return null;
    return objc.Object.fromId(value);
}

fn createCursorSublayer(layer: objc.Object) ?objc.Object {
    // The same subclass: no display callback (its ivars are nil), and no
    // implicit animations, so moving or hiding it never fades.
    const class = getSubclass() catch return null;
    const sub = class.msgSend(objc.Object, objc.sel("new"), .{});
    defer sub.release();
    sub.setProperty("contentsGravity", macos.animation.kCAGravityTopLeft);
    sub.setProperty("hidden", true);
    layer.msgSend(void, objc.sel("addSublayer:"), .{sub.value});
    layer.setInstanceVariable("cursor_layer", sub);
    return sub;
}

/// The `Cursor.epoch` of the running blink. Stored shifted like
/// `setHostSize`: the object-typed ivar holds an 8-aligned value, never
/// retained.
fn cursorEpoch(layer: objc.Object) u64 {
    return @as(u64, @intFromPtr(layer.getInstanceVariable("cursor_epoch").value)) >> 3;
}

fn setCursorEpoch(layer: objc.Object, epoch: u64) void {
    const stored: usize = @truncate(epoch << 3);
    layer.setInstanceVariable("cursor_epoch", .{ .value = @ptrFromInt(stored) });
}

/// Sets the layer's `contents` to the provided IOSurface, and `cursor` on
/// the cursor sublayer.
///
/// Makes sure to do so on the main thread to avoid visual artifacts.
pub inline fn setSurface(self: *IOSurfaceLayer, surface: *IOSurface, cursor: Cursor, seq: u64) !void {
    // We retain the surface to make sure it's not GC'd
    // before we can set it as the contents of the layer.
    //
    // We release in the callback after setting the contents.
    surface.retain();
    if (cursor.surface) |cursor_surface| cursor_surface.retain();
    // NOTE: Since `self.layer` is passed as an `objc.c.id`, it's
    //       automatically retained when the block is copied, so we
    //       don't need to retain it ourselves like with the surface.

    var block = SetSurfaceBlock.init(.{
        .layer = self.layer.value,
        .surface = surface,
        .cursor = cursor,
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

/// Sets the layer's `contents` to the provided IOSurface, and `cursor`, the
/// frame's blinking cursor, on the cursor sublayer: a frame and its cursor
/// go in the same Core Animation transaction.
///
/// Does not ensure this happens on the main thread.
pub inline fn setFrameSync(self: *IOSurfaceLayer, surface: *IOSurface, cursor: Cursor) void {
    self.layer.setProperty("contents", surface);
    applyCursor(self.layer, cursor);
}

const SetSurfaceBlock = objc.Block(struct {
    layer: objc.c.id,
    surface: *IOSurface,
    cursor: Cursor,
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
pub fn setSurfaceOffMain(self: *IOSurfaceLayer, surface: *IOSurface, cursor: Cursor, seq: u64) bool {
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
    setPresentSeq(self.layer, seq);
    self.layer.setProperty("contents", surface);
    applyCursor(self.layer, cursor);
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
    defer if (block.cursor.surface) |cursor_surface| cursor_surface.release();

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
    if (block.seq != 0) setPresentSeq(layer, block.seq);
    layer.setProperty("contents", surface);
    applyCursor(layer, block.cursor);
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
    if (!subclass.addIvar("cursor_layer")) return error.ObjCFailed;
    if (!subclass.addIvar("cursor_epoch")) return error.ObjCFailed;

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
