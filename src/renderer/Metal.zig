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
const DrawablePresenter = @import("metal/DrawablePresenter.zig");
const PresentState = @import("metal/PresentState.zig");
const PresentedSink = @import("metal/PresentedSink.zig");
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

/// The drawable layer above `layer` that the renderer presents its frames
/// in, without the main thread.
presenter: DrawablePresenter,

/// The frame on screen, for `ghostty_surface_presented_frame`.
last_frame: LastFrame = .{},

/// Whether the presentation was purged (`setPresentation(.purge)`): the
/// next show sizes the drawables again. Main thread.
purged: bool = false,

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
/// Written on the main thread (after the drawables of that size are set),
/// read by `surfaceSize` on any thread: the renderer draws at it, and its
/// frames of another size are dropped (`PresentState.accepts`).
host_size: std.atomic.Value(u64) = .init(0),

/// macOS host-sized surfaces: the newest frame the renderer thread drew with
/// cells built at that frame's size (`Target.cells_fresh`), for the display
/// pass of a new host size to present in the same Core Animation transaction
/// as the view's new bounds (`presentHostSized`).
fresh: FreshFrame = .{},

/// Whether the renderer draws (its last `setVisible`). Written on the
/// renderer thread, read by the display pass on the main thread: a hidden
/// surface's display pass draws nothing.
visible_hint: std.atomic.Value(bool) = .init(true),

/// Frames drawn by the display pass on the main thread (the fallback), and
/// presents of a new host size: with the renderer's fresh frame, keeping the
/// last frame because the fresh one was not drawn yet, or refused because
/// the renderer had committed a newer frame since (render counters).
counters: HostFrameCounters = .{},

pub const HostFrameCounters = struct {
    display_passes: std.atomic.Value(u64) = .init(0),
    /// `ghostty_surface_present_host_frame` calls (the embedder's own
    /// pre-commit hook, for a layer whose display pass does not run).
    present_calls: std.atomic.Value(u64) = .init(0),
    main_draws: std.atomic.Value(u64) = .init(0),
    fresh_presents: std.atomic.Value(u64) = .init(0),
    late: std.atomic.Value(u64) = .init(0),
    superseded: std.atomic.Value(u64) = .init(0),
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
    /// The frame id of `surface` (PresentState.begin).
    sequence: u64 = 0,
};

/// A fresh frame taken for a present: the caller releases `surface`.
const Fresh = struct {
    surface: *IOSurface,
    sequence: u64,
};

pub const LastFrame = struct {
    /// Held only to swap the pointer and retain it; nothing waits under it.
    mutex: std.Io.Mutex = .init,
    /// Retained.
    surface: ?*IOSurface = null,
};

pub const Presentation = rendererpkg.Presentation;

pub fn init(
    alloc: Allocator,
    device: *const Device,
    opts: rendererpkg.Options,
) !Metal {
    comptime switch (builtin.os.tag) {
        .macos, .ios => {},
        else => @compileError("unsupported platform for Metal"),
    };

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

    // The embedder's presented callback (ghostty_surface_config_s).
    const sink = try PresentedSink.create(
        alloc,
        opts.rt_surface.presented_cb,
        opts.rt_surface.presented_userdata,
    );
    defer sink.release();
    var presenter = try DrawablePresenter.init(
        layer.layer,
        mtl_device,
        targetPixelFormat(opts.config.blending),
        info.scaleFactor,
        sink,
    );
    errdefer presenter.deinit();

    return .{
        .layer = layer,
        .presenter = presenter,
        .device = device,
        .queue = queue,
        .blending = opts.config.blending,
    };
}

fn targetPixelFormat(blending: configpkg.Config.AlphaBlending) mtl.MTLPixelFormat {
    // Using an `*_srgb` pixel format makes Metal gamma encode the pixels
    // written to it *after* blending, which means we get linear alpha
    // blending rather than gamma-incorrect blending.
    return if (blending.isLinear()) .bgra8unorm_srgb else .bgra8unorm;
}

