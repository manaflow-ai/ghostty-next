pub const c = @import("animation/c.zig").c;

/// https://developer.apple.com/documentation/quartzcore/calayer/contents_gravity_values?language=objc
pub extern "c" const kCAGravityTopLeft: *anyopaque;
pub extern "c" const kCAGravityBottomLeft: *anyopaque;
pub extern "c" const kCAGravityCenter: *anyopaque;

/// https://developer.apple.com/documentation/quartzcore/cakeyframeanimation/calculationmode?language=objc
pub extern "c" const kCAAnimationDiscrete: *anyopaque;

test {
    @import("std").testing.refAllDecls(@This());
}
