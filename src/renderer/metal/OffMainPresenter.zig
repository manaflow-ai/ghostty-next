//! The two off-main present forms of the cmux present-form spike
//! (`macos-present-form`; cmux plans/cmux-next/rendering-DESIGN.md,
//! "Spike 017"). macOS only.
//!
//! Both put one "overlay" layer above the `IOSurfaceLayer` in the view's
//! layer tree. The renderer shows its frames in the overlay without the
//! main thread and without a Core Animation transaction into a layer that
//! the view's tree owns:
//!
//!   * `metal_layer`: the overlay is a `CAMetalLayer` with
//!     `presentsWithTransaction = false`. The renderer copies each frame into
//!     a drawable and presents it with the command buffer
//!     (`presentDrawable:`), as cmux's `MetalFramePresenter` does.
//!   * `layer_host`: the renderer owns a `CAContext` and its root layer. Each
//!     frame is set as that layer's contents in a transaction that the
//!     renderer commits for its own context; the overlay is a `CALayerHost`
//!     of that context. This is Chrome's GPU form
//!     (`gpu/ipc/service/image_transport_surface_overlay_mac.h` commits the
//!     GPU process's own context; `ui/accelerated_widget_mac/
//!     display_ca_layer_tree.h` hosts it with a `CALayerHost` under a
//!     flipped layer).
//!
//! One writer for each layer: the renderer writes only drawables (form a) or
//! its own context (form b); the main thread writes the view's tree, the
//! overlay's `hidden` and `drawableSize` included. A frame for a new size is
//! still presented by the main thread in its own transaction (the resize
//! pre-commit, `Metal.presentHostSized`) as the `IOSurfaceLayer`'s contents;
//! that hides the overlay and starts a new overlay generation. The
//! renderer's first frame that it encoded after the hide posts one reveal of
//! that generation to the main thread, which shows the overlay again and
//! clears the root contents. An older generation's reveal does nothing, so
//! the overlay never comes back with a frame older than the one that the
//! main thread presented.
const OffMainPresenter = @This();

const std = @import("std");
const objc = @import("objc");
const macos = @import("macos");
const graphics = macos.graphics;
const IOSurface = macos.iosurface.IOSurface;
const global = @import("../../global.zig");

const mtl = @import("api.zig");
const IOSurfaceLayer = @import("IOSurfaceLayer.zig");
const PresentHistogram = @import("PresentHistogram.zig");

const log = std.log.scoped(.present_form);

pub const Form = enum { metal_layer, layer_host };

form: Form,

/// The overlay in the view's tree: the `CAMetalLayer` (form a) or the
/// flipped layer that holds the `CALayerHost` (form b). Retained until
/// `deinit`, after the renderer stopped. Main thread writes only.
overlay: objc.Object,

/// Form b: the `CALayerHost` inside `overlay`, the renderer's context and
/// that context's root layer (renderer writes only). Retained.
host: ?objc.Object = null,
context: ?objc.Object = null,
content: ?objc.Object = null,

/// The pixel size (width << 32 | height) of the frames the overlay takes:
/// the size of the main thread's last present or the host size it set.
/// Form a: the `drawableSize` the main thread last set. Main writes, the
/// renderer reads. 0: no off-main present yet.
accept_size: std.atomic.Value(u64) = .init(0),

/// The overlay layer's `contentsScale` (f64 bits), for form b's content
/// layer. Main writes, the renderer reads.
scale_bits: std.atomic.Value(u64) = .init(0),

/// The pixel size of the last frame that the renderer showed off main; 0
/// before the first. Renderer writes, the main thread reads.
shown_size: std.atomic.Value(u64) = .init(0),

/// The overlay generation: bumped by each main present (the overlay is then
/// hidden). Main writes, the renderer reads it when it encodes a frame.
generation: std.atomic.Value(u64) = .init(1),

/// The last generation that the renderer posted a reveal for. GPU
/// completion thread.
revealed: std.atomic.Value(u64) = .init(0),

stats: Stats = .{},

pub const Stats = struct {
    offmain_presents: std.atomic.Value(u64) = .init(0),
    /// Frames that could not be shown off main (no drawable, or a frame of a
    /// size the overlay does not take); they took the main-queue path.
    refused: std.atomic.Value(u64) = .init(0),
    main_presents: std.atomic.Value(u64) = .init(0),
    reveals: std.atomic.Value(u64) = .init(0),
    /// Form a: the renderer thread's wait in `nextDrawable` (it runs under
    /// the renderer's draw mutex). Form b: the renderer's transaction commit.
    wait: PresentHistogram = .{},
};

/// What the renderer read when it encoded a frame: the overlay generation
/// and whether the frame's drawable present is already encoded (form a).
pub const Ticket = extern struct {
    generation: u64 = 0,
    encoded: bool = false,
};

