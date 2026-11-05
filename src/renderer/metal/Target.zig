//! Represents a render target.
//!
//! In this case, an IOSurface-backed MTLTexture.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const macos = @import("macos");
const graphics = macos.graphics;
const IOSurface = macos.iosurface.IOSurface;

const mtl = @import("api.zig");

const log = std.log.scoped(.metal);

/// Options for initializing a Target
pub const Options = struct {
    /// MTLDevice
    device: objc.Object,

    /// Desired width
    width: usize,
    /// Desired height
    height: usize,

    /// Pixel format for the MTLTexture
    pixel_format: mtl.MTLPixelFormat,
    /// Storage mode for the MTLTexture
    storage_mode: mtl.MTLResourceOptions.StorageMode,
};

/// The underlying IOSurface. Undefined while the target is empty (`release`).
surface: *IOSurface,

/// The underlying MTLTexture. Undefined while the target is empty (`release`).
texture: objc.Object,

/// Current width of this target; 0 while it is empty (`release`).
width: usize,
/// Current height of this target; 0 while it is empty (`release`).
height: usize,

/// The pixel size of the frame drawn into this target, from its top-left
/// corner (the render pass's viewport and scissor). It is the target's size,
/// except while the host sets a capacity (`Metal.setHostCapacity`): then the
/// target can be larger and the layer shows only these pixels. Set before
/// each draw (`Metal.fitTarget`).
drawn_width: usize,
drawn_height: usize,

/// The renderer's count of live target bytes (`Metal.counters`), lowered by
/// `bytes` when this target is freed; null for a target nothing counts.
live_bytes: ?*std.atomic.Value(u64) = null,
/// The IOSurface's allocation size, as counted in `live_bytes`.
bytes: u64 = 0,

/// A frame drawn into this target is in flight: committed (`Metal.frameCommitted`)
/// and not completed (`Metal.frameDone`). Meanwhile only its completion may
/// change the target; the renderer thread leaves it alone (`SwapChain.trim`).
/// Set by the renderer thread, cleared by the GPU completion thread (release),
/// read by the renderer thread (acquire).
in_flight: std.atomic.Value(bool) = .init(false),

/// The frame drawn into this target last had cells built at this target's
/// size (macOS host-sized surfaces present only such frames in a display
/// pass of a new size, `Metal.presentHostSized`). Set before each draw.
cells_fresh: bool = false,

/// The host size generation (`Metal.sizeGeneration`) when this frame's draw
/// began: a frame publishes for a display pass only in its own generation.
size_generation: u64 = 0,

pub fn init(opts: Options) !Self {
    // We set our surface's color space to Display P3.
    // This allows us to have "Apple-style" alpha blending,
    // since it seems to be the case that Apple apps like
    // Terminal and TextEdit render text in the display's
    // color space using converted colors, which reduces,
    // but does not fully eliminate blending artifacts.
    const colorspace = try graphics.ColorSpace.createNamed(.displayP3);
    defer colorspace.release();

    const surface = try IOSurface.init(.{
        .width = @intCast(opts.width),
        .height = @intCast(opts.height),
        .pixel_format = .@"32BGRA",
        .bytes_per_element = 4,
        .colorspace = colorspace,
    });

    // Create our descriptor
    const desc = init: {
        const Class = objc.getClass("MTLTextureDescriptor").?;
        const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
        const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
        break :init id_init;
    };
    defer desc.release();

    // Set our properties
    desc.setProperty("width", @as(c_ulong, @intCast(opts.width)));
    desc.setProperty("height", @as(c_ulong, @intCast(opts.height)));
    desc.setProperty("pixelFormat", @intFromEnum(opts.pixel_format));
    desc.setProperty("usage", mtl.MTLTextureUsage{ .render_target = true });
    desc.setProperty(
        "resourceOptions",
        mtl.MTLResourceOptions{
            // Indicate that the CPU writes to this resource but never reads it.
            .cpu_cache_mode = .write_combined,
            .storage_mode = opts.storage_mode,
        },
    );

    const id = opts.device.msgSend(
        ?*anyopaque,
        objc.sel("newTextureWithDescriptor:iosurface:plane:"),
        .{
            desc,
            surface,
            @as(c_ulong, 0),
        },
    ) orelse return error.MetalFailed;

    const texture = objc.Object.fromId(id);

    return .{
        .surface = surface,
        .texture = texture,
        .width = opts.width,
        .height = opts.height,
        .drawn_width = opts.width,
        .drawn_height = opts.height,
    };
}

pub fn deinit(self: *Self) void {
    // An empty target (`release`) holds nothing.
    if (self.width == 0) return;
    if (self.live_bytes) |live| _ = live.fetchSub(self.bytes, .monotonic);
    self.surface.deinit();
    self.texture.release();
}

/// Whether this target is larger than a frame of `width` x `height` pixels
/// needs, in either dimension. An empty target is not.
pub fn largerThan(self: *const Self, width: usize, height: usize) bool {
    return self.width > width or self.height > height;
}

/// Frees the surface and the texture now; the target is then empty (width
/// and height 0) until the next frame drawn into it gets a new one
/// (`Metal.fitTarget`). For a target given back after a host capacity
/// (`Renderer.SwapChain.trim`). Only for a target that is not in flight: a
/// frame in flight presents from it when it completes. A surface the layer
/// shows stays on screen: the layer holds its own reference until a newer
/// frame replaces it.
pub fn release(self: *Self) void {
    if (self.width == 0) return;
    self.deinit();
    self.surface = undefined;
    self.texture = undefined;
    self.width = 0;
    self.height = 0;
    self.drawn_width = 0;
    self.drawn_height = 0;
    self.live_bytes = null;
    self.bytes = 0;
}
