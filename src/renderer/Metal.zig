//! Graphics API wrapper for Metal.
pub const Metal = @This();

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const objc = @import("objc");
const macos = @import("macos");
const graphics = macos.graphics;
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(Metal);
const shadertoy = @import("shadertoy.zig");
const global = @import("../global.zig");
const IOSurface = macos.iosurface.IOSurface;

const mtl = @import("metal/api.zig");
const IOSurfaceLayer = @import("metal/IOSurfaceLayer.zig");
pub const Device = @import("metal/Device.zig");

pub const GraphicsAPI = Metal;
pub const Target = @import("metal/Target.zig");
pub const Frame = @import("metal/Frame.zig");
pub const RenderPass = @import("metal/RenderPass.zig");
pub const Pipeline = @import("metal/Pipeline.zig");
const bufferpkg = @import("metal/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("metal/Sampler.zig");
pub const Texture = @import("metal/Texture.zig");
pub const shaders = @import("metal/shaders.zig");

pub const custom_shader_target: shadertoy.Target = .msl;
// The fragCoord for Metal shaders is +Y = down.
pub const custom_shader_y_is_down = true;

/// Triple buffering.
pub const swap_chain_count = 3;

const log = std.log.scoped(.metal);

layer: IOSurfaceLayer,

/// The shared render device.
device: *const Device,

/// MTLCommandQueue
queue: objc.Object,

/// Alpha blending mode
blending: configpkg.Config.AlphaBlending,

/// We start an AutoreleasePool before `drawFrame` and end it afterwards.
autorelease_pool: ?*objc.AutoreleasePool = null,

/// macOS, opt-in (`ghostty_surface_set_host_sized`): the render target's
/// pixel size, packed width << 32 | height, as the embedder last set it
/// with `ghostty_surface_set_size`. 0 follows the layer's bounds (default).
/// Written on the main thread, read by `surfaceSize` on any thread.
host_size: std.atomic.Value(u64) = .init(0),

/// macOS, opt-in (`ghostty_surface_set_host_capacity`): the least pixel size
/// of every render target, packed width << 32 | height, for a gesture whose
/// sizes all fit in it (a held-key resize, a divider drag): each swap-chain
/// target keeps one IOSurface that large and each frame is drawn in its
/// top-left corner at the host size, so a new size allocates nothing
/// (`fitTarget`). 0 (the default): a target has exactly its frame's size.
/// Main thread writes, the renderer thread reads.
host_capacity: std.atomic.Value(u64) = .init(0),

/// A capacity was cleared and the swap chain may still hold targets of its
/// size: the renderer thread gives back the idle ones at its next draw
/// (`Renderer.SwapChain.trim`), and a frame in flight gives back its own when
/// it completes (`frameDone`). Main thread writes it (`setHostCapacity`); the
/// renderer thread clears it once no frame is in flight (`trimDone`).
trim_armed: std.atomic.Value(bool) = .init(false),

/// A capacity was cleared and no frame was drawn since: the renderer thread's
/// next draw draws the landing frame at the host size even when nothing else
/// changed (`takeLandingDue`), so the layer stops showing a capacity surface.
landing_due: std.atomic.Value(bool) = .init(false),

/// macOS host-sized surfaces: the newest frame the renderer thread drew with
/// cells built at that frame's size (`Target.cells_fresh`), for the display
/// pass of a new host size to present in the same Core Animation transaction
/// as the view's new bounds (`presentHostSized`).
fresh: FreshFrame = .{},

/// Whether the renderer draws (its last `setVisible`). Written on the
/// renderer thread, read by the display pass on the main thread: a hidden
/// surface's display pass draws nothing.
visible_hint: std.atomic.Value(bool) = .init(true),

/// The renderer skips frame updates (synchronized output, a restore's
/// frame hold): no fresh frame can come, so a display pass of a new size
/// keeps the last frame at once instead of waiting for one. Renderer
/// thread writes, main thread reads.
frames_held: std.atomic.Value(bool) = .init(false),

/// When the host size last changed (`setHostDrawableSize`). Main thread.
host_size_set_at: ?std.Io.Timestamp = null,

/// macOS host-sized surfaces, opt-in (`ghostty_surface_set_host_present`):
/// the embedder, not the renderer, shows a frame whose size differs from the
/// frame the layer shows, so it can change the view's bounds in the same
/// Core Animation transaction. Main thread writes; the GPU completion thread
/// and the display pass read.
embedder_presents: std.atomic.Value(bool) = .init(false),

/// Numbers presented frames in completion order, so a frame the main thread
/// presents late never replaces a newer one presented off main. GPU
/// completion thread.
present_seq: std.atomic.Value(u64) = .init(0),

/// Frames drawn by the display pass on the main thread (the fallback) and
/// display passes of a new host size that kept the last frame because no
/// fresh frame came within `host_frame_wait_ns` (render counters).
counters: HostFrameCounters = .{},

pub const HostFrameCounters = struct {
    display_passes: std.atomic.Value(u64) = .init(0),
    /// Frames presented from the completion thread (content only, `setSurfaceOffMain`).
    off_main_presents: std.atomic.Value(u64) = .init(0),
    /// `ghostty_surface_present_host_frame` calls and
    /// `ghostty_surface_host_frame` calls that present (the embedder's own
    /// pre-commit hook, for a layer whose display pass does not run).
    present_calls: std.atomic.Value(u64) = .init(0),
    main_draws: std.atomic.Value(u64) = .init(0),
    fresh_presents: std.atomic.Value(u64) = .init(0),
    late: std.atomic.Value(u64) = .init(0),
    /// Frames handed to the main thread's present (`IOSurfaceLayer.setSurface`): from the GPU completion thread, one
    /// block on the main queue each.
    main_presents: std.atomic.Value(u64) = .init(0),
    /// Render targets created (`initTarget`), all causes: a new swap chain, a new frame size, a capacity, a config
    /// change. Each is one IOSurface and one MTLTexture.
    target_allocs: std.atomic.Value(u64) = .init(0),
    /// The bytes of the live targets' IOSurfaces (`Target.live_bytes`), and their peak.
    target_bytes_live: std.atomic.Value(u64) = .init(0),
    target_bytes_peak: std.atomic.Value(u64) = .init(0),
};

const FreshFrame = struct {
    /// Bumped by every host size change; a frame publishes only when the
    /// generation it began drawing under is still current (A->B->A: a late
    /// frame of the first A is not presented for the second).
    generation: std.atomic.Value(u64) = .init(0),
    /// A host size changed and its frame was not taken yet: only then does a
    /// completed frame publish itself (no retain, lock or wake per frame at rest).
    armed: std.atomic.Value(bool) = .init(false),
    mutex: std.Io.Mutex = .init,
    /// Retained; null after a take or before the first fresh frame.
    surface: ?*IOSurface = null,
    /// The pixel size `surface` was drawn at (`IOSurfaceLayer.Drawn`): the
    /// surface is larger while the host sets a capacity.
    width: usize = 0,
    height: usize = 0,
    /// The present sequence number (`Metal.present_seq`) of `surface`.
    surface_seq: u64 = 0,
    /// Bumped on each publish; the display pass waits on it (futex).
    seq: std.atomic.Value(u32) = .init(0),
};

/// A fresh frame taken for a present (`takeFresh`): retained, the caller
/// releases `frame.surface`.
const TakenFrame = struct {
    frame: IOSurfaceLayer.Drawn,
    /// Its present sequence number (`Metal.present_seq`).
    seq: u64,
};

/// How long after a new host size the display pass waits for the renderer
/// thread's frame at that size. The renderer thread starts it when the size
/// is set (during layout), so the wait overlaps layout and the other
/// surfaces' builds: the main thread waits for the slowest surface once,
/// not for each surface's draw in turn. Past it the layer keeps its last
/// frame (top-left, clipped), and the late frame lands at the next pass.
const host_frame_wait_ns = 4 * std.time.ns_per_ms;

pub fn init(
    alloc: Allocator,
    device: *const Device,
    opts: rendererpkg.Options,
) !Metal {
    comptime switch (builtin.os.tag) {
        .macos, .ios => {},
        else => @compileError("unsupported platform for Metal"),
    };

    _ = alloc;

    // Create a MTLCommandQueue for our app-scoped MTLDevice.
    const mtl_device = device.device;
    const queue = mtl_device.msgSend(objc.Object, objc.sel("newCommandQueue"), .{});
    errdefer queue.release();

    const ViewInfo = struct {
        view: objc.Object,
        scaleFactor: f64,
    };

    // Get the metadata about our underlying view that we'll be rendering to.
    const info: ViewInfo = switch (apprt.runtime) {
        apprt.embedded => .{
            .scaleFactor = @floatCast(opts.rt_surface.content_scale.x),
            .view = switch (opts.rt_surface.platform) {
                .macos => |v| v.nsview,
                .ios => |v| v.uiview,
            },
        },

        else => @compileError("unsupported apprt for metal"),
    };

    // Create an IOSurfaceLayer which we can assign to the view to make
    // it in to a "layer-hosting view", so that we can manually control
    // the layer contents.
    var layer = try IOSurfaceLayer.init();
    errdefer layer.release();

    // Add our layer to the view.
    //
    // On macOS we do this by making the view "layer-hosting"
    // by assigning it to the view's `layer` property BEFORE
    // setting `wantsLayer` to `true`.
    //
    // On iOS, views are always layer-backed, and `layer`
    // is readonly, so instead we add it as a sublayer.
    switch (comptime builtin.os.tag) {
        .macos => {
            info.view.setProperty("layer", layer.layer.value);
            info.view.setProperty("wantsLayer", true);
        },

        .ios => {
            const view_layer = objc.Object.fromId(info.view.getProperty(?*anyopaque, "layer"));
            view_layer.msgSend(void, objc.sel("addSublayer:"), .{layer.layer.value});
        },

        else => @compileError("unsupported target for Metal"),
    }

    // Ensure that if our layer is oversized it
    // does not overflow the bounds of the view.
    info.view.setProperty("clipsToBounds", true);

    // Ensure that our layer has a content scale set to
    // match the scale factor of the window. This avoids
    // magnification issues leading to blurry rendering.
    layer.layer.setProperty("contentsScale", info.scaleFactor);

    // This makes it so that our display callback will actually be called.
    layer.layer.setProperty("needsDisplayOnBoundsChange", true);

    return .{
        .layer = layer,
        .device = device,
        .queue = queue,
        .blending = opts.config.blending,
    };
}

pub fn deinit(self: *Metal) void {
    self.queue.release();
    if (self.fresh.surface) |surface| surface.release();

    // The MTLDevice is app-scoped and destroyed
    // by the render device, not by us.

    self.layer.release();
}

/// iOS only: size and place the IOSurfaceLayer inside the embedder's view.
///
/// On iOS the IOSurfaceLayer is a sublayer of the view's own layer (the
/// view's `layer` is read-only), so unlike macOS it does not follow the
/// view's bounds. Without this its bounds stay zero, `surfaceSize` reports
/// 0x0, `drawFrame` returns early, and nothing is ever drawn. The embedded
/// runtime calls this on the main thread from `ghostty_surface_set_size`
/// and `ghostty_surface_set_content_scale`, before the renderer learns the
/// new size, so the next frame matches the layer. The layer is pinned to
/// the view's top-left corner; its implicit animations are already off.
pub fn setHostedLayerSize(
    self: *Metal,
    width_px: u32,
    height_px: u32,
    scale: f64,
) void {
    if (comptime builtin.os.tag != .ios) return;
    if (!(scale > 0)) return;
    const layer = self.layer.layer;
    layer.setProperty("contentsScale", scale);
    layer.setProperty("anchorPoint", graphics.Point{ .x = 0, .y = 0 });
    layer.setProperty("position", graphics.Point{ .x = 0, .y = 0 });
    layer.setProperty("bounds", graphics.Rect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{
            .width = @as(f64, @floatFromInt(width_px)) / scale,
            .height = @as(f64, @floatFromInt(height_px)) / scale,
        },
    });
}

