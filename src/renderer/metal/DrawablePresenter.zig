//! Shows the renderer's frames without the main thread: a `CAMetalLayer`
//! (the overlay, `presentsWithTransaction = false`) above the
//! `IOSurfaceLayer` in the view's tree. The renderer copies each frame into
//! a drawable and presents it with the frame's command buffer; there is no
//! Core Animation transaction and no main-queue turn for a frame. This is
//! form (a) of cmux spike p03-rendering-017 (plans/cmux-next/rendering-DESIGN.md,
//! "Spike 017"), the pattern of cmux `MetalFramePresenter`. Chromium's GPU
//! process presents the same way, on its own thread
//! (gpu/ipc/service/image_transport_surface_overlay_mac.h).
//!
//! Writers (PresentState has the protocol):
//!   * renderer thread: drawables only (`nextDrawable`, `presentDrawable:`),
//!     never while it holds the draw lock;
//!   * main thread: the overlay's `hidden`, `opaque`, `contents`,
//!     `drawableSize`, `frame` and `contentsScale`, and the root layer's
//!     `contents`.
//!
//! Teardown: `Metal` holds its reference to the overlay until `deinit`,
//! which runs after the renderer thread stopped and its frames completed. A
//! present in flight holds its drawable, and the drawable its layer.
const DrawablePresenter = @This();

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc");
const macos = @import("macos");
const graphics = macos.graphics;
const global = @import("../../global.zig");

const mtl = @import("api.zig");
const PresentHistogram = @import("PresentHistogram.zig");
const PresentState = @import("PresentState.zig");
const PresentedSink = @import("PresentedSink.zig");

const log = std.log.scoped(.present_form);

/// The `CAMetalLayer`, a sublayer of the root. Retained.
overlay: objc.Object,

/// The protocol between the three threads.
state: PresentState = .{},

/// The embedder's presented callback. One reference; each drawable's
/// presented handler holds another.
sink: *PresentedSink,

/// The drawable the renderer took for the frame it is drawing
/// (`acquire`, before the draw lock). Retained. Renderer thread only.
pending: ?objc.Object = null,

/// A frame was dropped because its drawable was taken before main changed
/// the size: the renderer draws it again (`takeRedraw`) with a drawable it
/// takes outside the draw lock. Set under the draw lock.
redraw: std.atomic.Value(bool) = .init(false),

stats: Stats = .{},

pub const Stats = struct {
    offmain_presents: std.atomic.Value(u64) = .init(0),
    /// Frames that did not go to a drawable: no drawable, a size other than
    /// the drawable size, or a hidden presentation.
    dropped: std.atomic.Value(u64) = .init(0),
    /// Of `dropped`: the drawable was taken before main changed the size.
    stale_drawables: std.atomic.Value(u64) = .init(0),
    main_presents: std.atomic.Value(u64) = .init(0),
    reveals: std.atomic.Value(u64) = .init(0),
    /// The renderer thread's wait in `nextDrawable`.
    wait: PresentHistogram = .{},
};

/// Creates the overlay as a hidden sublayer of `root`. Main thread.
pub fn init(
    root: objc.Object,
    device: objc.Object,
    pixel_format: mtl.MTLPixelFormat,
    scale: f64,
    is_opaque: bool,
    sink: *PresentedSink,
) !DrawablePresenter {
    const CAMetalLayer = objc.getClass("CAMetalLayer") orelse return error.ObjCFailed;
    const layer = CAMetalLayer.msgSend(objc.Object, objc.sel("layer"), .{}).retain();
    errdefer layer.release();
    layer.setProperty("device", device);
    // The swap chain's format: the copy needs equal formats.
    layer.setProperty("pixelFormat", @intFromEnum(pixel_format));
    // The drawable is a blit destination.
    layer.setProperty("framebufferOnly", false);
    layer.setProperty("presentsWithTransaction", false);
    layer.setProperty("maximumDrawableCount", @as(c_ulong, 3));
    // A CAMetalLayer is opaque by default; a translucent background needs
    // the frame's alpha (`opaqueOverlay`).
    layer.setProperty("opaque", is_opaque);
    if (layer.msgSend(bool, objc.sel("respondsToSelector:"), .{objc.sel("setColorspace:")})) {
        // The swap chain's IOSurfaces are Display P3 (Target.init).
        const colorspace = try graphics.ColorSpace.createNamed(.displayP3);
        defer colorspace.release();
        layer.setProperty("colorspace", colorspace);
    }
    layer.setProperty("actions", try noActions());
    // A frame keeps its pixel size from the top-left corner, as the root's
    // contents do, while a resize waits for the frame of the new size.
    layer.setProperty("contentsGravity", macos.animation.kCAGravityTopLeft);
    layer.setProperty("contentsScale", scale);
    layer.setProperty("anchorPoint", graphics.Point{ .x = 0, .y = 0 });
    layer.setProperty("frame", root.getProperty(graphics.Rect, "bounds"));
    if (comptime builtin.os.tag == .macos) {
        // kCALayerWidthSizable | kCALayerHeightSizable (macOS only).
        layer.setProperty("autoresizingMask", @as(c_uint, 2 | 16));
    }
    layer.setProperty("hidden", true);
    root.msgSend(void, objc.sel("addSublayer:"), .{layer});
    return .{ .overlay = layer, .sink = sink.retain() };
}