pub fn pack(width: usize, height: usize) u64 {
    return (@as(u64, @intCast(width)) << 32) | @as(u64, @intCast(height));
}

/// Creates the overlay as a hidden sublayer of `root` (the view's
/// `IOSurfaceLayer`). Main thread, when the surface is created.
pub fn init(
    form: Form,
    root: objc.Object,
    device: objc.Object,
    pixel_format: mtl.MTLPixelFormat,
    scale: f64,
) !OffMainPresenter {
    const actions = try noActions();
    var self: OffMainPresenter = switch (form) {
        .metal_layer => metal: {
            const CAMetalLayer = objc.getClass("CAMetalLayer") orelse return error.ObjCFailed;
            const layer = CAMetalLayer.msgSend(objc.Object, objc.sel("layer"), .{}).retain();
            errdefer layer.release();
            layer.setProperty("device", device);
            layer.setProperty("pixelFormat", @intFromEnum(pixel_format));
            // The drawable is a blit destination (the frame is copied into it).
            layer.setProperty("framebufferOnly", false);
            layer.setProperty("presentsWithTransaction", false);
            layer.setProperty("maximumDrawableCount", @as(c_ulong, 3));
            const colorspace = try graphics.ColorSpace.createNamed(.displayP3);
            defer colorspace.release();
            layer.setProperty("colorspace", colorspace);
            break :metal .{ .form = form, .overlay = layer };
        },
        .layer_host => host: {
            const CALayer = objc.getClass("CALayer") orelse return error.ObjCFailed;
            const CAContext = objc.getClass("CAContext") orelse return error.ObjCFailed;
            const CALayerHost = objc.getClass("CALayerHost") orelse return error.ObjCFailed;
            const NSDictionary = objc.getClass("NSDictionary") orelse return error.ObjCFailed;

            const content = CALayer.msgSend(objc.Object, objc.sel("layer"), .{}).retain();
            errdefer content.release();
            content.setProperty("anchorPoint", graphics.Point{ .x = 0, .y = 0 });
            content.setProperty("position", graphics.Point{ .x = 0, .y = 0 });
            content.setProperty("contentsGravity", macos.animation.kCAGravityTopLeft);
            content.setProperty("actions", actions);

            const options = NSDictionary.msgSend(objc.Object, objc.sel("dictionary"), .{});
            const context_id = CAContext.msgSend(
                ?*anyopaque,
                objc.sel("contextWithCGSConnection:options:"),
                .{ CGSMainConnectionID(), options },
            ) orelse return error.ObjCFailed;
            const context = objc.Object.fromId(context_id).retain();
            errdefer context.release();
            context.setProperty("layer", content);

            const host = CALayerHost.msgSend(objc.Object, objc.sel("layer"), .{}).retain();
            errdefer host.release();
            host.setProperty("contextId", context.getProperty(u32, "contextId"));
            host.setProperty("anchorPoint", graphics.Point{ .x = 0, .y = 0 });
            host.setProperty("position", graphics.Point{ .x = 0, .y = 0 });
            host.setProperty("actions", actions);

            // The content layer is placed from the top-left corner, as the
            // IOSurfaceLayer's contents are (Chrome's flipped layer).
            const flipped = CALayer.msgSend(objc.Object, objc.sel("layer"), .{}).retain();
            flipped.setProperty("geometryFlipped", true);
            flipped.msgSend(void, objc.sel("addSublayer:"), .{host});
            break :host .{ .form = form, .overlay = flipped, .host = host, .context = context, .content = content };
        },
    };

    const overlay = self.overlay;
    overlay.setProperty("actions", actions);
    overlay.setProperty("contentsGravity", macos.animation.kCAGravityTopLeft);
    overlay.setProperty("contentsScale", scale);
    overlay.setProperty("anchorPoint", graphics.Point{ .x = 0, .y = 0 });
    overlay.setProperty("frame", root.getProperty(graphics.Rect, "bounds"));
    // kCALayerWidthSizable | kCALayerHeightSizable: the overlay follows the
    // root's bounds; a frame keeps its pixel size from the top-left corner.
    overlay.setProperty("autoresizingMask", @as(c_uint, 2 | 16));
    overlay.setProperty("hidden", true);
    root.msgSend(void, objc.sel("addSublayer:"), .{overlay});
    self.scale_bits.store(@bitCast(scale), .release);
    IOSurfaceLayer.setOverlayGeneration(root, self.generation.load(.acquire));
    return self;
}