/// macOS only: make the render target follow the size the embedder sets
/// (`ghostty_surface_set_size`) instead of the layer's bounds, or follow the
/// bounds again with `enabled` false. Main thread.
///
/// While a host-sized view's bounds change and the embedder holds its size
/// (a divider drag), nothing is drawn or allocated: the layer keeps showing
/// the last frame from its top-left corner (`contentsGravity`; the embedder
/// clips the view), and new output still draws at the held size. A new size draws
/// one synchronous frame at the next display pass, as a bounds change does
/// for a surface that follows its layer.
pub fn setHostDrawableSize(self: *Metal, enabled: bool, width_px: u32, height_px: u32) void {
    if (comptime builtin.os.tag != .macos) return;
    const max = self.device.max_texture_size;
    const value: u64 = if (enabled and width_px > 0 and height_px > 0)
        (@as(u64, @min(width_px, max)) << 32) | @min(height_px, max)
    else
        0;
    if (self.host_size.swap(value, .acq_rel) == value) return;
    self.host_size_set_at = .now(global.io(), .awake);
    // A fresh frame kept from an earlier size is not this size's frame,
    // even when the sizes are equal (a drag back): only a frame published
    // after this call may be presented for it.
    self.dropFresh();
    _ = self.fresh.generation.fetchAdd(1, .acq_rel);
    self.fresh.armed.store(value != 0, .release);
    self.layer.setHostSize(value);
    self.layer.layer.setProperty("needsDisplayOnBoundsChange", value == 0);
    // An embedder that presents host sizes shows this size's frame itself
    // (`hostFrame`), with its bounds: no display pass draws, presents or
    // waits for it. A first frame (nothing shown yet) still draws in the next
    // display pass, as it does by default. Only the main thread makes the
    // layer show nothing, so this read needs no lock.
    if (value != 0 and self.embedder_presents.load(.acquire) and
        self.layer.layer.getProperty(?*anyopaque, "contents") != null) return;
    // One synchronous frame at the new target size (or at the bounds again).
    self.layer.layer.msgSend(void, objc.sel("setNeedsDisplay"), .{});
}

/// macOS (`ghostty_surface_set_host_capacity`): every render target is at
/// least `width_px` x `height_px` until the capacity is cleared (0, 0), so the
/// frames of a gesture whose sizes all fit draw into the same targets: one
/// IOSurface per swap-chain frame for the whole gesture instead of one per
/// frame and size. A frame is drawn at the host size from the target's
/// top-left corner (the render pass's viewport and scissor), and the layer
/// shows only those pixels (`IOSurfaceLayer.showLocked`). A larger size grows
/// the target it is drawn into to that size. Clamped to the largest texture.
/// Returns whether it cleared a capacity: the caller then wakes the renderer
/// thread, which gives the targets larger than the host size back and draws
/// a frame at the host size (`Renderer.SwapChain.trim`). Main thread.
pub fn setHostCapacity(self: *Metal, width_px: u32, height_px: u32) bool {
    if (comptime builtin.os.tag != .macos) return false;
    const max = self.device.max_texture_size;
    const value: u64 = if (width_px > 0 and height_px > 0)
        (@as(u64, @min(width_px, max)) << 32) | @min(height_px, max)
    else
        0;
    const old = self.host_capacity.swap(value, .acq_rel);
    // A new gesture reuses the targets: nothing to give back. A clear after a
    // capacity arms the trim; a clear with none set changes nothing.
    if (value != 0) {
        self.trim_armed.store(false, .release);
        self.landing_due.store(false, .release);
        return false;
    }
    if (old == 0) return false;
    self.trim_armed.store(true, .release);
    self.landing_due.store(true, .release);
    return true;
}

/// Whether the next draw must draw the landing frame of a cleared capacity;
/// true once per clear. Renderer thread.
pub fn takeLandingDue(self: *Metal) bool {
    return self.landing_due.swap(false, .acq_rel);
}

/// Whether a cleared capacity still waits for its targets to be given back
/// (`Renderer.SwapChain.trim`); false again once a new capacity is set.
/// Renderer thread.
pub fn trimArmed(self: *const Metal) bool {
    return self.trim_armed.load(.acquire) and self.host_capacity.load(.acquire) == 0;
}

/// No target of the cleared capacity is left: none larger than the host size,
/// and no frame in flight (`Renderer.SwapChain.trim`). Renderer thread.
pub fn trimDone(self: *Metal) void {
    self.trim_armed.store(false, .release);
}

/// macOS host-sized surfaces (`ghostty_surface_set_host_present`): with
/// `enabled`, the embedder shows each frame of a new host size itself
/// (`hostFrame`), in the Core Animation transaction that changes the view's
/// bounds. Frames at the shown size still go to the screen off the main
/// thread, and a first frame (nothing shown yet) still presents itself.
/// Main thread.
pub fn setEmbedderPresents(self: *Metal, enabled: bool) void {
    if (comptime builtin.os.tag != .macos) return;
    if (self.embedder_presents.swap(enabled, .acq_rel) == enabled) return;
    self.layer.setEmbedderPresents(enabled);
    // Back to the renderer: a frame it drew for the host size while the
    // embedder owned size changes goes to the screen now. One still drawing
    // presents itself when it completes.
    if (enabled) return;
    const host = self.host_size.load(.acquire);
    if (host != 0) _ = self.presentFresh(@intCast(host >> 32), @intCast(host & 0xffff_ffff));
}

/// iOS only: detach the IOSurfaceLayer from the embedder's view before
/// the renderer's memory is freed.
///
/// The layer keeps raw pointers to this renderer (display callback and
/// context) in its instance variables. On iOS it is a sublayer of the
/// embedder's view, which outlives the surface, so a Core Animation pass
/// on the main thread after the free would call into freed memory.
/// Clearing the pointers, the contents and the sublayer link on the main
/// queue, while they still name this renderer, closes that window. A
/// layer whose callback was rebound to another renderer is left alone.
/// Ported from manaflow-ai/ghostty adee7043fc and dd726a9a60.
pub fn prepareDeinit(self: *Metal) void {
    if (comptime builtin.os.tag != .ios) return;
    const renderer: *align(1) Renderer = @fieldParentPtr("api", self);
    self.layer.detachFromHostIfDisplayCallbackOwned(
        @ptrCast(&displayCallback),
        @ptrCast(renderer),
    );
}

pub fn loopEnter(self: *Metal) void {
    const renderer: *align(1) Renderer = @fieldParentPtr("api", self);
    self.layer.setDisplayCallback(
        @ptrCast(&displayCallback),
        @ptrCast(renderer),
    );
}

fn displayCallback(renderer: *Renderer) align(8) void {
    _ = renderer.api.counters.display_passes.fetchAdd(1, .monotonic);
    if (comptime builtin.os.tag == .macos) {
        if (renderer.api.embedder_presents.load(.acquire)) {
            if (renderer.api.displayWhileEmbedderPresents()) return;
        } else if (renderer.api.presentHostSized()) return;
    }
    _ = renderer.api.counters.main_draws.fetchAdd(1, .monotonic);
    renderer.drawFrame(true) catch |err| {
        log.warn("Error drawing frame in display callback, err={}", .{err});
    };
}

/// Actions taken before doing anything in `drawFrame`.
///
/// Right now we use this to start an AutoreleasePool.
pub fn drawFrameStart(self: *Metal) void {
    assert(self.autorelease_pool == null);
    self.autorelease_pool = .init();
}

/// Actions taken after `drawFrame` is done.
///
/// Right now we use this to end our AutoreleasePool.
pub fn drawFrameEnd(self: *Metal) void {
    assert(self.autorelease_pool != null);
    self.autorelease_pool.?.deinit();
    self.autorelease_pool = null;
}

pub fn initShaders(
    self: *const Metal,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    return try shaders.Shaders.init(
        alloc,
        self.device.device,
        custom_shaders,
        // Using an `*_srgb` pixel format makes Metal gamma encode
        // the pixels written to it *after* blending, which means
        // we get linear alpha blending rather than gamma-incorrect
        // blending.
        if (self.blending.isLinear())
            mtl.MTLPixelFormat.bgra8unorm_srgb
        else
            mtl.MTLPixelFormat.bgra8unorm,
    );
}