/// After the renderer thread stopped and its frames completed. Main thread.
/// No presented callback runs once this returns.
pub fn deinit(self: *DrawablePresenter) void {
    const s = &self.stats;
    // scripts/cmux-next/ghostty-present-form-bench.py reads this line.
    log.info(
        "present form metal_layer: offmain={d} refused={d} stale_drawables={d} main_hops=0 main_presents={d} " ++
            "reveals={d} wait_n={d} wait_sum_ns={d} wait_max_ns={d} wait_buckets_us={any}",
        .{
            s.offmain_presents.load(.monotonic),
            s.dropped.load(.monotonic),
            s.stale_drawables.load(.monotonic),
            s.main_presents.load(.monotonic),
            s.reveals.load(.monotonic),
            s.wait.count.load(.monotonic),
            s.wait.sum_ns.load(.monotonic),
            s.wait.max_ns.load(.monotonic),
            s.wait.snapshot(),
        },
    );
    if (self.pending) |d| d.release();
    self.pending = null;
    self.sink.close();
    self.sink.release();
    // The view's tree may still hold the overlay; only our reference goes.
    self.overlay.release();
}

// ---------------------------------------------------------------- main thread

/// The drawables' pixel size (packed, not 0). Main thread.
pub fn setDrawableSize(self: *DrawablePresenter, size: u64) void {
    if (size == 0 or self.state.drawable_size.load(.acquire) == size) return;
    self.overlay.setProperty("drawableSize", graphics.Size{
        .width = @floatFromInt(PresentState.packedWidth(size)),
        .height = @floatFromInt(PresentState.packedHeight(size)),
    });
    self.state.drawable_size.store(size, .release);
}

/// A purged presentation: the renderer takes no drawable until main sets a
/// size again, the drawable on the overlay goes, and the layer's drawables
/// shrink to one pixel so their memory goes. Main thread.
pub fn purgeDrawables(self: *DrawablePresenter) void {
    self.state.drawable_size.store(0, .release);
    self.overlay.setProperty("contents", @as(?*anyopaque, null));
    self.overlay.setProperty("drawableSize", graphics.Size{ .width = 1, .height = 1 });
}

/// Whether the overlay is opaque (`PresentState.opaqueOverlay`), in its own
/// transaction: Core Animation otherwise applies a change to `opaque` only
/// at the next resize. Main thread.
pub fn setOpaque(self: *DrawablePresenter, is_opaque: bool) void {
    if (self.overlay.getProperty(bool, "opaque") == is_opaque) return;
    const CATransaction = objc.getClass("CATransaction") orelse return;
    CATransaction.msgSend(void, objc.sel("begin"), .{});
    defer CATransaction.msgSend(void, objc.sel("commit"), .{});
    self.overlay.setProperty("opaque", is_opaque);
}

/// Places the overlay on the root's bounds at its scale. Main thread.
pub fn syncGeometry(self: *DrawablePresenter, root: objc.Object) void {
    self.overlay.setProperty("frame", root.getProperty(graphics.Rect, "bounds"));
    self.overlay.setProperty("contentsScale", root.getProperty(f64, "contentsScale"));
}