/// After the renderer thread stopped and its frames completed. Main thread.
pub fn deinit(self: *Metal) void {
    self.presenter.deinit();
    self.queue.release();
    if (self.fresh.surface) |surface| surface.release();
    if (self.last_frame.surface) |surface| surface.release();

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
    self.presenter.syncGeometry(layer);
    self.syncDrawableSize();
}

/// The drawables follow the size the renderer draws at (`surfaceSize`).
/// Main thread.
fn syncDrawableSize(self: *Metal) void {
    const size = self.surfaceSize() catch return;
    if (size.width == 0 or size.height == 0) return;
    self.presenter.setDrawableSize(PresentState.pack(size.width, size.height));
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
    if (self.host_size.load(.acquire) == value) return;
    // Drawables of the new size first: a frame the renderer draws at the
    // new host size must find them, or it is dropped as a wrong-size frame.
    if (value != 0) self.presenter.setDrawableSize(value);
    self.host_size.store(value, .release);
    if (value == 0) self.syncDrawableSize();
    // A fresh frame kept from an earlier size is not this size's frame,
    // even when the sizes are equal (a drag back): only a frame published
    // after this call may be presented for it.
    self.dropFresh();
    _ = self.fresh.generation.fetchAdd(1, .acq_rel);
    self.fresh.armed.store(value != 0, .release);
    self.layer.layer.setProperty("needsDisplayOnBoundsChange", value == 0);
    // One synchronous frame at the new target size (or at the bounds again).
    self.layer.layer.msgSend(void, objc.sel("setNeedsDisplay"), .{});
}

/// iOS only: detach the IOSurfaceLayer from the embedder's view before
/// the renderer's memory is freed.
///
/// The layer keeps raw pointers to this renderer (display callback and
/// context) in its instance variables. On iOS it is a sublayer of the
/// embedder's view, which outlives the surface, so a Core Animation pass
/// on the main thread after the free would call into freed memory.
/// Clearing the pointers, the contents and the sublayer link (the surface
/// is freed on the main thread), while they still name this renderer,
/// closes that window. A
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
        if (renderer.api.presentHostSized()) return;
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
pub fn initTarget(self: *const Metal, width: usize, height: usize) !Target {
    return Target.init(.{
        .device = self.device.device,
        .pixel_format = targetPixelFormat(self.blending),
        .storage_mode = self.device.default_storage_mode,
        .width = width,
        .height = height,
    });
}

/// Renderer thread, before `drawFrame` takes the draw lock: the drawable
/// for the frame, so a wait for one never holds the lock that a main-thread
/// draw takes (DrawablePresenter.acquire).
pub fn acquirePresentable(self: *Metal) void {
    self.presenter.acquire();
}

/// Renderer thread, after `drawFrame` released the draw lock.
pub fn releasePresentable(self: *Metal) void {
    self.presenter.releaseUnused();
}

/// Renderer thread, before the frame's command buffer commits: encodes the
/// frame's copy into a drawable and its present (DrawablePresenter.encode).
pub fn encodePresent(self: *Metal, buffer: objc.Object, target: *const Target) PresentState.Ticket {
    return self.presenter.encode(buffer, target.texture, target.width, target.height);
}

/// Present the provided target. `sync`: a frame drawn on the main thread,
/// shown in its transaction. Otherwise the GPU completion thread, with the
/// `ticket` that `encodePresent` returned: the drawable present is already
/// encoded, so nothing is posted to the main thread for the frame.
pub inline fn present(self: *Metal, target: Target, sync: bool, ticket: PresentState.Ticket) !void {
    if (sync) {
        // Under the draw lock, where every frame gets its id: the newest.
        _ = self.presentOnMain(target.surface, self.presenter.state.begin().sequence);
        return;
    }
    if (comptime builtin.os.tag == .macos) {
        if (target.cells_fresh and self.fresh.armed.load(.acquire) and
            target.size_generation == self.fresh.generation.load(.acquire) and
            self.host_size.load(.acquire) != 0) self.publishFresh(target.surface, ticket.sequence);
    }
    if (!ticket.encoded) return;
    self.setLastFrame(target.surface);
    const size = PresentState.pack(target.surface.getWidth(), target.surface.getHeight());
    const generation = self.presenter.presented(ticket, size) orelse return;
    // The overlay is hidden behind an older frame main presented: ask the
    // main thread to show it through the app mailbox, which the embedder
    // drains at its own tick. Never wait on this thread.
    const renderer: *align(1) Renderer = @fieldParentPtr("api", self);
    if (renderer.surface_mailbox.push(.present_reveal, .instant) == 0) {
        self.presenter.state.revealPostFailed(generation);
    }
}