/// Get the current size of the runtime surface.
pub fn surfaceSize(self: *const Metal) !struct { width: u32, height: u32 } {
    // A host-sized surface draws at the size the embedder set: while its
    // view's bounds change (a pane drag) the target and the shown frame stay.
    const host = self.host_size.load(.acquire);
    if (host != 0) return .{
        .width = @truncate(host >> 32),
        .height = @truncate(host),
    };

    const bounds = self.layer.layer.getProperty(graphics.Rect, "bounds");
    const scale = self.layer.layer.getProperty(f64, "contentsScale");

    // We need to clamp our runtime surface size to the maximum
    // possible texture size since we can't create a screen buffer (texture)
    // larger than that.
    return .{
        .width = @min(
            @as(u32, @intFromFloat(bounds.size.width * scale)),
            self.device.max_texture_size,
        ),
        .height = @min(
            @as(u32, @intFromFloat(bounds.size.height * scale)),
            self.device.max_texture_size,
        ),
    };
}

/// Initialize a new render target which can be presented by this API.
/// Counted in `counters` (`target_allocs`, the live and peak bytes).
pub fn initTarget(self: *Metal, width: usize, height: usize) !Target {
    var target = try Target.init(.{
        .device = self.device.device,
        // Using an `*_srgb` pixel format makes Metal gamma encode the pixels
        // written to it *after* blending, which means we get linear alpha
        // blending rather than gamma-incorrect blending.
        .pixel_format = if (self.blending.isLinear())
            .bgra8unorm_srgb
        else
            .bgra8unorm,
        .storage_mode = self.device.default_storage_mode,
        .width = width,
        .height = height,
    });
    target.bytes = target.surface.getAllocSize();
    target.live_bytes = &self.counters.target_bytes_live;
    _ = self.counters.target_allocs.fetchAdd(1, .monotonic);
    const live = self.counters.target_bytes_live.fetchAdd(target.bytes, .monotonic) + target.bytes;
    _ = self.counters.target_bytes_peak.fetchMax(live, .monotonic);
    return target;
}

/// Gives `target` (a swap-chain frame's) the size to draw a frame of `width` x
/// `height` pixels, and records that drawn size (`Target.drawn_width`): a new
/// target only when it does not fit (`targetSize`), or with `rebuild` (its
/// config changed, such as the blending mode). Renderer thread.
pub fn fitTarget(self: *Metal, target: *Target, width: usize, height: usize, rebuild: bool) !void {
    if (self.targetSize(target.width, target.height, width, height, rebuild)) |size| {
        const fitted = try self.initTarget(size.width, size.height);
        target.deinit();
        target.* = fitted;
    }
    target.drawn_width = width;
    target.drawn_height = height;
}

/// The size of the new render target a frame of `width` x `height` pixels
/// needs, given a target of `have_width` x `have_height` (0 x 0: one given
/// back, `Target.release`); null keeps that target. Without a host capacity a
/// target has the frame's size, as it always had. With one (`setHostCapacity`)
/// a target is at least the capacity and never shrinks while it is set: it
/// fits any frame up to its size, and a larger frame grows it to that size.
fn targetSize(
    self: *const Metal,
    have_width: usize,
    have_height: usize,
    width: usize,
    height: usize,
    rebuild: bool,
) ?IOSurfaceLayer.Size {
    const capacity = self.host_capacity.load(.acquire);
    if (capacity == 0) {
        if (!rebuild and have_width == width and have_height == height) return null;
        return .{ .width = width, .height = height };
    }
    const want_width = @max(width, @as(usize, @intCast(capacity >> 32)));
    const want_height = @max(height, @as(usize, @intCast(capacity & 0xffff_ffff)));
    if (rebuild) return .{ .width = want_width, .height = want_height };
    if (have_width >= want_width and have_height >= want_height) return null;
    return .{ .width = @max(have_width, want_width), .height = @max(have_height, want_height) };
}

/// The frame drawn into `target` was committed to the GPU (`Frame.complete`):
/// it is in flight until its completion (`frameDone`). Renderer thread, or
/// main for a sync draw.
pub fn frameCommitted(self: *Metal, target: *Target) void {
    _ = self;
    target.in_flight.store(true, .release);
}

/// The frame of `target` completed and was presented (`Frame.bufferCompleted`),
/// before its swap-chain slot is released. After a cleared capacity, a target
/// larger than the size the next frame draws at goes back now
/// (`Target.release`), so no draw is needed for it: the renderer thread's
/// trim (`Renderer.SwapChain.trim`) gave back only the idle ones. Outside the
/// Core Animation lock (`present` released it). The layer keeps showing the
/// frame until a newer one replaces it (it holds its own reference). GPU
/// completion thread.
pub fn frameDone(self: *Metal, target: *Target) void {
    // Last: from here the target is the renderer thread's again.
    defer target.in_flight.store(false, .release);
    if (!self.trimArmed()) return;
    const size = self.surfaceSize() catch return;
    if (target.largerThan(size.width, size.height)) target.release();
}

/// Present the provided target.
pub inline fn present(self: *Metal, target: Target, sync: bool) !void {
    // The frame and the size it was drawn at: the target is larger while the host sets a capacity.
    const frame: IOSurfaceLayer.Drawn = .{
        .surface = target.surface,
        .width = target.drawn_width,
        .height = target.drawn_height,
    };
    if (sync) {
        self.layer.setSurfaceSync(frame);
    } else {
        const seq = self.present_seq.fetchAdd(1, .monotonic) + 1;
        var published = false;
        if (comptime builtin.os.tag == .macos) {
            if (target.cells_fresh and self.fresh.armed.load(.acquire) and
                target.size_generation == self.fresh.generation.load(.acquire) and
                self.host_size.load(.acquire) != 0)
            {
                self.publishFresh(frame, seq);
                published = true;
            }
        }
        // A content-only frame of a host-sized surface goes to the screen from
        // this (completion) thread: a terminal echo does not wait for main.
        if (comptime builtin.os.tag == .macos) {
            const host = self.host_size.load(.acquire);
            if (host != 0 and self.layer.setSurfaceOffMain(frame, seq)) {
                _ = self.counters.off_main_presents.fetchAdd(1, .monotonic);
                return;
            }
            // While the embedder presents host sizes, a frame kept for its present that the layer cannot show in
            // its bounds now (`setSurfaceCallback` drops it) goes to no main-queue block: the embedder shows it with
            // its bounds (`hostFrame`). Any other frame still goes through main, which rechecks it then: one the host
            // no longer has the size of, or one no longer kept (a host change dropped it since it was published).
            if (host != 0 and published and self.embedder_presents.load(.acquire) and
                self.embedderShowsKeptFrame(frame, seq, target.size_generation)) return;
        }
        _ = self.counters.main_presents.fetchAdd(1, .monotonic);
        try self.layer.setSurface(frame, seq);
    }
}

/// While the embedder presents host sizes: whether the embedder shows
/// `frame` (present sequence `seq`, drawn under host size generation
/// `generation`) itself, so no main-thread present is needed. True only while
/// the layer shows a frame of another size in bounds of another size
/// (`setSurfaceCallback` would drop it) and the kept fresh frame is still this
/// one at this generation (no host change or present took it since
/// `publishFresh`). Decided under the Core Animation lock, then `fresh.mutex`:
/// the main thread presents the fresh frame in that order too (`hostFrame` in
/// the embedder's lock span), so it cannot take or drop the frame between the
/// checks. A host change that drops it afterwards follows the rule of every
/// kept frame (`setHostDrawableSize`): a frame kept from before a host change
/// is not the new size's frame, even at an equal size (A->B->A). The renderer
/// draws each new host size at once while visible (`Thread` resize: `resized`
/// draws now), and that frame is published and presented; while frames are
/// held or the surface is hidden, the layer keeps its last frame. GPU
/// completion thread.
fn embedderShowsKeptFrame(self: *Metal, frame: IOSurfaceLayer.Drawn, seq: u64, generation: u64) bool {
    const CATransaction = objc.getClass("CATransaction").?;
    CATransaction.msgSend(void, objc.sel("lock"), .{});
    defer CATransaction.msgSend(void, objc.sel("unlock"), .{});
    if (!self.layer.embedderShowsFrameLocked(frame)) return false;
    const io = global.io();
    self.fresh.mutex.lockUncancelable(io);
    defer self.fresh.mutex.unlock(io);
    return self.fresh.surface == frame.surface and self.fresh.surface_seq == seq and
        self.fresh.generation.load(.acquire) == generation;
}

/// Keeps `frame`, the frame of present sequence `seq`, as the newest fresh
/// frame and wakes a display pass that waits for it. A frame older than the
/// one kept (completions that raced) is not kept. GPU completion thread.
fn publishFresh(self: *Metal, frame: IOSurfaceLayer.Drawn, seq: u64) void {
    const io = global.io();
    const old = old: {
        self.fresh.mutex.lockUncancelable(io);
        defer self.fresh.mutex.unlock(io);
        if (self.fresh.surface != null and seq <= self.fresh.surface_seq) return;
        frame.surface.retain();
        const old = self.fresh.surface;
        self.fresh.surface = frame.surface;
        self.fresh.width = frame.width;
        self.fresh.height = frame.height;
        self.fresh.surface_seq = seq;
        break :old old;
    };
    if (old) |o| o.release();
    _ = self.fresh.seq.fetchAdd(1, .release);
    io.futexWake(@TypeOf(self.fresh.seq), &self.fresh.seq, std.math.maxInt(u32));
}

/// Releases the kept fresh frame, if any. Main thread.
fn dropFresh(self: *Metal) void {
    const io = global.io();
    const old = old: {
        self.fresh.mutex.lockUncancelable(io);
        defer self.fresh.mutex.unlock(io);
        const old = self.fresh.surface;
        self.fresh.surface = null;
        break :old old;
    };
    if (old) |o| o.release();
}