/// Main presented a frame as the root's contents in its transaction: the
/// overlay hides in the same transaction until the renderer's next frame.
/// Main thread.
pub fn mainPresented(self: *DrawablePresenter, root: objc.Object, size: u64) void {
    _ = self.stats.main_presents.fetchAdd(1, .monotonic);
    self.syncGeometry(root);
    self.setDrawableSize(size);
    self.hideOverlay();
}

/// Hides the overlay and starts a new hide generation. Main thread.
pub fn hideOverlay(self: *DrawablePresenter) void {
    _ = self.state.hide();
    self.overlay.setProperty("hidden", true);
}

/// The renderer asked to show the overlay (an app mailbox message): shows
/// it if its frame is newer than main's last present, and clears the
/// root's contents (the overlay covers them). Main thread.
pub fn reveal(self: *DrawablePresenter, root: objc.Object) void {
    if (!self.state.takeReveal()) return;
    _ = self.stats.reveals.fetchAdd(1, .monotonic);
    self.overlay.setProperty("hidden", false);
    root.setProperty("contents", @as(?*anyopaque, null));
}

/// The pixel size of the frame on screen, packed; 0 before the first.
/// Main thread.
pub fn shownSize(self: *const DrawablePresenter, root: objc.Object) u64 {
    if (self.state.overlayShown()) return self.state.shown_size.load(.acquire);
    const contents = root.getProperty(?*anyopaque, "contents") orelse return 0;
    const surface: *macos.iosurface.IOSurface = @ptrCast(contents);
    return PresentState.pack(surface.getWidth(), surface.getHeight());
}

// ---------------------------------------------------------------- renderer

/// Renderer thread, before it takes the draw lock: takes the drawable for
/// the next frame, so a wait for one never holds the lock that a main
/// thread draw takes. A drawable of a size main has since replaced goes
/// back, and one of the new size is taken, still outside the lock.
pub fn acquire(self: *DrawablePresenter) void {
    if (!self.state.presenting.load(.acquire)) return self.releaseUnused();
    if (self.pending) |held| {
        if (drawableSize(held) == self.state.drawable_size.load(.acquire)) return;
        self.releaseUnused();
    }
    if (self.state.drawable_size.load(.acquire) == 0) return;
    const d = self.nextDrawable() orelse return;
    if (drawableSize(d) == self.state.drawable_size.load(.acquire)) {
        self.pending = d;
        return;
    }
    // Main set a new size while this thread waited for the drawable.
    d.release();
    self.pending = self.nextDrawable();
}

/// Under the draw lock: whether the last frame was dropped for a drawable
/// of an old size, so this frame must draw even with nothing changed.
/// Clears the request.
pub fn takeRedraw(self: *DrawablePresenter) bool {
    return self.redraw.swap(false, .acq_rel);
}

/// Renderer thread, after the draw lock is released: a frame was dropped
/// for a drawable of an old size and is not drawn again yet.
pub fn redrawPending(self: *const DrawablePresenter) bool {
    return self.redraw.load(.acquire);
}

/// Renderer thread, after the draw lock is released: a drawable the frame
/// did not use goes back to the layer.
pub fn releaseUnused(self: *DrawablePresenter) void {
    const d = self.pending orelse return;
    self.pending = null;
    d.release();
}

fn nextDrawable(self: *DrawablePresenter) ?objc.Object {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const io = global.io();
    const start: std.Io.Timestamp = .now(io, .awake);
    const id = self.overlay.msgSend(?*anyopaque, objc.sel("nextDrawable"), .{});
    const waited = start.durationTo(.now(io, .awake)).nanoseconds;
    self.stats.wait.record(@intCast(@max(0, waited)));
    return objc.Object.fromId(id orelse return null).retain();
}

