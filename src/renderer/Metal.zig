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

/// Whether the renderer draws (its last `setVisible`). Written on the
/// renderer thread, read by the display pass on the main thread: a hidden
/// surface's display pass draws nothing.
visible_hint: std.atomic.Value(bool) = .init(true),

/// macOS host-sized surfaces (`ghostty_surface_set_host_present`): in the
/// synced mode, the renderer keeps a full-screen program's last frame after
/// a new host size until the program redrew at the new grid or the bound
/// passed (`resize_hold_bound_ns`). Main thread writes; the GPU completion
/// thread reads.
host_present: std.atomic.Value(apprt.HostPresent) = .init(.renderer),

/// The resize hold of the current host size runs (synced mode): a frame of
/// that size on the alternate screen without the program's redraw at its
/// grid is not shown before `resize_hold_until_ns`. Armed by a new host size
/// (`setHostDrawableSize`, main thread); disarmed when a frame of the host
/// size is shown (GPU completion thread), when the renderer thread draws at
/// the bound (`resizeHoldEnds`) or at a reveal (`setShownFromMain`).
resize_hold_armed: std.atomic.Value(bool) = .init(false),

/// When the resize hold ends, on the awake clock (nanoseconds). Set with
/// the hold, moved by a grid the PTY owner announced (`restartResizeHold`).
resize_hold_until_ns: std.atomic.Value(i64) = .init(0),

/// The resize hold's bound (`default_resize_hold_bound_ns`; tests set a
/// longer one).
resize_hold_bound_ns: i64 = default_resize_hold_bound_ns,

/// Numbers presented frames in completion order, so a frame the main thread
/// presents late never replaces a newer one presented off main. GPU
/// completion thread.
present_seq: std.atomic.Value(u64) = .init(0),

/// Where the frames of a host-sized surface went (render counters).
counters: HostFrameCounters = .{},

pub const HostFrameCounters = struct {
    display_passes: std.atomic.Value(u64) = .init(0),
    /// Frames presented from the completion thread (content only, `setSurfaceOffMain`).
    off_main_presents: std.atomic.Value(u64) = .init(0),
    /// Frames drawn by the display pass on the main thread (the first frame, a surface that follows its bounds).
    main_draws: std.atomic.Value(u64) = .init(0),
    /// Frames of the host size handed to the main thread's present (a size change, or a frame while main's commit of one
    /// is pending).
    size_presents: std.atomic.Value(u64) = .init(0),
    /// Frames of a new host size not shown because the resize hold runs (synced mode).
    held: std.atomic.Value(u64) = .init(0),
    /// Frames handed to the main thread's present (`IOSurfaceLayer.setSurface`): from the GPU completion thread, one
    /// block on the main queue each.
    main_presents: std.atomic.Value(u64) = .init(0),
};

/// The resize hold's bound in refreshes (design: `resizeHoldTicks` of cmux's
/// hold, 3), and the refresh it counts: 120 Hz, the panel the bound was set
/// on. A 60 Hz display holds for 3 of its 120 Hz refreshes, 1.5 of its own.
const resize_hold_refreshes = 3;
const resize_hold_refresh_ns = std.time.ns_per_s / 120;
const default_resize_hold_bound_ns: i64 = resize_hold_refreshes * resize_hold_refresh_ns;