/// The fresh frame if it was drawn at `width` x `height` pixels (retained;
/// the caller releases it). A fresh frame of another size stays for its own
/// pass.
fn takeFresh(self: *Metal, width: usize, height: usize) ?TakenFrame {
    const io = global.io();
    self.fresh.mutex.lockUncancelable(io);
    defer self.fresh.mutex.unlock(io);
    const surface = self.fresh.surface orelse return null;
    if (self.fresh.width != width or self.fresh.height != height) return null;
    self.fresh.surface = null;
    self.fresh.armed.store(false, .release);
    return .{
        .frame = .{ .surface = surface, .width = width, .height = height },
        .seq = self.fresh.surface_seq,
    };
}

/// Whether a fresh frame drawn at `width` x `height` pixels waits
/// (`takeFresh` would take it). Main thread.
fn hasFresh(self: *Metal, width: usize, height: usize) bool {
    const io = global.io();
    self.fresh.mutex.lockUncancelable(io);
    defer self.fresh.mutex.unlock(io);
    if (self.fresh.surface == null) return false;
    return self.fresh.width == width and self.fresh.height == height;
}

/// Shows the fresh frame of `width` x `height` pixels in the caller's Core
/// Animation transaction, unless the layer shows a newer frame. Returns
/// whether it did. Main thread.
fn presentFresh(self: *Metal, width: usize, height: usize) bool {
    const taken = self.takeFresh(width, height) orelse return false;
    defer taken.frame.surface.release();
    if (!self.layer.setSurfacePresented(taken.frame, taken.seq)) {
        // Not shown (the layer shows a newer frame): the next frame of this
        // size publishes for the next present.
        self.fresh.armed.store(true, .release);
        return false;
    }
    _ = self.counters.fresh_presents.fetchAdd(1, .monotonic);
    return true;
}

/// The display pass of a host-sized surface (main thread): present the
/// renderer thread's frame at the host size, drawn with cells rebuilt for
/// that size (the text reflowed to the new grid, the reflow preview
/// included), in this Core Animation transaction. Never draws on the main
/// thread: the cells the main thread could draw with are the ones built for
/// the previous size, so a frame drawn here would show the old text at the
/// new size. Returns false when the display pass should draw itself: not
/// host-sized, or nothing presented yet (the first frame).
pub fn presentHostSized(self: *Metal) bool {
    return self.presentHostSizedWait(true);
}

/// `presentHostSized`; with `wait` false it never blocks: it presents the fresh frame only if the
/// renderer already published it, and otherwise keeps the last frame (counted late).
pub fn presentHostSizedWait(self: *Metal, wait: bool) bool {
    // An embedder that presents host sizes: the same ordered present as
    // `ghostty_surface_host_frame`, which never waits.
    if (comptime builtin.os.tag == .macos) {
        if (self.embedder_presents.load(.acquire)) return self.hostFrame(true) != .none;
    }
    const host = self.host_size.load(.acquire);
    if (host == 0) return false;
    // Hidden: nothing to draw now (the renderer draws when shown again),
    // and drawing here would rebuild the released swap chain.
    if (!self.visible_hint.load(.acquire)) return true;
    const width: usize = @intCast(host >> 32);
    const height: usize = @intCast(host & 0xffff_ffff);
    // The drawn size of the shown frame, not its surface's (a capacity target is larger).
    const shown = self.layer.shownSize() orelse return false;
    if (shown.width == width and shown.height == height) {
        // The renderer thread's frame at this size already landed.
        if (self.takeFresh(width, height)) |taken| taken.frame.surface.release();
        return true;
    }

    const io = global.io();
    const set_at = self.host_size_set_at orelse std.Io.Timestamp.now(io, .awake);
    while (true) {
        const seq = self.fresh.seq.load(.acquire);
        if (self.takeFresh(width, height)) |taken| {
            defer taken.frame.surface.release();
            self.layer.setSurfaceSync(taken.frame);
            _ = self.counters.fresh_presents.fetchAdd(1, .monotonic);
            return true;
        }
        // Read each time: a hold (synchronized output, a restore) or a hide that starts while
        // this pass waits wakes it (setFramesHeld / setVisibleHint), and no frame can come then.
        if (!wait or self.frames_held.load(.acquire) or !self.visible_hint.load(.acquire)) break;
        const now: std.Io.Timestamp = .now(io, .awake);
        const waited: i96 = set_at.durationTo(now).nanoseconds;
        if (waited >= host_frame_wait_ns) break;
        const remaining: u64 = @intCast(@as(i96, host_frame_wait_ns) - waited);
        io.futexWaitTimeout(
            @TypeOf(self.fresh.seq),
            &self.fresh.seq,
            .init(seq),
            .{ .duration = .{ .raw = .fromNanoseconds(remaining), .clock = .awake } },
        ) catch {};
    }
    // Late: keep the last frame; the renderer thread's frame at this size
    // lands through `setSurface` when it completes.
    _ = self.counters.late.fetchAdd(1, .monotonic);
    return true;
}

/// What an embedder that presents host sizes can show for the host size
/// (`ghostty_surface_host_frame`); with `show`, a frame the renderer drew for
/// it becomes the layer's contents in the caller's Core Animation
/// transaction, where the embedder gives the view its new bounds. Never
/// waits and never draws. Main thread.
pub fn hostFrame(self: *Metal, show: bool) apprt.HostFrame {
    if (comptime builtin.os.tag != .macos) return .none;
    const host = self.host_size.load(.acquire);
    if (host == 0) return .none;
    // Hidden: the renderer draws when shown again (a reveal arms the present).
    if (!self.visible_hint.load(.acquire)) return .hidden;
    const width: usize = @intCast(host >> 32);
    const height: usize = @intCast(host & 0xffff_ffff);
    // Nothing shown: the first frame presents itself.
    const shown = self.layer.shownSize() orelse return .none;
    if (shown.width == width and shown.height == height) {
        // A frame at this size is on screen (a first frame, a frame that fit
        // bounds the embedder had set, or an earlier present): a kept fresh
        // frame is not newer, and no frame needs to publish until the next
        // size (frames at this size go off main).
        if (self.takeFresh(width, height)) |taken| taken.frame.surface.release();
        self.fresh.armed.store(false, .release);
        return .shown;
    }
    if (!show) {
        if (self.hasFresh(width, height)) return .ready;
        return if (self.frames_held.load(.acquire)) .held else .pending;
    }
    if (self.presentFresh(width, height)) return .presented;
    // The layer keeps its frame; the new one waits, published, for the next call.
    _ = self.counters.late.fetchAdd(1, .monotonic);
    return if (self.frames_held.load(.acquire)) .held else .pending;
}

/// The embedder committed the transaction of its last present or bounds change
/// (`ghostty_surface_host_frame_committed`). Main thread.
pub fn hostFrameCommitted(self: *Metal) void {
    if (comptime builtin.os.tag != .macos) return;
    self.layer.setEmbedderCommitted();
}

/// A display pass while the embedder presents host sizes (Core Animation runs
/// one on its own, for example for a new contents scale): it never waits and
/// never shows a frame of another size than the one shown; the embedder does,
/// with the view's bounds (`hostFrame`). Returns false when the pass should
/// draw itself: not host-sized, or nothing shown yet (the first frame).
fn displayWhileEmbedderPresents(self: *Metal) bool {
    if (self.host_size.load(.acquire) == 0) return false;
    // Hidden: nothing to draw now, and drawing would rebuild the released swap chain.
    if (!self.visible_hint.load(.acquire)) return true;
    return self.layer.shownSize() != null;
}

/// The host size generation a frame drawn now belongs to (Target.size_generation).
pub fn sizeGeneration(self: *const Metal) u64 {
    return self.fresh.generation.load(.acquire);
}

/// The surface was shown or hidden (`ghostty_surface_set_occlusion`, main
/// thread). Shown: a frame at the host size is due now (it was resized while
/// hidden, or its last frame was purged), so the present is armed for a frame
/// drawn from here on and its deadline starts now, not at the last resize.
pub fn setShownFromMain(self: *Metal, visible: bool) void {
    if (visible and self.host_size.load(.acquire) != 0) {
        self.dropFresh();
        _ = self.fresh.generation.fetchAdd(1, .acq_rel);
        self.fresh.armed.store(true, .release);
        self.host_size_set_at = .now(global.io(), .awake);
    }
    self.setVisibleHint(visible);
}

/// Frame updates are held or resumed (`frames_held`). Renderer thread.
pub fn setFramesHeld(self: *Metal, held: bool) void {
    if (self.frames_held.swap(held, .acq_rel) == held) return;
    if (held) self.wakePresent();
}

/// Wakes a display pass waiting for a fresh frame, so it re-reads the hold and visibility.
fn wakePresent(self: *Metal) void {
    _ = self.fresh.seq.fetchAdd(1, .release);
    global.io().futexWake(@TypeOf(self.fresh.seq), &self.fresh.seq, std.math.maxInt(u32));
}

/// The renderer started or stopped drawing (`setVisible`). Renderer thread.
pub fn setVisibleHint(self: *Metal, visible: bool) void {
    self.visible_hint.store(visible, .release);
    // A hidden surface holds no frame for a present that cannot come.
    if (!visible) {
        self.dropFresh();
        self.wakePresent();
    }
}

/// Returns the options to use when constructing buffers.
pub inline fn bufferOptions(self: Metal) bufferpkg.Options {
    return .{
        .device = self.device.device,
        .resource_options = .{
            // Indicate that the CPU writes to this resource but never reads it.
            .cpu_cache_mode = .write_combined,
            .storage_mode = self.device.default_storage_mode,
        },
    };
}

pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

