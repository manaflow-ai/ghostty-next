//! The Metal device context.
//!
//! This holds the MTLDevice, metadata derived from it and the one
//! MTLCommandQueue that every surface renderer commits to. Chrome's GPU
//! process does the same: ANGLE's Metal display owns one command queue
//! for all of its contexts (third_party/angle/src/libANGLE/renderer/metal/
//! DisplayMtl.h, `mCmdQueue`). MTLCommandQueue is thread-safe.
const Device = @This();

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc");

const mtl = @import("api.zig");
const shaders = @import("shaders.zig");

const log = std.log.scoped(.metal);

/// MTLDevice
device: objc.Object,

/// MTLCommandQueue shared by every surface renderer.
queue: objc.Object,

/// The default storage mode to use for resources created with our device.
///
/// This is based on whether the device is a discrete GPU or not, since
/// discrete GPUs do not have unified memory and therefore do not support
/// the "shared" storage mode, instead we have to use the "managed" mode.
default_storage_mode: mtl.MTLResourceOptions.StorageMode,

/// The maximum 2D texture width and height supported by the device.
max_texture_size: u32,

/// Uncompleted command buffers the queue allows before `commandBuffer`
/// waits. A surface has at most `swap_chain_count` frames in flight, so
/// this serves about 340 surfaces drawing at once (Metal's default is 64).
const max_command_buffers = 1024;

pub const InitError = error{ NoMetalDevice, CommandQueueFailed };

pub fn init(self: *Device, alloc: std.mem.Allocator) InitError!void {
    _ = alloc;

    // Choose our MTLDevice.
    const device = try chooseDevice();
    errdefer device.release();

    const queue = objc.Object.fromId(device.msgSend(
        ?*anyopaque,
        objc.sel("newCommandQueueWithMaxCommandBufferCount:"),
        .{@as(c_ulong, max_command_buffers)},
    ) orelse return error.CommandQueueFailed);
    errdefer queue.release();

    // Grab metadata about the device.
    const default_storage_mode: mtl.MTLResourceOptions.StorageMode = switch (comptime builtin.os.tag) {
        // manage mode is not supported by iOS
        .ios => .shared,
        else => if (device.getProperty(bool, "hasUnifiedMemory")) .shared else .managed,
    };
    const max_texture_size = queryMaxTextureSize(device);
    log.debug(
        "device properties default_storage_mode={} max_texture_size={}",
        .{ default_storage_mode, max_texture_size },
    );

    self.* = .{
        .device = device,
        .queue = queue,
        .default_storage_mode = default_storage_mode,
        .max_texture_size = max_texture_size,
    };
}

pub fn deinit(self: *Device) void {
    self.queue.release();
    self.device.release();
    self.* = undefined;
}

/// Warm up the Metal device machinery. The first Metal device query in
/// a process takes multiple milliseconds; once warm, subsequent queries
/// are effectively free. Calling this early (e.g. on a background
/// thread at app startup; Metal device queries are thread-safe) moves
/// that one-time cost off the critical path of the first surface's
/// renderer initialization.
pub fn warmup() void {
    const device = chooseDevice() catch return;
    defer device.release();

    // Create and release a command queue. The first command queue
    // created for a device pays additional one-time driver setup
    // costs; subsequent creations are much cheaper.
    const queue = device.msgSend(objc.Object, objc.sel("newCommandQueue"), .{});
    queue.release();

    // Build and discard our shader pipelines for both pixel formats we
    // may use (which one is used depends on the blending config). The
    // first pipeline state creation compiles shaders which is slow;
    // once warm, later creations hit driver and OS caches.
    inline for (.{
        mtl.MTLPixelFormat.bgra8unorm_srgb,
        mtl.MTLPixelFormat.bgra8unorm,
    }) |format| {
        if (shaders.Shaders.init(
            std.heap.c_allocator,
            device,
            &.{},
            format,
        )) |s| {
            var s_mut = s;
            s_mut.deinit(std.heap.c_allocator);
        } else |err| {
            log.warn("metal warmup shader init failed err={}", .{err});
        }
    }
}

fn chooseDevice() error{NoMetalDevice}!objc.Object {
    var chosen_device: ?objc.Object = null;

    switch (comptime builtin.os.tag) {
        .macos => {
            const devices = objc.Object.fromId(mtl.MTLCopyAllDevices());
            defer devices.release();

            var iter = devices.iterate();
            while (iter.next()) |device| {
                // We want a GPU that’s connected to a display.
                if (device.getProperty(bool, "isHeadless")) continue;
                chosen_device = device;

                // If the user has an eGPU plugged in, they probably want
                // to use it. Otherwise, integrated GPUs are better for
                // battery life and thermals.
                if (device.getProperty(bool, "isRemovable") or
                    device.getProperty(bool, "isLowPower")) break;
            }
        },

        .ios => {
            chosen_device = objc.Object.fromId(mtl.MTLCreateSystemDefaultDevice());
        },
        else => @compileError("unsupported target for Metal"),
    }

    const device = chosen_device orelse return error.NoMetalDevice;
    return device.retain();
}

/// Determines the maximum 2D texture size supported by the device.
/// We need to clamp our frame size to this if it's larger.
fn queryMaxTextureSize(device: objc.Object) u32 {
    // https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf

    if (device.msgSend(
        bool,
        objc.sel("supportsFamily:"),
        .{mtl.MTLGPUFamily.apple10},
    )) return 32768;

    if (device.msgSend(
        bool,
        objc.sel("supportsFamily:"),
        .{mtl.MTLGPUFamily.apple3},
    )) return 16384;

    return 8192;
}

test "one command queue per device" {
    var device: Device = undefined;
    device.init(std.testing.allocator) catch |err| switch (err) {
        // A Mac without a display-attached GPU (a headless VM).
        error.NoMetalDevice => return error.SkipZigTest,
        else => return err,
    };
    defer device.deinit();

    // Command buffers of two surfaces come from the one queue.
    const a = device.queue.msgSend(objc.Object, objc.sel("commandBuffer"), .{});
    const b = device.queue.msgSend(objc.Object, objc.sel("commandBuffer"), .{});
    const queue: ?*anyopaque = @ptrCast(device.queue.value);
    try std.testing.expectEqual(queue, a.getProperty(?*anyopaque, "commandQueue"));
    try std.testing.expectEqual(queue, b.getProperty(?*anyopaque, "commandQueue"));
}