/// Sets `surface`, frame `sequence`, as the root layer's contents in the
/// main thread's transaction; the overlay hides in the same transaction
/// until the renderer's next frame. Returns false, and changes nothing, when
/// the renderer committed a newer frame (PresentState.cover). A hidden
/// presentation shows nothing: the frame is kept for the next show. Main
/// thread.
fn presentOnMain(self: *Metal, surface: *IOSurface, sequence: u64) bool {
    const state = &self.presenter.state;
    if (!state.presenting.load(.acquire)) {
        if (!state.commit(sequence)) return false;
        self.setLastFrame(surface);
        return true;
    }
    const size = PresentState.pack(surface.getWidth(), surface.getHeight());
    if (!self.presenter.cover(self.layer.layer, size, sequence)) return false;
    self.layer.setContents(surface);
    self.setLastFrame(surface);
    return true;
}

/// The renderer presented a frame encoded after main's last present (the
/// `present_reveal` surface message). Main thread.
pub fn revealPresented(self: *Metal) void {
    self.presenter.reveal(self.layer.layer);
}

/// Any thread: `surface` is the frame on screen now (null: none).
fn setLastFrame(self: *Metal, surface: ?*IOSurface) void {
    if (surface) |s| s.retain();
    const io = global.io();
    const old = old: {
        self.last_frame.mutex.lockUncancelable(io);
        defer self.last_frame.mutex.unlock(io);
        const old = self.last_frame.surface;
        self.last_frame.surface = surface;
        break :old old;
    };
    if (old) |o| o.release();
}

/// The frame on screen, retained (+1), or null before the first frame or
/// after a purge (`ghostty_surface_presented_frame`). Any thread.
pub fn presentedFrame(self: *Metal) ?*IOSurface {
    const io = global.io();
    self.last_frame.mutex.lockUncancelable(io);
    defer self.last_frame.mutex.unlock(io);
    const surface = self.last_frame.surface orelse return null;
    surface.retain();
    return surface;
}

/// `ghostty_surface_set_presentation`. Main thread. Returns true when the
/// renderer must draw a frame (shown again): the caller queues a render.
///   * hidden: nothing is presented and the layers show nothing.
///   * shown: the last frame shows at once (the root's contents) and the
///     renderer's next frame takes over.
///   * purge: hidden, and the kept frames and the drawable pool are freed.
pub fn setPresentation(self: *Metal, presentation: Presentation) bool {
    const state = &self.presenter.state;
    switch (presentation) {
        .hidden, .purge => {
            state.presenting.store(false, .release);
            self.presenter.hideOverlay(state.committed.load(.seq_cst));
            self.layer.setContents(null);
            if (presentation == .purge) {
                self.purged = true;
                self.setLastFrame(null);
                self.dropFresh();
                self.presenter.purgeDrawables();
            }
            return false;
        },
        .shown => {
            if (state.presenting.load(.acquire)) return false;
            if (self.purged) {
                self.purged = false;
                self.syncDrawableSize();
            }
            // A new hide generation: only a frame newer than the last one
            // shows the overlay again; until then the root shows the last frame.
            self.presenter.hideOverlay(state.committed.load(.seq_cst));
            if (self.presentedFrame()) |surface| {
                defer surface.release();
                self.layer.setContents(surface);
            }
            state.presenting.store(true, .release);
            return true;
        },
    }
}