/// Returns the options to use when constructing textures.
pub inline fn textureOptions(self: Metal) Texture.Options {
    return .{
        .device = self.device.device,
        // Using an `*_srgb` pixel format makes Metal gamma encode the pixels
        // written to it *after* blending, which means we get linear alpha
        // blending rather than gamma-incorrect blending.
        .pixel_format = if (self.blending.isLinear())
            .bgra8unorm_srgb
        else
            .bgra8unorm,
        .resource_options = .{
            // Indicate that the CPU writes to this resource but never reads it.
            .cpu_cache_mode = .write_combined,
            .storage_mode = self.device.default_storage_mode,
        },
        .usage = .{
            // textureOptions is currently only used for custom shaders,
            // which require both the shader read (for when multiple shaders
            // are chained) and render target (for the final output) usage.
            // Disabling either of these will lead to metal validation
            // errors in Xcode.
            .shader_read = true,
            .render_target = true,
        },
    };
}

pub inline fn samplerOptions(self: Metal) Sampler.Options {
    return .{
        .device = self.device.device,

        // These parameters match Shadertoy behaviors.
        .min_filter = .linear,
        .mag_filter = .linear,
        .s_address_mode = .clamp_to_edge,
        .t_address_mode = .clamp_to_edge,
    };
}

/// Pixel format for image texture options.
pub const ImageTextureFormat = enum {
    /// 1 byte per pixel grayscale.
    gray,
    /// 4 bytes per pixel RGBA.
    rgba,
    /// 4 bytes per pixel BGRA.
    bgra,

    fn toPixelFormat(
        self: ImageTextureFormat,
        srgb: bool,
    ) mtl.MTLPixelFormat {
        return switch (self) {
            .gray => if (srgb) .r8unorm_srgb else .r8unorm,
            .rgba => if (srgb) .rgba8unorm_srgb else .rgba8unorm,
            .bgra => if (srgb) .bgra8unorm_srgb else .bgra8unorm,
        };
    }
};

/// Returns the options to use when constructing textures for images.
pub inline fn imageTextureOptions(
    self: Metal,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    return .{
        .device = self.device.device,
        .pixel_format = format.toPixelFormat(srgb),
        .resource_options = .{
            // Indicate that the CPU writes to this resource but never reads it.
            .cpu_cache_mode = .write_combined,
            .storage_mode = self.device.default_storage_mode,
        },
        .usage = .{
            // We only need to read from this texture from a shader.
            .shader_read = true,
        },
    };
}

/// Initializes a Texture suitable for the provided font atlas.
pub fn initAtlasTexture(
    self: *const Metal,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    const pixel_format: mtl.MTLPixelFormat = switch (atlas.format) {
        .grayscale => .r8unorm,
        .bgra => .bgra8unorm_srgb,
        else => @panic("unsupported atlas format for Metal texture"),
    };

    return try Texture.init(
        .{
            .device = self.device.device,
            .pixel_format = pixel_format,
            .resource_options = .{
                // Indicate that the CPU writes to this resource but never reads it.
                .cpu_cache_mode = .write_combined,
                .storage_mode = self.device.default_storage_mode,
            },
            .usage = .{
                // We only need to read from this texture from a shader.
                .shader_read = true,
            },
        },
        atlas.size,
        atlas.size,
        null,
    );
}

/// Begin a frame.
pub inline fn beginFrame(
    self: *const Metal,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Frame {
    return try Frame.begin(.{ .queue = self.queue }, renderer, target);
}

fn testDevice() Device {
    var device: Device = undefined;
    device.max_texture_size = 16384;
    return device;
}

/// A host-sized Metal API with a real layer and no GPU: the paths under test
/// touch only the layer, the host size and the fresh frame.
fn testMetal(device: *const Device) !Metal {
    return .{
        .layer = try IOSurfaceLayer.init(),
        .device = device,
        .queue = undefined,
        .blending = .native,
    };
}

fn testDeinit(self: *Metal) void {
    self.dropFresh();
    self.layer.release();
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
fn testShownWidth(self: *const Metal) ?usize {
    const shown = self.layer.layer.getProperty(?*anyopaque, "contents") orelse return null;
    const surface: *IOSurface = @ptrCast(shown);
    return surface.getWidth();
}

/// A frame the renderer drew at `surface`'s size, with cells built for it.
fn testTarget(self: *const Metal, surface: *IOSurface) Target {
    return .{
        .surface = surface,
        .texture = undefined,
        .width = surface.getWidth(),
        .height = surface.getHeight(),
        .drawn_width = surface.getWidth(),
        .drawn_height = surface.getHeight(),
        .cells_fresh = true,
        .size_generation = self.sizeGeneration(),
    };
}

fn testIsMainThread() bool {
    return objc.getClass("NSThread").?.msgSend(bool, "isMainThread", .{});
}

test "host present: a new host size asks no display pass while the embedder presents sizes" {
    const testing = std.testing;
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    const shown = try testSurface(80, 60);
    defer shown.release();
    metal.layer.setSurfaceSync(.whole(shown));
    metal.setEmbedderPresents(true);
    metal.layer.layer.msgSend(void, objc.sel("displayIfNeeded"), .{});
    try testing.expect(!metal.layer.layer.getProperty(bool, "needsDisplay"));

    metal.setHostDrawableSize(true, 120, 60);
    // No display pass: Core Animation never presents (or waits for) the new
    // size's frame on its own; the embedder shows it with its bounds.
    try testing.expect(!metal.layer.layer.getProperty(bool, "needsDisplay"));
}

test "host present: a new host size asks a display pass by default" {
    const testing = std.testing;
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    const shown = try testSurface(80, 60);
    defer shown.release();
    metal.layer.setSurfaceSync(.whole(shown));
    metal.layer.layer.msgSend(void, objc.sel("displayIfNeeded"), .{});
    try testing.expect(!metal.layer.layer.getProperty(bool, "needsDisplay"));

    metal.setHostDrawableSize(true, 120, 60);
    try testing.expect(metal.layer.layer.getProperty(bool, "needsDisplay"));
}

test "host present: the renderer never shows a frame of a new host size while the embedder presents sizes" {
    const testing = std.testing;
    // The main-thread present runs at once only on the main thread.
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    const shown = try testSurface(80, 60);
    defer shown.release();
    const drawn = try testSurface(120, 60);
    defer drawn.release();
    metal.layer.setSurfaceSync(.whole(shown));
    metal.setEmbedderPresents(true);
    metal.setHostDrawableSize(true, 120, 60);

    // The renderer completed the frame of the new size.
    try metal.present(testTarget(&metal, drawn), false);
    // The layer keeps the shown frame and its size; the new frame waits, as
    // the fresh frame, for the embedder's present.
    try testing.expectEqual(@as(?usize, 80), testShownWidth(&metal));
    try testing.expectEqual(@as(?*IOSurface, drawn), metal.fresh.surface);
}

test "host present: a frame of a new host size that the embedder presents wakes no main-thread present" {
    // cmux FRAME OWNER S4, held key resize with 7 moving terminals (cmux24 job c33bd85dbb064376b348d0c2): each frame of a
    // new size went to the main queue, where setSurfaceCallback dropped it (the embedder shows it with its bounds): one
    // main-thread wake per moving terminal and frame, for nothing.
    const testing = std.testing;
    const HostFrame = apprt.HostFrame;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    const shown = try testSurface(80, 60);
    defer shown.release();
    const drawn = try testSurface(120, 60);
    defer drawn.release();
    metal.layer.setSurfaceSync(.whole(shown));
    metal.layer.layer.setProperty("contentsScale", @as(f64, 1));
    metal.layer.layer.setProperty("bounds", macos.graphics.Rect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 80, .height = 60 },
    });
    metal.setEmbedderPresents(true);
    metal.setHostDrawableSize(true, 120, 60);

    // The renderer completed the frame of the new size; the view keeps its old bounds until the embedder presents it.
    try metal.present(testTarget(&metal, drawn), false);
    try testing.expectEqual(@as(u64, 0), metal.counters.main_presents.load(.monotonic));
    try testing.expectEqual(@as(?usize, 80), testShownWidth(&metal));
    // The frame waits for the embedder, which shows it in its transaction.
    try testing.expectEqual(HostFrame.presented, metal.hostFrame(true));
    try testing.expectEqual(@as(?usize, 120), testShownWidth(&metal));
}

test "host present: a kept frame that a host change dropped since its publish still goes through main" {
    // Review of this change (Codex FIX at 3d209283a): the frame of host size A was kept for the embedder, then the host
    // changed to B and back to A (each change drops the kept frame); the completion must not skip the main-thread
    // present for a frame that nothing keeps any more.
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    const shown = try testSurface(80, 60);
    defer shown.release();
    const drawn = try testSurface(120, 60);
    defer drawn.release();
    metal.layer.setSurfaceSync(.whole(shown));
    metal.layer.layer.setProperty("contentsScale", @as(f64, 1));
    metal.layer.layer.setProperty("bounds", macos.graphics.Rect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 80, .height = 60 },
    });
    metal.setEmbedderPresents(true);
    metal.setHostDrawableSize(true, 120, 60);
    const target = testTarget(&metal, drawn);
    metal.publishFresh(.whole(drawn), 1);
    try testing.expect(metal.embedderShowsKeptFrame(.whole(drawn), 1, target.size_generation));

    metal.setHostDrawableSize(true, 160, 60);
    metal.setHostDrawableSize(true, 120, 60);
    try testing.expect(!metal.embedderShowsKeptFrame(.whole(drawn), 1, target.size_generation));
}