/// After the renderer stopped and its frames completed (`Metal.deinit`).
/// Logs the spike's counters for the bench
/// (scripts/cmux-next/ghostty-present-form-bench.py reads this line).
pub fn deinit(self: *OffMainPresenter, main_hops: u64) void {
    const s = &self.stats;
    log.info(
        "present form {s}: offmain={d} refused={d} main_hops={d} main_presents={d} reveals={d} " ++
            "wait_n={d} wait_sum_ns={d} wait_max_ns={d} wait_buckets_us={any}",
        .{
            @tagName(self.form),
            s.offmain_presents.load(.monotonic),
            s.refused.load(.monotonic),
            main_hops,
            s.main_presents.load(.monotonic),
            s.reveals.load(.monotonic),
            s.wait.count.load(.monotonic),
            s.wait.sum_ns.load(.monotonic),
            s.wait.max_ns.load(.monotonic),
            s.wait.snapshot(),
        },
    );
    if (self.content) |c| c.release();
    if (self.context) |c| c.release();
    if (self.host) |h| h.release();
    // The view's tree may still hold the overlay; only our reference goes.
    self.overlay.release();
}

/// The same log line for the `main-contents` form (no overlay), at the
/// renderer's teardown.
pub fn logMainContents(main_hops: u64) void {
    log.info("present form main_contents: main_hops={d}", .{main_hops});
}

// ---------------------------------------------------------------- main thread

/// The host set a new target size (`Metal.setHostDrawableSize`, packed, not
/// 0): frames of that size go to the overlay from now on. Main thread.
pub fn setAcceptSize(self: *OffMainPresenter, size: u64) void {
    if (self.accept_size.swap(size, .acq_rel) == size) return;
    if (self.form == .metal_layer) self.overlay.setProperty("drawableSize", graphics.Size{
        .width = @floatFromInt(size >> 32),
        .height = @floatFromInt(size & 0xffff_ffff),
    });
}

/// The main thread set a frame of `width` x `height` as the root's contents
/// in its transaction (a synchronous draw or the resize pre-commit): the
/// overlay hides in the same transaction and waits for the renderer's
/// next frame. Main thread.
pub fn mainPresented(self: *OffMainPresenter, root: objc.Object, width: usize, height: usize) void {
    _ = self.stats.main_presents.fetchAdd(1, .monotonic);
    self.setAcceptSize(pack(width, height));
    self.scale_bits.store(@bitCast(root.getProperty(f64, "contentsScale")), .release);
    self.overlay.setProperty("contentsScale", root.getProperty(f64, "contentsScale"));
    self.overlay.setProperty("hidden", true);
    const generation = self.generation.fetchAdd(1, .acq_rel) + 1;
    IOSurfaceLayer.setOverlayGeneration(root, generation);
}

/// The pixel size of the frame on screen: the overlay's last frame while
/// the overlay shows, else the root's contents; 0 when nothing was
/// presented yet. Main thread.
pub fn shownSize(self: *const OffMainPresenter, root: objc.Object) u64 {
    if (!self.overlay.getProperty(bool, "hidden")) return self.shown_size.load(.acquire);
    const contents = root.getProperty(?*anyopaque, "contents") orelse return 0;
    const surface: *IOSurface = @ptrCast(contents);
    return pack(surface.getWidth(), surface.getHeight());
}

// ---------------------------------------------------------------- renderer

/// Renderer thread, before the frame's command buffer commits (Frame.complete):
/// form a copies `texture` (`width` x `height`) into a drawable and encodes
/// its present. Both forms read the overlay generation here, so a reveal is
/// posted only for a frame encoded after the main thread's last hide.
pub fn encode(
    self: *OffMainPresenter,
    buffer: objc.Object,
    texture: objc.Object,
    width: usize,
    height: usize,
) Ticket {
    var ticket: Ticket = .{ .generation = self.generation.load(.acquire) };
    if (self.form != .metal_layer) return ticket;
    if (self.accept_size.load(.acquire) != pack(width, height)) return ticket;

    const io = global.io();
    const start: std.Io.Timestamp = .now(io, .awake);
    // Autoreleased: the renderer's frame autorelease pool holds it, and
    // `presentDrawable:` retains it until it is shown.
    const drawable_id = self.overlay.msgSend(?*anyopaque, objc.sel("nextDrawable"), .{});
    const waited = start.durationTo(.now(io, .awake)).nanoseconds;
    self.stats.wait.record(@intCast(@max(0, waited)));
    const drawable = objc.Object.fromId(drawable_id orelse return ticket);
    const target = drawable.getProperty(objc.Object, "texture");
    // The main thread can set a new drawableSize between the check above
    // and nextDrawable; a drawable of another size takes no copy.
    if (target.getProperty(c_ulong, "width") != width or
        target.getProperty(c_ulong, "height") != height) return ticket;

    const blit = buffer.msgSend(objc.Object, objc.sel("blitCommandEncoder"), .{});
    blit.msgSend(void, objc.sel("copyFromTexture:toTexture:"), .{ texture, target });
    blit.msgSend(void, objc.sel("endEncoding"), .{});
    buffer.msgSend(void, objc.sel("presentDrawable:"), .{drawable});
    ticket.encoded = true;
    return ticket;
}

