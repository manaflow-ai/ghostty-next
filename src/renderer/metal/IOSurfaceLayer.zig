//! The surface's root layer: a CALayer whose `contents` the main thread
//! sets to an IOSurface for a frame it presents itself (a synchronous draw
//! or the resize pre-commit), and whose `display` pass calls the renderer.
//! Every method runs on the main thread; the renderer's own frames go to
//! the drawable overlay above it (`DrawablePresenter`).
const IOSurfaceLayer = @This();

const std = @import("std");
const objc = @import("objc");
const macos = @import("macos");

const IOSurface = macos.iosurface.IOSurface;

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
/// the callback, the contents, and remove it from its superlayer. Main
/// thread: the surface is freed there (`ghostty_surface_free`), and Core
/// Animation calls the display callback only in main-thread transactions,
/// so nothing calls into the renderer after this returns.
pub fn detachFromHostIfDisplayCallbackOwned(
    self: *IOSurfaceLayer,
    display_cb: DisplayCallback,
    display_ctx: ?*anyopaque,
) void {
    const layer = self.layer;

    // Ownership guard: a layer rebound to another renderer stays as it is.
    const cur_cb: ?*anyopaque = @ptrCast(layer.getInstanceVariable("display_cb").value);
    const cur_ctx: ?*anyopaque = @ptrCast(layer.getInstanceVariable("display_ctx").value);
    const own_cb: ?*anyopaque = @ptrCast(@constCast(display_cb));
    if (cur_cb != own_cb or cur_ctx != display_ctx) return;

    layer.setInstanceVariable("display_cb", .{ .value = null });
    layer.setInstanceVariable("display_ctx", .{ .value = null });
    layer.setProperty("contents", @as(?*anyopaque, null));
    layer.msgSend(void, objc.sel("removeFromSuperlayer"), .{});
}

/// Sets the layer's `contents` (null clears them) in the caller's Core
/// Animation transaction. Main thread: the layer belongs to the embedder's
/// view, and the renderer never writes it.
pub fn setContents(self: *IOSurfaceLayer, surface: ?*IOSurface) void {
    self.layer.setProperty("contents", surface);
}

/// The IOSurface in `contents`, or null. Main thread.
pub fn contentsSurface(self: *const IOSurfaceLayer) ?*IOSurface {
    const contents = self.layer.getProperty(?*anyopaque, "contents") orelse return null;
    return @ptrCast(contents);
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