test "host present: after a host change drops a skipped frame, the new size's frame replaces it" {
    // Review of this change (Codex FIX at 17ccbcfea): the completion skipped the main-thread present of a kept frame
    // of host size A; then the host went to B and back to A (each change drops the kept frame) and the embedder gave
    // the view A bounds without a present. No stale frame shows for the second A (the kept-frame rule): the layer keeps
    // its last frame (PENDING), and the renderer's frame of the second A presents itself through main.
    const testing = std.testing;
    const HostFrame = apprt.HostFrame;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    const shown = try testSurface(80, 60);
    defer shown.release();
    const first = try testSurface(120, 60);
    defer first.release();
    const second = try testSurface(120, 60);
    defer second.release();
    metal.layer.setSurfaceSync(.whole(shown));
    metal.layer.layer.setProperty("contentsScale", @as(f64, 1));
    metal.layer.layer.setProperty("bounds", macos.graphics.Rect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 80, .height = 60 },
    });
    metal.setEmbedderPresents(true);
    metal.setHostDrawableSize(true, 120, 60);
    try metal.present(testTarget(&metal, first), false);
    try testing.expectEqual(@as(u64, 0), metal.counters.main_presents.load(.monotonic));

    metal.setHostDrawableSize(true, 160, 60);
    metal.setHostDrawableSize(true, 120, 60);
    metal.layer.layer.setProperty("bounds", macos.graphics.Rect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 120, .height = 60 },
    });
    try testing.expectEqual(HostFrame.pending, metal.hostFrame(false));
    try testing.expectEqual(@as(?usize, 80), testShownWidth(&metal));

    // The renderer drew the second A at once (a resize draws now): its frame fits the bounds and presents itself.
    try metal.present(testTarget(&metal, second), false);
    try testing.expectEqual(@as(u64, 1), metal.counters.main_presents.load(.monotonic));
    const contents = metal.layer.layer.getProperty(?*anyopaque, "contents");
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(second)), contents);
}

test "host present: a frame for bounds the embedder already set presents itself through main" {
    // The embedder gave the view the new bounds without a present (a size that waited too long takes its bounds
    // anyway): the frame drawn for them goes to the screen through main when it completes.
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    const shown = try testSurface(80, 60);
    defer shown.release();
    const drawn = try testSurface(120, 60);
    defer drawn.release();
    metal.layer.setSurfaceSync(.whole(shown));
    metal.setEmbedderPresents(true);
    metal.setHostDrawableSize(true, 120, 60);
    metal.layer.layer.setProperty("contentsScale", @as(f64, 1));
    metal.layer.layer.setProperty("bounds", macos.graphics.Rect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 120, .height = 60 },
    });

    try metal.present(testTarget(&metal, drawn), false);
    try testing.expectEqual(@as(u64, 1), metal.counters.main_presents.load(.monotonic));
    try testing.expectEqual(@as(?usize, 120), testShownWidth(&metal));
}

test "host present: a frame of a size the host no longer has still goes through main while the embedder presents sizes" {
    // Not kept for the embedder (the host size changed while it was drawn), so nothing else can show it: the main
    // thread's present rechecks the host size when it runs (the host can have its size again by then, A->B->A).
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    const shown = try testSurface(80, 60);
    defer shown.release();
    const drawn = try testSurface(120, 60);
    defer drawn.release();
    metal.layer.setSurfaceSync(.whole(shown));
    metal.setEmbedderPresents(true);
    metal.setHostDrawableSize(true, 120, 60);
    const target = testTarget(&metal, drawn);
    metal.setHostDrawableSize(true, 160, 60);

    try metal.present(target, false);
    try testing.expectEqual(@as(u64, 1), metal.counters.main_presents.load(.monotonic));
    try testing.expectEqual(@as(?usize, 80), testShownWidth(&metal));
    try testing.expectEqual(@as(?*IOSurface, null), metal.fresh.surface);
}

test "host present: a frame of a size the host no longer has still goes through main by default" {
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    const shown = try testSurface(80, 60);
    defer shown.release();
    const drawn = try testSurface(120, 60);
    defer drawn.release();
    metal.layer.setSurfaceSync(.whole(shown));
    metal.setHostDrawableSize(true, 120, 60);
    const target = testTarget(&metal, drawn);
    metal.setHostDrawableSize(true, 160, 60);

    try metal.present(target, false);
    try testing.expectEqual(@as(u64, 1), metal.counters.main_presents.load(.monotonic));
    try testing.expectEqual(@as(?usize, 80), testShownWidth(&metal));
}

test "host present: the renderer shows a frame of a new host size by default" {
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    const shown = try testSurface(80, 60);
    defer shown.release();
    const drawn = try testSurface(120, 60);
    defer drawn.release();
    metal.layer.setSurfaceSync(.whole(shown));
    metal.setHostDrawableSize(true, 120, 60);

    try metal.present(testTarget(&metal, drawn), false);
    try testing.expectEqual(@as(?usize, 120), testShownWidth(&metal));
}

test "host present: a first frame presents itself while the embedder presents sizes" {
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    const drawn = try testSurface(120, 60);
    defer drawn.release();
    metal.setEmbedderPresents(true);
    metal.setHostDrawableSize(true, 120, 60);

    // Nothing is shown yet: there is no size to keep.
    try metal.present(testTarget(&metal, drawn), false);
    try testing.expectEqual(@as(?usize, 120), testShownWidth(&metal));
}

test "host present: a frame at the shown size goes to the screen off main while the embedder presents sizes" {
    const testing = std.testing;
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    const shown = try testSurface(120, 60);
    defer shown.release();
    const drawn = try testSurface(120, 60);
    defer drawn.release();
    metal.layer.setSurfaceSync(.whole(shown));
    metal.setEmbedderPresents(true);
    metal.setHostDrawableSize(true, 120, 60);
    // The embedder committed its last change: frames at the shown size may go off main.
    metal.hostFrameCommitted();

    // A content-only frame (a terminal echo) needs no geometry change.
    try metal.present(testTarget(&metal, drawn), false);
    const contents = metal.layer.layer.getProperty(?*anyopaque, "contents");
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(drawn)), contents);
    try testing.expectEqual(@as(u64, 1), metal.counters.off_main_presents.load(.monotonic));
}

test "host present: a frame at the shown size goes through main until the embedder reports its commit" {
    // Independent review of #75 (finding 1): a frame kept for the embedder at the size the layer already shows is not
    // one the embedder presents with new bounds (hostFrame answers SHOWN for it): it must go through main while the
    // embedder's last change is not reported committed (setSurfaceOffMain refuses it then), never be skipped.
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    const shown = try testSurface(120, 60);
    defer shown.release();
    const drawn = try testSurface(120, 60);
    defer drawn.release();
    metal.layer.setSurfaceSync(.whole(shown));
    metal.setEmbedderPresents(true);
    metal.setHostDrawableSize(true, 120, 60);

    try metal.present(testTarget(&metal, drawn), false);
    try testing.expectEqual(@as(u64, 0), metal.counters.off_main_presents.load(.monotonic));
    try testing.expectEqual(@as(u64, 1), metal.counters.main_presents.load(.monotonic));
    const contents = metal.layer.layer.getProperty(?*anyopaque, "contents");
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(drawn)), contents);
}

test "host present: hostFrame reports the frame drawn for a new host size and shows it in the caller's transaction" {
    const testing = std.testing;
    const HostFrame = apprt.HostFrame;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    const shown = try testSurface(80, 60);
    defer shown.release();
    const drawn = try testSurface(120, 60);
    defer drawn.release();
    metal.layer.setSurfaceSync(.whole(shown));
    metal.setEmbedderPresents(true);
    metal.setHostDrawableSize(true, 120, 60);
    try metal.present(testTarget(&metal, drawn), false);

    // A query shows nothing.
    try testing.expectEqual(HostFrame.ready, metal.hostFrame(false));
    try testing.expectEqual(@as(?usize, 80), testShownWidth(&metal));
    // A present shows the frame now; the embedder gives the view its new
    // bounds in the same transaction.
    try testing.expectEqual(HostFrame.presented, metal.hostFrame(true));
    try testing.expectEqual(@as(?usize, 120), testShownWidth(&metal));
    try testing.expectEqual(@as(u64, 1), metal.counters.fresh_presents.load(.monotonic));
    // Nothing is left to show for this size.
    try testing.expectEqual(HostFrame.shown, metal.hostFrame(true));
}

test "host present: hostFrame keeps the shown frame until the renderer drew the new host size" {
    const testing = std.testing;
    const HostFrame = apprt.HostFrame;
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    const shown = try testSurface(80, 60);
    defer shown.release();
    metal.layer.setSurfaceSync(.whole(shown));
    metal.setEmbedderPresents(true);
    metal.setHostDrawableSize(true, 120, 60);

    try testing.expectEqual(HostFrame.pending, metal.hostFrame(false));
    try testing.expectEqual(HostFrame.pending, metal.hostFrame(true));
    try testing.expectEqual(@as(?usize, 80), testShownWidth(&metal));
    // Only a present that kept the shown frame counts as late.
    try testing.expectEqual(@as(u64, 1), metal.counters.late.load(.monotonic));
}

test "host present: hostFrame reports nothing to keep, held frames and a hidden surface" {
    const testing = std.testing;
    const HostFrame = apprt.HostFrame;
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);

    // Not host-sized: the target follows the bounds.
    try testing.expectEqual(HostFrame.none, metal.hostFrame(true));
    metal.setEmbedderPresents(true);
    metal.setHostDrawableSize(true, 120, 60);
    // Nothing shown yet: the first frame presents itself.
    try testing.expectEqual(HostFrame.none, metal.hostFrame(true));
    const shown = try testSurface(80, 60);
    defer shown.release();
    metal.layer.setSurfaceSync(.whole(shown));
    // Synchronized output or a restore holds frame updates: no frame can come now.
    metal.setFramesHeld(true);
    try testing.expectEqual(HostFrame.held, metal.hostFrame(false));
    try testing.expectEqual(HostFrame.held, metal.hostFrame(true));
    metal.setFramesHeld(false);
    // A hidden surface draws nothing until it is shown again.
    metal.setVisibleHint(false);
    try testing.expectEqual(HostFrame.hidden, metal.hostFrame(true));
    try testing.expectEqual(@as(?usize, 80), testShownWidth(&metal));
}