/// GPU completion thread, for a frame that completed healthy: shows it off
/// main. False when it could not (the caller takes the main-queue path).
pub fn present(
    self: *OffMainPresenter,
    root: objc.Object,
    surface: *IOSurface,
    ticket: Ticket,
) bool {
    const size = pack(surface.getWidth(), surface.getHeight());
    const shown = switch (self.form) {
        .metal_layer => ticket.encoded,
        .layer_host => self.commitContent(surface, size),
    };
    if (!shown) {
        _ = self.stats.refused.fetchAdd(1, .monotonic);
        return false;
    }
    _ = self.stats.offmain_presents.fetchAdd(1, .monotonic);
    self.shown_size.store(size, .release);
    if (self.revealed.swap(ticket.generation, .acq_rel) != ticket.generation) {
        self.postReveal(root, ticket.generation);
    }
    return true;
}

/// Form b: the frame becomes the content layer's contents in a transaction
/// of the renderer's own context (no layer of the view's tree is in it).
fn commitContent(self: *OffMainPresenter, surface: *IOSurface, size: u64) bool {
    if (self.accept_size.load(.acquire) != size) return false;
    const content = self.content orelse return false;
    const CATransaction = objc.getClass("CATransaction") orelse return false;
    const scale: f64 = @bitCast(self.scale_bits.load(.acquire));
    if (!(scale > 0)) return false;

    const io = global.io();
    const start: std.Io.Timestamp = .now(io, .awake);
    CATransaction.msgSend(void, objc.sel("begin"), .{});
    CATransaction.msgSend(void, objc.sel("setDisableActions:"), .{true});
    content.setProperty("contentsScale", scale);
    content.setProperty("bounds", graphics.Rect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{
            .width = @as(f64, @floatFromInt(surface.getWidth())) / scale,
            .height = @as(f64, @floatFromInt(surface.getHeight())) / scale,
        },
    });
    content.setProperty("contents", surface);
    CATransaction.msgSend(void, objc.sel("commit"), .{});
    const took = start.durationTo(.now(io, .awake)).nanoseconds;
    self.stats.wait.record(@intCast(@max(0, took)));
    return true;
}

const RevealBlock = objc.Block(struct {
    root: objc.c.id,
    overlay: objc.c.id,
    generation: u64,
}, .{}, void);

/// One main-queue turn for each overlay generation, not for each frame.
fn postReveal(self: *OffMainPresenter, root: objc.Object, generation: u64) void {
    _ = self.stats.reveals.fetchAdd(1, .monotonic);
    // The block retains both layers when it is copied; it reads no renderer
    // memory, so it is safe after the renderer is gone.
    var block = RevealBlock.init(.{
        .root = root.value,
        .overlay = self.overlay.value,
        .generation = generation,
    }, &revealCallback);
    macos.dispatch.dispatch_async(
        @ptrCast(macos.dispatch.queue.getMain()),
        @ptrCast(&block),
    );
}

fn revealCallback(block: *const RevealBlock.Context) callconv(.c) void {
    const root = objc.Object.fromId(block.root);
    // A main present after this frame was encoded hid the overlay again; the
    // reveal of that newer generation comes with a newer frame.
    if (IOSurfaceLayer.overlayGeneration(root) != block.generation) return;
    objc.Object.fromId(block.overlay).setProperty("hidden", false);
    root.setProperty("contents", @as(?*anyopaque, null));
}

/// An `actions` dictionary with no animation for the keys these layers change.
fn noActions() !objc.Object {
    const NSMutableDictionary = objc.getClass("NSMutableDictionary") orelse return error.ObjCFailed;
    const NSString = objc.getClass("NSString") orelse return error.ObjCFailed;
    const NSNull = objc.getClass("NSNull") orelse return error.ObjCFailed;
    const none = NSNull.msgSend(objc.Object, objc.sel("null"), .{});
    const dict = NSMutableDictionary.msgSend(objc.Object, objc.sel("dictionary"), .{});
    const keys = [_][:0]const u8{
        "bounds",        "position",    "frame",     "hidden",    "contents",
        "contentsScale", "anchorPoint", "sublayers", "onOrderIn", "onOrderOut",
    };
    for (keys) |key| {
        const name = NSString.msgSend(objc.Object, objc.sel("stringWithUTF8String:"), .{key.ptr});
        dict.msgSend(void, objc.sel("setObject:forKey:"), .{ none, name });
    }
    return dict;
}

extern "c" fn CGSMainConnectionID() c_int;