/// Keeps `surface`, frame `sequence`, as the newest fresh frame for the next
/// present of the host size. GPU completion thread (one queue's frames
/// complete in commit order, so each publish is newer than the last).
fn publishFresh(self: *Metal, surface: *IOSurface, sequence: u64) void {
    const io = global.io();
    surface.retain();
    const old = old: {
        self.fresh.mutex.lockUncancelable(io);
        defer self.fresh.mutex.unlock(io);
        const old = self.fresh.surface;
        self.fresh.surface = surface;
        self.fresh.sequence = sequence;
        break :old old;
    };
    if (old) |o| o.release();
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

/// The fresh frame if it has `width` x `height` pixels (retained; the caller
/// releases it). A fresh frame of another size stays for its own pass.
fn takeFresh(self: *Metal, width: usize, height: usize) ?Fresh {
    const io = global.io();
    self.fresh.mutex.lockUncancelable(io);
    defer self.fresh.mutex.unlock(io);
    const surface = self.fresh.surface orelse return null;
    if (surface.getWidth() != width or surface.getHeight() != height) return null;
    self.fresh.surface = null;
    self.fresh.armed.store(false, .release);
    return .{ .surface = surface, .sequence = self.fresh.sequence };
}

/// The display pass of a host-sized surface, or the embedder's pre-commit
/// present (main thread): present the renderer thread's frame at the host
/// size, drawn with cells rebuilt for that size (the text reflowed to the new
/// grid, the reflow preview included), in this Core Animation transaction,
/// only if it is drawn already. Never waits: a frame not drawn yet keeps the
/// last frame (counted late) and lands in the overlay when it completes.
/// Never draws on the main thread: the cells the main thread could draw with
/// are the previous size's, so a frame drawn here would show the old text at
/// the new size. A fresh frame older than one the renderer committed since is
/// not presented (PresentState.cover). Returns false when the display pass
/// should draw itself: not host-sized, or nothing presented yet (the first
/// frame).
///
/// Chromium does the same at a resize: the browser shows the newest frame the
/// renderer submitted (a fallback surface) and never blocks the UI thread on
/// the new size's frame (content/browser/renderer_host/delegated_frame_host.cc,
/// `EmbedSurface`).
pub fn presentHostSized(self: *Metal) bool {
    const host = self.host_size.load(.acquire);
    if (host == 0) return false;
    // Hidden: nothing to draw now (the renderer draws when shown again),
    // and drawing here would rebuild the released swap chain.
    if (!self.visible_hint.load(.acquire)) return true;
    const width: usize = @intCast(host >> 32);
    const height: usize = @intCast(host & 0xffff_ffff);
    const shown = self.shownSize();
    if (shown == 0) return false;
    if (shown == PresentState.pack(width, height)) {
        // The renderer thread's frame at this size already landed.
        if (self.takeFresh(width, height)) |fresh| fresh.surface.release();
        return true;
    }
    const fresh = self.takeFresh(width, height) orelse {
        _ = self.counters.late.fetchAdd(1, .monotonic);
        return true;
    };
    defer fresh.surface.release();
    if (self.presentOnMain(fresh.surface, fresh.sequence)) {
        _ = self.counters.fresh_presents.fetchAdd(1, .monotonic);
    } else {
        _ = self.counters.superseded.fetchAdd(1, .monotonic);
    }
    return true;
}

/// The pixel size of the frame on screen, 0 before the first. Main thread.
fn shownSize(self: *const Metal) u64 {
    return self.presenter.shownSize(self.layer.layer);
}

/// The host size generation a frame drawn now belongs to (Target.size_generation).
pub fn sizeGeneration(self: *const Metal) u64 {
    return self.fresh.generation.load(.acquire);
}

/// The surface was shown or hidden (`ghostty_surface_set_occlusion`, main
/// thread). Shown: a frame at the host size is due now (it was resized while
/// hidden, or its last frame was purged), so the present is armed for a frame
/// drawn from here on.
pub fn setShownFromMain(self: *Metal, visible: bool) void {
    if (visible and self.host_size.load(.acquire) != 0) {
        self.dropFresh();
        _ = self.fresh.generation.fetchAdd(1, .acq_rel);
        self.fresh.armed.store(true, .release);
    }
    self.setVisibleHint(visible);
}

/// The renderer started or stopped drawing (`setVisible`). Renderer thread.
pub fn setVisibleHint(self: *Metal, visible: bool) void {
    self.visible_hint.store(visible, .release);
    // A hidden surface holds no frame for a present that cannot come.
    if (!visible) self.dropFresh();
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