test "host present: a frame that reaches the main thread late never replaces the one the embedder showed" {
    const testing = std.testing;
    const HostFrame = apprt.HostFrame;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    const shown = try testSurface(80, 60);
    defer shown.release();
    const stale = try testSurface(120, 60);
    defer stale.release();
    const fresh = try testSurface(120, 60);
    defer fresh.release();
    metal.layer.setSurfaceSync(.whole(shown));
    metal.setEmbedderPresents(true);
    metal.setHostDrawableSize(true, 120, 60);

    // The renderer drew the new size twice: first with the cells of the old
    // size (present sequence 1), then with cells built for it (sequence 2).
    var stale_target = testTarget(&metal, stale);
    stale_target.cells_fresh = false;
    try metal.present(stale_target, false);
    try metal.present(testTarget(&metal, fresh), false);
    try testing.expectEqual(HostFrame.presented, metal.hostFrame(true));

    // The older frame's main-thread present runs after that (a block queued
    // before it): it must not replace the newer frame.
    try metal.layer.setSurface(.whole(stale), 1);
    const contents = metal.layer.layer.getProperty(?*anyopaque, "contents");
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(fresh)), contents);
}

test "host present: back to the renderer, a frame drawn for the host size goes to the screen" {
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    const shown = try testSurface(80, 60);
    defer shown.release();
    const drawn = try testSurface(120, 60);
    defer drawn.release();
    metal.layer.setSurfaceSync(.whole(shown));
    metal.setEmbedderPresents(true);
    metal.setHostDrawableSize(true, 120, 60);
    try metal.present(testTarget(&metal, drawn), false);

    metal.setEmbedderPresents(false);
    try testing.expectEqual(@as(?usize, 120), testShownWidth(&metal));
}

test "host present: a refused present keeps the next frame of the host size publishing" {
    const testing = std.testing;
    const HostFrame = apprt.HostFrame;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    const shown = try testSurface(80, 60);
    defer shown.release();
    const newer = try testSurface(80, 60);
    defer newer.release();
    const drawn = try testSurface(120, 60);
    defer drawn.release();
    metal.layer.setSurfaceSync(.whole(shown));
    metal.setEmbedderPresents(true);
    metal.setHostDrawableSize(true, 120, 60);
    try metal.present(testTarget(&metal, drawn), false);
    // The layer shows a newer frame (of the old size) than the one drawn for the
    // host size, so the present refuses it.
    try testing.expect(metal.layer.setSurfacePresented(.whole(newer), 50));

    try testing.expectEqual(HostFrame.pending, metal.hostFrame(true));
    // The next frame at the host size must publish for the next present.
    try testing.expect(metal.fresh.armed.load(.acquire));
}

test "host present: the old present calls follow the embedder's ordered present" {
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    const shown = try testSurface(80, 60);
    defer shown.release();
    const stale = try testSurface(120, 60);
    defer stale.release();
    const fresh = try testSurface(120, 60);
    defer fresh.release();
    metal.layer.setSurfaceSync(.whole(shown));
    metal.setEmbedderPresents(true);
    metal.setHostDrawableSize(true, 120, 60);
    var stale_target = testTarget(&metal, stale);
    stale_target.cells_fresh = false;
    try metal.present(stale_target, false);
    try metal.present(testTarget(&metal, fresh), false);

    // ghostty_surface_present_host_frame(_ready) while the embedder presents sizes.
    try testing.expect(metal.presentHostSizedWait(true));
    try metal.layer.setSurface(.whole(stale), 1);
    const contents = metal.layer.layer.getProperty(?*anyopaque, "contents");
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(fresh)), contents);
}

/// The layer shows `target`'s frame: its surface, at the size it was drawn at, and exactly its drawn pixels, top-left.
fn testExpectShows(metal: *Metal, target: *const Target) !void {
    const testing = std.testing;
    const shown = metal.layer.shownSize() orelse return error.NothingShown;
    try testing.expectEqual(target.drawn_width, shown.width);
    try testing.expectEqual(target.drawn_height, shown.height);
    const contents = metal.layer.layer.getProperty(?*anyopaque, "contents");
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(target.surface)), contents);
    // The top-left drawn_width x drawn_height pixels of the surface, in Core Animation's unit space, whose y runs up
    // for an IOSurface ("host present: a capacity frame shows only its drawn pixels, top-left").
    const width = @as(f64, @floatFromInt(target.drawn_width)) / @as(f64, @floatFromInt(target.width));
    const height = @as(f64, @floatFromInt(target.drawn_height)) / @as(f64, @floatFromInt(target.height));
    const rect = metal.layer.layer.getProperty(graphics.Rect, "contentsRect");
    try testing.expectEqual(@as(f64, 0), rect.origin.x);
    try testing.expectEqual(1 - height, rect.origin.y);
    try testing.expectEqual(width, rect.size.width);
    try testing.expectEqual(height, rect.size.height);
}

/// One frame of `drawFrameLocked` on a real swap chain, without the GPU: the host size, the trim of a cleared
/// capacity (`SwapChain.trim`), the next frame's target (`FrameState.fit`) and its commit (`Frame.complete`). The frame
/// is in flight until `testComplete`.
fn testCommit(metal: *Metal, chain: *Renderer.SwapChain, width: u32, height: u32) !*Target {
    metal.setHostDrawableSize(true, width, height);
    _ = chain.trim(metal, width, height);
    const frame = chain.nextFrame();
    errdefer chain.releaseFrame();
    try frame.fit(metal, width, height, false);
    frame.target.cells_fresh = true;
    frame.target.size_generation = metal.sizeGeneration();
    metal.frameCommitted(&frame.target);
    return &frame.target;
}

/// The completion of a committed frame (`Frame.bufferCompleted`): its present, `frameDone`, then its swap-chain slot
/// is free again. Frames complete in commit order, as on a Metal command queue.
fn testComplete(metal: *Metal, chain: *Renderer.SwapChain, target: *Target) !void {
    try metal.present(target.*, false);
    metal.frameDone(target);
    chain.releaseFrame();
}

/// `testCommit`, then its completion at once. Returns that frame's target.
fn testDraw(metal: *Metal, chain: *Renderer.SwapChain, width: u32, height: u32) !*Target {
    const target = try testCommit(metal, chain, width, height);
    try testComplete(metal, chain, target);
    return target;
}

test "host present: a held-key resize makes one render target per swap-chain frame with a host capacity" {
    // cmux FRAME OWNER S4 (contract m14): in a held-key resize every moving terminal presents a frame at its pane's
    // size each frame, and each new size made a new IOSurface and MTLTexture per frame (FrameState.resize ->
    // initTarget): IOSurfaceCreate 7 -> 57 ms, newTextureWithDescriptor:iosurface 15 -> 36 ms, __mmap 30 -> 104 ms
    // per round in cmux's held keys-stress. With the gesture's largest size as the host capacity, each swap-chain
    // frame keeps one target for the whole gesture: one allocation per target (to reach the capacity), not one per
    // frame. The floor is one per swap-chain frame, not one per terminal: a target in flight or on screen cannot be
    // redrawn. Each frame is still drawn at its host size, and the layer shows exactly those pixels.
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    var device = try Device.initForTest();
    defer device.deinit();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    var chain = try Renderer.SwapChain.init(&metal, false);
    defer chain.deinit();
    const allocs = &metal.counters.target_allocs;

    // At rest: each swap-chain frame drew once at the pane's size.
    for (0..swap_chain_count) |_| _ = try testDraw(&metal, &chain, 80, 60);
    const at_rest = allocs.load(.monotonic);

    // The gesture: 24 frames, each at a new size, all inside the capacity.
    _ = metal.setHostCapacity(160, 60);
    var allocs_per_target = [_]u64{0} ** swap_chain_count;
    for (0..24) |i| {
        const index = (@as(usize, chain.frame_index) + 1) % swap_chain_count;
        const before = allocs.load(.monotonic);
        const width: u32 = @intCast(81 + 3 * i);
        const target = try testDraw(&metal, &chain, width, 60);
        allocs_per_target[index] += allocs.load(.monotonic) - before;
        try testing.expectEqual(@as(usize, width), target.drawn_width);
        try testing.expectEqual(@as(usize, 60), target.drawn_height);
        try testExpectShows(&metal, target);
    }
    // One allocation per swap-chain target for the whole gesture, not one per frame.
    try testing.expectEqual(@as(u64, swap_chain_count), allocs.load(.monotonic) - at_rest);
    for (allocs_per_target) |count| try testing.expectEqual(@as(u64, 1), count);

    // A size past the capacity grows the target it is drawn into once, to that size; once every target has grown,
    // no frame at that size or below allocates.
    const before_past = allocs.load(.monotonic);
    const grown = try testDraw(&metal, &chain, 200, 60);
    try testing.expectEqual(before_past + 1, allocs.load(.monotonic));
    try testing.expectEqual(@as(usize, 200), grown.width);
    try testExpectShows(&metal, grown);
    for (0..swap_chain_count - 1) |_| _ = try testDraw(&metal, &chain, 200, 60);
    const settled = allocs.load(.monotonic);
    try testing.expectEqual(before_past + swap_chain_count, settled);
    for (0..swap_chain_count) |_| _ = try testDraw(&metal, &chain, 190, 60);
    try testing.expectEqual(settled, allocs.load(.monotonic));
}