pub fn init(
    alloc: Allocator,
    device: *const Device,
    opts: rendererpkg.Options,
) !Metal {
    comptime switch (builtin.target.os.tag) {
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
    switch (comptime builtin.target.os.tag) {
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
/// clips the view), and new output still draws at the held size. A new size
/// draws at once on the renderer thread (`Thread` resize), and its frame
/// shows through the main thread (`present`), in the synced mode after the
/// resize hold for a full-screen program.
pub fn setHostDrawableSize(self: *Metal, enabled: bool, width_px: u32, height_px: u32) void {
    if (comptime builtin.os.tag != .macos) return;
    const max = self.device.max_texture_size;
    const value: u64 = if (enabled and width_px > 0 and height_px > 0)
        (@as(u64, @min(width_px, max)) << 32) | @min(height_px, max)
    else
        0;
    if (self.host_size.swap(value, .acq_rel) == value) return;
    self.layer.setHostSize(value);
    self.layer.layer.setProperty("needsDisplayOnBoundsChange", value == 0);
    // The hold of the new size starts now. The renderer thread wakes at its
    // bound (`resizeHoldWakeMs`).
    if (value != 0 and self.host_present.load(.acquire) == .renderer_synced) {
        self.resize_hold_until_ns.store(nowNs() + self.resize_hold_bound_ns, .release);
        self.resize_hold_armed.store(true, .release);
    } else {
        self.resize_hold_armed.store(false, .release);
    }
    // The renderer thread draws and presents a new host size itself. A
    // display pass draws only a first frame (nothing shown yet) or a surface
    // that follows its bounds again. Only the main thread makes the layer
    // show nothing, so this read needs no lock.
    if (value != 0 and self.layer.layer.getProperty(?*anyopaque, "contents") != null) return;
    self.layer.layer.msgSend(void, objc.sel("setNeedsDisplay"), .{});
}

/// macOS host-sized surfaces: the embedder's display scale (`ghostty_surface_set_content_scale`). The layer takes it
/// with the first frame at the host size, in one Core Animation transaction, so a frame never shows at a scale it was
/// not drawn at (`IOSurfaceLayer.setContentScale`). Main thread.
pub fn setHostContentScale(self: *Metal, scale: f64) void {
    if (comptime builtin.os.tag != .macos) return;
    self.layer.setContentScale(scale);
}

/// Installs the embedder's present callback (`ghostty_surface_set_present_callback`), or with null removes it: each
/// frame that becomes the layer's contents is reported, with its pixel size and why it changed (content or resize),
/// on the thread that sets it. Main thread.
pub fn setPresentCallback(self: *Metal, cb: ?apprt.PresentCallback, userdata: ?*anyopaque) void {
    self.layer.setPresentCallback(cb, userdata);
}

/// macOS host-sized surfaces (`ghostty_surface_set_host_present`): who
/// decides when a frame of a new host size shows. `.renderer` shows it when
/// drawn; `.renderer_synced` keeps a full-screen program's last frame until
/// its redraw at the new grid or the bound (`present`). Main thread.
pub fn setHostPresent(self: *Metal, mode: apprt.HostPresent) void {
    if (comptime builtin.os.tag != .macos) return;
    if (self.host_present.swap(mode, .acq_rel) == mode) return;
    if (mode != .renderer_synced) self.resize_hold_armed.store(false, .release);
}

/// A grid the PTY owner announced for this surface (`ghostty_surface_set_grid`,
/// a mirror surface): its program learns the grid now, so the bound of a
/// running resize hold counts from now. Any thread.
pub fn restartResizeHold(self: *Metal) void {
    if (comptime builtin.os.tag != .macos) return;
    if (!self.resize_hold_armed.load(.acquire)) return;
    self.resize_hold_until_ns.store(nowNs() + self.resize_hold_bound_ns, .release);
}

/// The renderer thread's wake for the resize hold (`GenericRenderer.animationWake`):
/// milliseconds until its bound while it runs (0 once due), null otherwise.
pub fn resizeHoldWakeMs(self: *const Metal) ?u64 {
    if (comptime builtin.os.tag != .macos) return null;
    if (!self.resize_hold_armed.load(.acquire)) return null;
    const remaining = self.resize_hold_until_ns.load(.acquire) - nowNs();
    if (remaining <= 0) return 0;
    return @intCast(std.math.divCeil(i64, remaining, std.time.ns_per_ms) catch 0);
}

/// The resize hold reached its bound: it ends here, once, and the frame drawn
/// now shows the size (with the program's last picture). Renderer thread, at
/// each draw (`GenericRenderer.drawFrame`).
pub fn resizeHoldEnds(self: *Metal) bool {
    if (comptime builtin.os.tag != .macos) return false;
    if (!self.resize_hold_armed.load(.acquire)) return false;
    if (nowNs() < self.resize_hold_until_ns.load(.acquire)) return false;
    return self.resize_hold_armed.swap(false, .acq_rel);
}

/// The awake clock in nanoseconds.
fn nowNs() i64 {
    const now: std.Io.Timestamp = .now(global.io(), .awake);
    return @intCast(now.nanoseconds);
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
///
/// Every platform: the embedder's present callback goes first. Its userdata
/// may be freed once `ghostty_surface_free` returns, while a frame queued for
/// the main thread before the free (`setSurfaceCallback`) can still reach the
/// layer the embedder's view keeps. Frames in flight on the GPU completion
/// thread finish before the free returns (`releaseGpuResources` waits).
pub fn prepareDeinit(self: *Metal) void {
    self.layer.setPresentCallback(null, null);
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
        if (!renderer.api.displayPassDraws()) return;
    }
    _ = renderer.api.counters.main_draws.fetchAdd(1, .monotonic);
    renderer.drawFrame(true) catch |err| {
        log.warn("Error drawing frame in display callback, err={}", .{err});
    };
}

/// Whether a display pass draws on the main thread: not for a host-sized
/// surface that shows a frame (the renderer thread draws and presents each
/// new size itself, `present`) or that is hidden (drawing would rebuild the
/// released swap chain). A first frame (nothing shown yet) and a surface
/// that follows its bounds draw. Main thread.
fn displayPassDraws(self: *Metal) bool {
    if (self.host_size.load(.acquire) == 0) return true;
    if (!self.visible_hint.load(.acquire)) return false;
    return self.layer.shownSize() == null;
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
}

/// Present the provided target.
pub inline fn present(self: *Metal, target: Target, sync: bool) !void {
    if (sync) {
        self.layer.setSurfaceSync(target.surface);
        return;
    }
    const seq = self.present_seq.fetchAdd(1, .monotonic) + 1;
    if (comptime builtin.os.tag == .macos) {
        const host = self.host_size.load(.acquire);
        if (host != 0) {
            const at_host = (host >> 32) == target.width and (host & 0xffff_ffff) == target.height;
            // A frame at the shown size goes to the screen from this (completion) thread: a terminal echo, a scroll
            // or output never waits for main, during a resize hold too.
            if (self.layer.setSurfaceOffMain(target.surface, seq)) {
                _ = self.counters.off_main_presents.fetchAdd(1, .monotonic);
                if (at_host) self.resize_hold_armed.store(false, .release);
                return;
            }
            if (at_host) {
                // The synced mode's resize hold: a full-screen program's frame of a new size without its redraw at
                // the new grid is not shown (nor handed to main) until the bound; the layer keeps the last frame,
                // top-left, clipped or padded, never stretched. The renderer thread draws again at the bound.
                if (self.holdsFrame(target)) {
                    _ = self.counters.held.fetchAdd(1, .monotonic);
                    return;
                }
                self.resize_hold_armed.store(false, .release);
                _ = self.counters.size_presents.fetchAdd(1, .monotonic);
            }
        }
    }
    // Through main: a new size shows in main's transaction, with the bounds of that pass, and frames at it go through
    // main until that commit (`IOSurfaceLayer.markMainSizeChange`). Main drops a frame of a size the host no longer
    // has.
    _ = self.counters.main_presents.fetchAdd(1, .monotonic);
    try self.layer.setSurface(target.surface, seq);
}

/// Whether the resize hold keeps `target`, a frame of the host size that the
/// layer cannot show off main: the synced mode's hold runs and has not
/// reached its bound, the frame is of the alternate screen (a full-screen
/// program) and the program has not redrawn at its grid, and the layer shows
/// a frame of another size (a first frame, or one held only for main's
/// commit, is never kept). GPU completion thread.
fn holdsFrame(self: *Metal, target: Target) bool {
    if (!target.alternate or target.program_fresh) return false;
    if (self.host_present.load(.acquire) != .renderer_synced) return false;
    if (!self.resize_hold_armed.load(.acquire)) return false;
    if (nowNs() >= self.resize_hold_until_ns.load(.acquire)) return false;
    const shown = self.layer.shownSize() orelse return false;
    return shown.width != target.width or shown.height != target.height;
}

/// The surface was shown or hidden (`ghostty_surface_set_occlusion`, main
/// thread). Shown: the frame due now was resized while hidden or replaces a
/// purged one; the program had time to redraw, so no resize hold keeps it.
pub fn setShownFromMain(self: *Metal, visible: bool) void {
    if (visible) self.resize_hold_armed.store(false, .release);
    self.setVisibleHint(visible);
}

/// The renderer started or stopped drawing (`setVisible`). Renderer thread.
pub fn setVisibleHint(self: *Metal, visible: bool) void {
    self.visible_hint.store(visible, .release);
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
/// touch only the layer and the host size.
fn testMetal(device: *const Device) !Metal {
    return .{
        .layer = try IOSurfaceLayer.init(),
        .device = device,
        .queue = undefined,
        .blending = .native,
        // A bound no test reaches by itself: a test ends a hold by moving `resize_hold_until_ns`.
        .resize_hold_bound_ns = 60 * std.time.ns_per_s,
    };
}

fn testDeinit(self: *Metal) void {
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

fn testIsMainThread() bool {
    return objc.getClass("NSThread").?.msgSend(bool, "isMainThread", .{});
}

/// What the present callback saw (the present callback tests): the last report and the number of calls.
const TestPresents = struct {
    calls: u32 = 0,
    last: apprt.Present = undefined,

    fn record(userdata: ?*anyopaque, report: *const apprt.Present) callconv(.c) void {
        const self: *TestPresents = @ptrCast(@alignCast(userdata.?));
        self.calls += 1;
        self.last = report.*;
    }
};

test "present callback: a present at size S reports S and the reason content" {
    const testing = std.testing;
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    const shown = try testSurface(80, 60);
    defer shown.release();
    const drawn = try testSurface(80, 60);
    defer drawn.release();
    metal.layer.setSurfaceSync(shown);
    metal.setHostDrawableSize(true, 80, 60);

    var presents: TestPresents = .{};
    metal.setPresentCallback(&TestPresents.record, &presents);
    // The renderer thread's next frame at the shown size S (output, an echo, a scroll): it goes to the layer off main,
    // and the callback reports S, the reason content and the frame's sequence number.
    try metal.present(testFrame(drawn, .{}), false);
    try testing.expectEqual(@as(u64, 1), metal.counters.off_main_presents.load(.acquire));
    try testing.expectEqual(@as(u32, 1), presents.calls);
    try testing.expectEqual(@as(u32, 80), presents.last.width_px);
    try testing.expectEqual(@as(u32, 60), presents.last.height_px);
    try testing.expectEqual(apprt.PresentReason.content, presents.last.reason);
    try testing.expectEqual(@as(u64, 1), presents.last.seq);
    try testing.expect(presents.last.host_time != 0);
}

test "present callback: a frame of a new size reports the reason resize, and a removed callback hears nothing" {
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    const shown = try testSurface(80, 60);
    defer shown.release();
    const resized = try testSurface(120, 60);
    defer resized.release();
    const later = try testSurface(120, 60);
    defer later.release();

    var presents: TestPresents = .{};
    metal.setPresentCallback(&TestPresents.record, &presents);
    // The first frame (a display pass on main): nothing was shown, so it is a resize, with no renderer sequence.
    metal.layer.setSurfaceSync(shown);
    try testing.expectEqual(@as(u32, 1), presents.calls);
    try testing.expectEqual(apprt.PresentReason.resize, presents.last.reason);
    try testing.expectEqual(@as(u64, 0), presents.last.seq);

    // A new host size: its frame goes through the main thread (on main here, at once) and reports its size.
    metal.setHostDrawableSize(true, 120, 60);
    try metal.present(testFrame(resized, .{}), false);
    try testing.expectEqual(@as(u32, 2), presents.calls);
    try testing.expectEqual(@as(u32, 120), presents.last.width_px);
    try testing.expectEqual(apprt.PresentReason.resize, presents.last.reason);

    // Removed: the next frame still shows, and nothing is reported.
    metal.setPresentCallback(null, null);
    try metal.present(testFrame(later, .{}), false);
    try testing.expectEqual(@as(?usize, 120), testShownWidth(&metal));
    try testing.expectEqual(@as(u32, 2), presents.calls);
}

test "present callback: a frame dropped at the wrong size is not reported" {
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    const shown = try testSurface(80, 60);
    defer shown.release();
    const stale = try testSurface(100, 60);
    defer stale.release();
    metal.layer.setSurfaceSync(shown);
    metal.setHostDrawableSize(true, 80, 60);

    var presents: TestPresents = .{};
    metal.setPresentCallback(&TestPresents.record, &presents);
    // A late frame of a size the host no longer has: the main-thread present drops it, so it never reaches the layer.
    try metal.present(testFrame(stale, .{}), false);
    try testing.expectEqual(@as(?usize, 80), testShownWidth(&metal));
    try testing.expectEqual(@as(u32, 0), presents.calls);
}

test "present callback: a frame shown after the renderer goes is not reported" {
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    const late = try testSurface(80, 60);
    defer late.release();

    var presents: TestPresents = .{};
    metal.setPresentCallback(&TestPresents.record, &presents);
    // The surface goes (`ghostty_surface_free`): its userdata may be freed once free returns, but a frame queued for
    // the main thread before it (`setSurfaceCallback`) can still reach the layer, which the embedder's view keeps.
    metal.prepareDeinit();
    metal.layer.setSurfaceSync(late);
    try testing.expectEqual(@as(?usize, 80), testShownWidth(&metal));
    try testing.expectEqual(@as(u32, 0), presents.calls);
}

test "host present: a new host size asks a display pass only while nothing is shown" {
    const testing = std.testing;
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    metal.setHostDrawableSize(true, 80, 60);
    // Nothing shown: the display pass draws the first frame.
    try testing.expect(metal.layer.layer.getProperty(bool, "needsDisplay"));
    const shown = try testSurface(80, 60);
    defer shown.release();
    metal.layer.setSurfaceSync(shown);
    metal.layer.layer.msgSend(void, objc.sel("displayIfNeeded"), .{});
    metal.setHostDrawableSize(true, 120, 60);
    // The renderer thread draws and presents the new size: no display pass draws on main.
    try testing.expect(!metal.layer.layer.getProperty(bool, "needsDisplay"));
    try testing.expect(!metal.displayPassDraws());
}

test "host present: a frame of a size the host no longer has goes through main, which drops it" {
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    const shown = try testSurface(80, 60);
    defer shown.release();
    testSynced(&metal, shown);
    metal.setHostDrawableSize(true, 120, 60);
    const stale = try testSurface(100, 60);
    defer stale.release();
    try metal.present(testFrame(stale, .{ .alternate = true }), false);
    try testing.expectEqual(@as(?usize, 80), testShownWidth(&metal));
    try testing.expectEqual(@as(u64, 0), metal.counters.held.load(.acquire));
}

/// Turns the main run loop once (Core Animation's commit, then `IOSurfaceLayer`'s observer after it).
fn testRunMainLoopOnce() void {
    _ = macos.c.CFRunLoopRunInMode(macos.c.kCFRunLoopDefaultMode, 0, 0);
}

/// A frame the renderer drew at `surface`'s size, on the primary or the alternate screen, with or without the
/// program's redraw at its grid.
fn testFrame(surface: *IOSurface, flags: struct { alternate: bool = false, program_fresh: bool = false }) Target {
    return .{
        .surface = surface,
        .texture = undefined,
        .width = surface.getWidth(),
        .height = surface.getHeight(),
        .alternate = flags.alternate,
        .program_fresh = flags.program_fresh,
    };
}

/// A synced host-sized surface that shows an 80x60 frame, committed (frames at that size go off main).
fn testSynced(metal: *Metal, shown: *IOSurface) void {
    metal.setHostPresent(.renderer_synced);
    metal.setHostDrawableSize(true, 80, 60);
    metal.layer.setSurfaceSync(shown);
    testRunMainLoopOnce();
}

test "resize sync: a scroll and an output frame during a resize hold are never routed through main" {
    // ghostty-integration step 4 (cmux GI RENDERER SYNC): with the hold in cmux (P1-P8), Ghostty sent every frame
    // through main until the embedder reported its commit (P3), so a resize policy touched scroll and output frames.
    // In the synced mode the renderer holds only a TUI's frame of a new size, on its own thread: no frame of the hold
    // goes to a main-queue block, and a frame at the shown size goes off main.
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    const shown = try testSurface(80, 60);
    defer shown.release();
    testSynced(&metal, shown);

    // A TUI's pane grows: its program has not redrawn at the new grid.
    metal.setHostDrawableSize(true, 120, 60);
    const output = try testSurface(120, 60);
    defer output.release();
    const scroll = try testSurface(120, 60);
    defer scroll.release();
    try metal.present(testFrame(output, .{ .alternate = true }), false);
    try metal.present(testFrame(scroll, .{ .alternate = true }), false);
    try testing.expectEqual(@as(u64, 0), metal.counters.main_presents.load(.acquire));
    try testing.expectEqual(@as(u64, 2), metal.counters.held.load(.acquire));
    try testing.expectEqual(@as(?usize, 80), testShownWidth(&metal));

    // The drag comes back to the shown size during the hold: its output goes off main at once.
    metal.setHostDrawableSize(true, 80, 60);
    const back = try testSurface(80, 60);
    defer back.release();
    try metal.present(testFrame(back, .{ .alternate = true }), false);
    try testing.expectEqual(@as(u64, 1), metal.counters.off_main_presents.load(.acquire));
    try testing.expectEqual(@as(u64, 0), metal.counters.main_presents.load(.acquire));

    // It grows again and the program redraws at the new grid: that frame changes the shown size, once, on main.
    metal.setHostDrawableSize(true, 120, 60);
    const redrawn = try testSurface(120, 60);
    defer redrawn.release();
    try metal.present(testFrame(redrawn, .{ .alternate = true, .program_fresh = true }), false);
    try testing.expectEqual(@as(u64, 1), metal.counters.main_presents.load(.acquire));
    try testing.expectEqual(@as(?usize, 120), testShownWidth(&metal));

    // After main's commit, output and scroll at that size go off main, with no report from the embedder.
    testRunMainLoopOnce();
    const output2 = try testSurface(120, 60);
    defer output2.release();
    const scroll2 = try testSurface(120, 60);
    defer scroll2.release();
    try metal.present(testFrame(output2, .{ .alternate = true }), false);
    try metal.present(testFrame(scroll2, .{ .alternate = true }), false);
    try testing.expectEqual(@as(u64, 1), metal.counters.main_presents.load(.acquire));
    try testing.expectEqual(@as(u64, 3), metal.counters.off_main_presents.load(.acquire));
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(scroll2)), metal.layer.layer.getProperty(?*anyopaque, "contents"));
}

test "resize sync: the primary screen shows a frame of a new host size at once" {
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    const shown = try testSurface(80, 60);
    defer shown.release();
    testSynced(&metal, shown);

    metal.setHostDrawableSize(true, 120, 60);
    const reflowed = try testSurface(120, 60);
    defer reflowed.release();
    try metal.present(testFrame(reflowed, .{}), false);
    try testing.expectEqual(@as(?usize, 120), testShownWidth(&metal));
    try testing.expectEqual(@as(u64, 0), metal.counters.held.load(.acquire));
    // The size's frame is up: no redraw waits for the bound.
    try testing.expectEqual(@as(?u64, null), metal.resizeHoldWakeMs());
}

test "resize sync: the alternate screen keeps the last frame until the program's redraw or the bound" {
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    const shown = try testSurface(80, 60);
    defer shown.release();
    testSynced(&metal, shown);

    metal.setHostDrawableSize(true, 120, 60);
    const busy = try testSurface(120, 60);
    defer busy.release();
    try metal.present(testFrame(busy, .{ .alternate = true }), false);
    try testing.expectEqual(@as(?usize, 80), testShownWidth(&metal));
    // The renderer thread wakes at the bound to draw the size anyway.
    try testing.expect(metal.resizeHoldWakeMs() != null);
    try testing.expect(!metal.resizeHoldEnds());

    // The bound passed (the program did not redraw): the hold ends once, and the next frame shows the size.
    metal.resize_hold_until_ns.store(0, .release);
    try testing.expectEqual(@as(?u64, 0), metal.resizeHoldWakeMs());
    try testing.expect(metal.resizeHoldEnds());
    try testing.expect(!metal.resizeHoldEnds());
    try testing.expectEqual(@as(?u64, null), metal.resizeHoldWakeMs());
    const late = try testSurface(120, 60);
    defer late.release();
    try metal.present(testFrame(late, .{ .alternate = true }), false);
    try testing.expectEqual(@as(?usize, 120), testShownWidth(&metal));
}

test "resize sync: a grid the PTY owner announced restarts the bound" {
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    const shown = try testSurface(80, 60);
    defer shown.release();
    testSynced(&metal, shown);

    metal.setHostDrawableSize(true, 120, 60);
    // The bound would end now, but the grid reached the program only now (ghostty_surface_set_grid).
    metal.resize_hold_until_ns.store(0, .release);
    metal.restartResizeHold();
    const wake = metal.resizeHoldWakeMs() orelse return error.TestUnexpectedResult;
    try testing.expect(wake > 0);
    const busy = try testSurface(120, 60);
    defer busy.release();
    try metal.present(testFrame(busy, .{ .alternate = true }), false);
    try testing.expectEqual(@as(?usize, 80), testShownWidth(&metal));
}

test "resize sync: no frame is held in the renderer mode, for a first frame, or after a reveal" {
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();

    // The renderer mode (default): a TUI's frame of a new size shows at once.
    {
        var metal = try testMetal(&device);
        defer testDeinit(&metal);
        const shown = try testSurface(80, 60);
        defer shown.release();
        metal.setHostDrawableSize(true, 80, 60);
        metal.layer.setSurfaceSync(shown);
        testRunMainLoopOnce();
        metal.setHostDrawableSize(true, 120, 60);
        const drawn = try testSurface(120, 60);
        defer drawn.release();
        try metal.present(testFrame(drawn, .{ .alternate = true }), false);
        try testing.expectEqual(@as(?usize, 120), testShownWidth(&metal));
    }
    // A first frame (nothing shown) presents itself.
    {
        var metal = try testMetal(&device);
        defer testDeinit(&metal);
        metal.setHostPresent(.renderer_synced);
        metal.setHostDrawableSize(true, 120, 60);
        const first = try testSurface(120, 60);
        defer first.release();
        try metal.present(testFrame(first, .{ .alternate = true }), false);
        try testing.expectEqual(@as(?usize, 120), testShownWidth(&metal));
    }
    // Resized while hidden, then shown: the frame for the reveal shows at once.
    {
        var metal = try testMetal(&device);
        defer testDeinit(&metal);
        const shown = try testSurface(80, 60);
        defer shown.release();
        testSynced(&metal, shown);
        metal.setHostDrawableSize(true, 120, 60);
        metal.setShownFromMain(true);
        try testing.expectEqual(@as(?u64, null), metal.resizeHoldWakeMs());
        const drawn = try testSurface(120, 60);
        defer drawn.release();
        try metal.present(testFrame(drawn, .{ .alternate = true }), false);
        try testing.expectEqual(@as(?usize, 120), testShownWidth(&metal));
    }
}

/// A host-sized surface in cmux's mode that shows `shown` at the host size, committed (frames at that size go off
/// main).
fn testHostSized(metal: *Metal, shown: *IOSurface) void {
    metal.setHostPresent(.renderer_synced);
    metal.setHostDrawableSize(true, @intCast(shown.getWidth()), @intCast(shown.getHeight()));
    metal.layer.setSurfaceSync(shown);
    testRunMainLoopOnce();
}

/// The frames of a resize burst that the layer showed at a size other than the host size, by refresh.
const TestBurst = struct {
    /// Refreshes after which the layer showed a frame wider or higher than the host size: the view cuts it.
    cut: usize = 0,
    /// Refreshes after which it showed a frame narrower or lower than the host size: the view pads it.
    padded: usize = 0,
    /// The frames the burst drew, kept to its end (the layer shows one of them).
    frames: [max_frames]*IOSurface = undefined,
    count: usize = 0,

    const max_frames = 256;

    fn deinit(self: *TestBurst) void {
        for (self.frames[0..self.count]) |frame| frame.release();
    }

    /// One display refresh of a pane resize, as cmux drives it: the pane's size goes to the host size on the main
    /// thread, the renderer draws a frame at that size and presents it, and the main thread commits. The frame is of
    /// a full-screen program that has not redrawn at the new grid (it redraws only after SIGWINCH, a refresh or more
    /// late). Counts what the layer shows after the commit against the host size.
    fn refresh(self: *TestBurst, metal: *Metal, width: u32, height: u32) !void {
        metal.setHostDrawableSize(true, width, height);
        const frame = try testSurface(@intCast(width), @intCast(height));
        self.frames[self.count] = frame;
        self.count += 1;
        try metal.present(testFrame(frame, .{ .alternate = true }), false);
        testRunMainLoopOnce();
        const shown = metal.layer.shownSize() orelse return error.TestUnexpectedResult;
        if (shown.width > width or shown.height > height) {
            self.cut += 1;
        } else if (shown.width < width or shown.height < height) {
            self.padded += 1;
        }
    }
};

test "resize sync: in a key-resize burst no shown frame is wider or higher than the host size" {
    // cmux GI LAND 3 (the film of #40174, 19 of 255 frames wider than the pane by 2 cells or more; hold c1 on
    // aws-m4pro-8: 16, 13 and 20 such frames in 3 bursts, and in each of them only `host_held_frames` moved). A key
    // resize is a spring: the pane has a new size at each display refresh, for 6 steps one way and 6 steps back. The
    // resize hold kept the last frame of a full-screen program while the pane went on, and each new host size (and
    // each grid the PTY owner announced) started the hold's bound again, so the hold had no end in a spring: the pane
    // cut the kept frame (smaller pane) or padded it (larger pane). The pane's size is not Ghostty's to hold, so the
    // frame of the host size must show in the commit that follows its draw.
    const testing = std.testing;
    try testing.expect(testIsMainThread());
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = testDevice();
    var metal = try testMetal(&device);
    defer testDeinit(&metal);
    // The pane before the burst.
    const shown = try testSurface(240, 120);
    defer shown.release();
    testHostSized(&metal, shown);

    var burst: TestBurst = .{};
    defer burst.deinit();

    const steps = 6;
    const refreshes_per_step = 4;
    const px_per_refresh = 6;
    // A vertical divider: 6 steps that make the pane narrower, then 6 steps back.
    var width: u32 = 240;
    for (0..steps * refreshes_per_step) |_| {
        width -= px_per_refresh;
        try burst.refresh(&metal, width, 120);
    }
    for (0..steps * refreshes_per_step) |_| {
        width += px_per_refresh;
        try burst.refresh(&metal, width, 120);
    }
    // A horizontal divider: the same for the height.
    var height: u32 = 120;
    for (0..steps * refreshes_per_step / 2) |_| {
        height -= px_per_refresh;
        try burst.refresh(&metal, 240, height);
    }
    for (0..steps * refreshes_per_step / 2) |_| {
        height += px_per_refresh;
        try burst.refresh(&metal, 240, height);
    }

    try testing.expectEqual(@as(usize, 0), burst.cut);
    try testing.expectEqual(@as(usize, 0), burst.padded);
    try testing.expectEqual(@as(?usize, 240), testShownWidth(&metal));
}