/// Renderer thread, before the frame's command buffer commits: copies
/// `texture` (`width` x `height`) into the pending drawable and encodes its
/// present, when the sizes match the drawable size.
pub fn encode(
    self: *DrawablePresenter,
    buffer: objc.Object,
    texture: objc.Object,
    width: usize,
    height: usize,
) PresentState.Ticket {
    var ticket = self.state.begin();
    // A frame of another size than the drawables is dropped.
    if (!self.state.accepts(width, height, width, height)) return self.drop(ticket);
    // None taken before the lock (no size yet, a hidden presentation, or
    // nextDrawable timed out): never wait for one under the lock.
    const drawable = self.pending orelse return self.drop(ticket);
    self.pending = null;
    defer drawable.release();
    const size = PresentState.pack(width, height);
    if (drawableSize(drawable) != size) {
        // Taken before main set the new size (a resize): this frame is the
        // first of that size. Never take another under the lock: the
        // renderer draws it again once the lock is released (`takeRedraw`).
        _ = self.stats.stale_drawables.fetchAdd(1, .monotonic);
        self.redraw.store(true, .release);
        return self.drop(ticket);
    }
    const target = drawable.getProperty(objc.Object, "texture");

    const blit = buffer.msgSend(objc.Object, objc.sel("blitCommandEncoder"), .{});
    blit.msgSend(void, objc.sel("copyFromTexture:toTexture:"), .{ texture, target });
    blit.msgSend(void, objc.sel("endEncoding"), .{});

    var handler = PresentedBlock.init(.{
        .sink = self.sink.retain(),
        .frame_id = ticket.sequence,
        .generation = ticket.generation,
        .size = size,
    }, &presentedCallback);
    drawable.msgSend(void, objc.sel("addPresentedHandler:"), .{&handler});
    buffer.msgSend(void, objc.sel("presentDrawable:"), .{drawable});
    ticket.encoded = true;
    return ticket;
}

fn drop(self: *DrawablePresenter, ticket: PresentState.Ticket) PresentState.Ticket {
    _ = self.stats.dropped.fetchAdd(1, .monotonic);
    return ticket;
}

/// The drawable's pixel size, packed.
fn drawableSize(drawable: objc.Object) u64 {
    const texture = drawable.getProperty(objc.Object, "texture");
    return PresentState.pack(
        @intCast(texture.getProperty(c_ulong, "width")),
        @intCast(texture.getProperty(c_ulong, "height")),
    );
}

/// A drawable's presented handler (the sink's observer, so never after
/// `deinit`): the drawable is on the overlay, or a newer one replaced it.
/// True when the renderer must ask main to show the overlay; every drawable
/// older than this one is past, so the overlay cannot show one of them after
/// main's reveal.
pub fn presented(self: *DrawablePresenter, p: PresentedSink.Presented) bool {
    const shown = p.presented_time > 0;
    if (shown) _ = self.stats.offmain_presents.fetchAdd(1, .monotonic);
    return self.state.presented(
        .{ .sequence = p.frame_id, .generation = p.generation, .encoded = true },
        p.size,
        shown,
    );
}

const PresentedBlock = objc.Block(struct {
    sink: *PresentedSink,
    frame_id: u64,
    generation: u64,
    size: u64,
}, .{
    objc.c.id, // id<MTLDrawable>
}, void);

/// Core Animation calls this once for each drawable, on its own thread,
/// possibly after the surface is freed (the sink's reference keeps it).
fn presentedCallback(block: *const PresentedBlock.Context, drawable_id: objc.c.id) callconv(.c) void {
    const sink = block.sink;
    defer sink.release();
    sink.deliver(.{
        .frame_id = block.frame_id,
        .generation = block.generation,
        .size = block.size,
        .host_time = mach_absolute_time(),
        .presented_time = objc.Object.fromId(drawable_id).getProperty(f64, "presentedTime"),
    });
}

/// An `actions` dictionary with no animation for the keys main changes.
fn noActions() !objc.Object {
    const NSMutableDictionary = objc.getClass("NSMutableDictionary") orelse return error.ObjCFailed;
    const NSString = objc.getClass("NSString") orelse return error.ObjCFailed;
    const NSNull = objc.getClass("NSNull") orelse return error.ObjCFailed;
    const none = NSNull.msgSend(objc.Object, objc.sel("null"), .{});
    const dict = NSMutableDictionary.msgSend(objc.Object, objc.sel("dictionary"), .{});
    const keys = [_][:0]const u8{
        "bounds",        "position",    "frame",     "hidden",    "contents",
        "contentsScale", "anchorPoint", "sublayers", "onOrderIn", "onOrderOut",
        "opaque",
    };
    for (keys) |key| {
        const name = NSString.msgSend(objc.Object, objc.sel("stringWithUTF8String:"), .{key.ptr});
        dict.msgSend(void, objc.sel("setObject:forKey:"), .{ none, name });
    }
    return dict;
}

extern "c" fn mach_absolute_time() u64;