test "host present: clearing the host capacity at the landing leaves one target, at the pane's size" {
    // pixel-perfect's condition (frame-owner-s4, 2026-11-05): at the landing the capacity-sized surfaces go back to
    // the pane's size. The spare swap-chain targets kept the capacity's size until a frame was drawn into them, and a
    // terminal that draws nothing after the landing (no output, a hidden cursor) kept two window-sized IOSurfaces
    // (14 terminals: 28). Clearing the capacity gives back every target larger than the host size, once no frame is
    // in flight; the next frame drawn into one makes it at its size.
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    var device = try Device.initForTest();
    defer device.deinit();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    var chain = try Renderer.SwapChain.init(&metal, false);
    defer chain.deinit();
    const live = &metal.counters.target_bytes_live;

    // A pane of 1000 x 700 pixels grows toward 2000 (the capacity) while the key is held.
    for (0..swap_chain_count) |_| _ = try testDraw(&metal, &chain, 1000, 700);
    _ = metal.setHostCapacity(2000, 700);
    for (0..12) |i| _ = try testDraw(&metal, &chain, @intCast(1010 + 75 * i), 700);
    const at_capacity = live.load(.monotonic);

    // The landing: the host clears the capacity, then gives the pane its size.
    _ = metal.setHostCapacity(0, 0);
    const landing = try testDraw(&metal, &chain, 1200, 700);
    const landed = live.load(.monotonic);
    std.debug.print(
        "host capacity: live target bytes {d} during the gesture, {d} after the landing (the pane's target: {d}), peak {d}\n",
        .{ at_capacity, landed, landing.surface.getAllocSize(), metal.counters.target_bytes_peak.load(.monotonic) },
    );
    // Only the frame on screen holds a target, at the pane's size.
    try testing.expectEqual(@as(u64, landing.surface.getAllocSize()), landed);
    try testing.expectEqual(@as(usize, 1200), landing.width);
    try testExpectShows(&metal, landing);
    // The two spares hold no surface; the next frame drawn into each makes one at its size.
    var empty: usize = 0;
    for (&chain.frames) |*frame| {
        if (frame.target.width == 0) empty += 1;
    }
    try testing.expectEqual(@as(usize, swap_chain_count - 1), empty);
    const next = try testDraw(&metal, &chain, 1200, 700);
    try testing.expectEqual(@as(usize, 1200), next.width);
    try testing.expectEqual(@as(u64, 2 * landing.surface.getAllocSize()), live.load(.monotonic));
}

test "host present: the landing gives back the idle targets at once and never waits for a frame in flight" {
    // Review of #82 (F2): the trim of a cleared capacity ran at the start of the landing draw and waited up to 8 ms
    // under the draw mutex for frames in flight, on the most visible frame of the gesture. It never waits: targets no
    // frame is drawing go back at once, and one in flight goes back when its frame completes (`frameDone`).
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    var device = try Device.initForTest();
    defer device.deinit();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    var chain = try Renderer.SwapChain.init(&metal, false);
    defer chain.deinit();

    for (0..swap_chain_count) |_| _ = try testDraw(&metal, &chain, 80, 60);
    _ = metal.setHostCapacity(160, 60);
    for (0..swap_chain_count) |i| _ = try testDraw(&metal, &chain, @intCast(100 + i), 60);
    // The last frame of the gesture is still in flight.
    const in_flight = try testCommit(&metal, &chain, 150, 60);
    var completed = false;
    defer if (!completed) chain.releaseFrame();
    try testing.expectEqual(@as(usize, 160), in_flight.width);

    _ = metal.setHostCapacity(0, 0);
    const io = global.io();
    const start: std.Io.Timestamp = .now(io, .awake);
    const released = chain.trim(&metal, 120, 60);
    const waited_ns = start.durationTo(.now(io, .awake)).nanoseconds;
    std.debug.print("host capacity: the landing trim took {d} ns with a frame in flight\n", .{waited_ns});
    // No wait (the old trim waited 8 ms for the frame in flight, then gave nothing back).
    try testing.expect(waited_ns < 4 * std.time.ns_per_ms);
    try testing.expect(released);
    // The two idle targets went back at once; the one in flight is untouched.
    for (&chain.frames) |*frame| {
        if (&frame.target == in_flight) {
            try testing.expectEqual(@as(usize, 160), frame.target.width);
        } else {
            try testing.expectEqual(@as(usize, 0), frame.target.width);
        }
    }

    // Its frame completes: its target goes back too, with no draw. No target is left.
    try testComplete(&metal, &chain, in_flight);
    completed = true;
    try testing.expectEqual(@as(usize, 0), in_flight.width);
    try testing.expectEqual(@as(u64, 0), metal.counters.target_bytes_live.load(.monotonic));
}

test "host present: a frame in flight at the landing gives back its capacity target when it completes, with no other draw" {
    // Review of #82 (F1): the clear wakes the renderer for one draw. When a frame of the gesture was still in flight
    // then (likely: a completed frame presents before it frees its slot, and that present takes the Core Animation lock
    // that main's landing commit holds), its capacity-sized target stayed until a later draw, and a terminal that draws
    // nothing more kept it. Its completion gives it back.
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    var device = try Device.initForTest();
    defer device.deinit();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    var chain = try Renderer.SwapChain.init(&metal, false);
    defer chain.deinit();
    const live = &metal.counters.target_bytes_live;

    // A pane of 1000 x 700 pixels grows toward 2000 (the capacity) while the key is held.
    for (0..swap_chain_count) |_| _ = try testDraw(&metal, &chain, 1000, 700);
    _ = metal.setHostCapacity(2000, 700);
    for (0..11) |i| _ = try testDraw(&metal, &chain, @intCast(1010 + 75 * i), 700);
    // The gesture's last frame is in flight when the host clears the capacity.
    const last = try testCommit(&metal, &chain, 1835, 700);
    _ = metal.setHostCapacity(0, 0);

    // The landing frame (the one draw the clear wakes) is committed; then the frames complete, in order. No other draw.
    const landing = try testCommit(&metal, &chain, 1200, 700);
    try testComplete(&metal, &chain, last);
    try testComplete(&metal, &chain, landing);

    const landed = live.load(.monotonic);
    std.debug.print(
        "host capacity: live target bytes {d} after the landing with a frame in flight (the pane's target: {d}), peak {d}\n",
        .{ landed, landing.surface.getAllocSize(), metal.counters.target_bytes_peak.load(.monotonic) },
    );
    try testing.expectEqual(@as(u64, landing.surface.getAllocSize()), landed);
    try testing.expectEqual(@as(usize, 1200), landing.width);
    try testExpectShows(&metal, landing);
    var empty: usize = 0;
    for (&chain.frames) |*frame| {
        if (frame.target.width == 0) empty += 1;
    }
    try testing.expectEqual(@as(usize, swap_chain_count - 1), empty);
}

test "host present: without a host capacity each new size makes a target of exactly that size" {
    // The default (no capacity, and cmux with its switch off) is unchanged: one new target per frame at a new size,
    // of exactly that size, shown whole, and no spare target is given back.
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    var device = try Device.initForTest();
    defer device.deinit();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    var chain = try Renderer.SwapChain.init(&metal, false);
    defer chain.deinit();
    const allocs = &metal.counters.target_allocs;

    for (0..swap_chain_count) |_| _ = try testDraw(&metal, &chain, 80, 60);
    const at_rest = allocs.load(.monotonic);
    for (0..6) |i| {
        const width: u32 = @intCast(81 + i);
        const target = try testDraw(&metal, &chain, width, 60);
        try testing.expectEqual(at_rest + i + 1, allocs.load(.monotonic));
        try testing.expectEqual(@as(usize, width), target.width);
        try testing.expectEqual(@as(usize, 60), target.height);
        try testExpectShows(&metal, target);
    }
    // A frame at the size its target already has keeps it.
    for (0..swap_chain_count) |_| _ = try testDraw(&metal, &chain, 86, 60);
    const settled = allocs.load(.monotonic);
    _ = try testDraw(&metal, &chain, 86, 60);
    try testing.expectEqual(settled, allocs.load(.monotonic));
    // A pane that shrinks keeps its larger spare targets until a frame is drawn into them: nothing is given back.
    _ = try testDraw(&metal, &chain, 70, 60);
    var held: u64 = 0;
    for (&chain.frames) |*frame| {
        try testing.expect(frame.target.width != 0);
        held += frame.target.surface.getAllocSize();
    }
    try testing.expectEqual(held, metal.counters.target_bytes_live.load(.monotonic));
}

test "host present: a frame in a capacity target is drawn only in its top-left drawn pixels" {
    // The draw side of a capacity target: the render pass draws the frame at its drawn size in the target's top-left
    // corner (viewport and scissor, `RenderPass.begin`), unstretched; the rest of the target stays clear. Without them
    // the background's full-screen triangle fills the whole, larger target.
    const testing = std.testing;
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    var device = try Device.initForTest();
    defer device.deinit();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    var library = try shaders.Shaders.init(testing.allocator, device.device, &.{}, .bgra8unorm);
    defer library.deinit(testing.allocator);
    const queue = device.device.msgSend(objc.Object, objc.sel("newCommandQueue"), .{});
    defer queue.release();

    // A capacity target of 8 x 8 pixels holding a frame drawn at 6 x 4 (`fitTarget` with a capacity).
    var target = try metal.initTarget(8, 8);
    defer target.deinit();
    target.drawn_width = 6;
    target.drawn_height = 4;

    var uniforms = std.mem.zeroes(shaders.Uniforms);
    uniforms.bg_color = .{ 255, 0, 0, 255 };
    var uniform_buffer = try Buffer(shaders.Uniforms).init(metal.uniformBufferOptions(), 1);
    defer uniform_buffer.deinit();
    try uniform_buffer.sync(&.{uniforms});

    const command_buffer = queue.msgSend(objc.Object, objc.sel("commandBuffer"), .{});
    {
        var pass = RenderPass.begin(.{
            .command_buffer = command_buffer,
            .attachments = &.{.{ .target = .{ .target = target }, .clear_color = .{ 0, 0, 0, 0 } }},
        });
        defer pass.complete();
        pass.step(.{
            .pipeline = library.pipelines.bg_color,
            .uniforms = uniform_buffer.buffer,
            .draw = .{ .type = .triangle, .vertex_count = 3 },
        });
    }
    command_buffer.msgSend(void, objc.sel("commit"), .{});
    command_buffer.msgSend(void, objc.sel("waitUntilCompleted"), .{});

    // The surface's rows top-down (Metal draws row 0 first): the background inside the top-left 6 x 4, clear outside.
    target.surface.lock();
    defer target.surface.unlock();
    const base = target.surface.getBaseAddress().?;
    const bytes_per_row = target.surface.getBytesPerRow();
    for (0..8) |y| {
        for (0..8) |x| {
            const alpha = base[y * bytes_per_row + x * 4 + 3];
            const drawn = x < 6 and y < 4;
            testing.expectEqual(@as(u8, if (drawn) 255 else 0), alpha) catch |err| {
                std.debug.print("surface pixel ({d}, {d}): alpha {d}\n", .{ x, y, alpha });
                return err;
            };
        }
    }
}
