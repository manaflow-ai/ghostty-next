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
const IOSurfaceLayer = @import("IOSurfaceLayer.zig");

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

/// The underlying IOSurface.
surface: *IOSurface,

/// The underlying MTLTexture.
texture: objc.Object,

/// Current width of this target.
width: usize,
/// Current height of this target.
height: usize,

/// The frame drawn into this target last had cells built at this target's
/// size (macOS host-sized surfaces present only such frames in a display
/// pass of a new size, `Metal.presentHostSized`). Set before each draw.
cells_fresh: bool = false,

/// The host size generation (`Metal.sizeGeneration`) when this frame's draw
/// began: a frame publishes for a display pass only in its own generation.
size_generation: u64 = 0,

/// The blinking cursor this frame shows on its own layer, presented with
/// the frame (`IOSurfaceLayer.Cursor`; no surface: none). Set before each
/// draw.
cursor_layer: IOSurfaceLayer.Cursor = .{},

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
    };
}

pub fn deinit(self: *Self) void {
    self.surface.deinit();
    self.texture.release();
}
