const std = @import("std");
const Allocator = std.mem.Allocator;

const internal_os = @import("../os/main.zig");
const apprt = @import("../apprt.zig");
pub const resourcesDir = internal_os.resourcesDir;

pub const App = struct {
    /// There is no app thread or event loop to wake. Messages sent to
    /// the core app mailbox stay queued until something drains it.
    pub fn wakeup(_: *App) void {}

    /// Always return false: there is no apprt to perform an action. Core
    /// code that notifies the apprt (the key path's tests in Surface.zig)
    /// compiles against this runtime.
    pub fn performAction(
        _: *App,
        _: apprt.Target,
        comptime action: apprt.Action.Key,
        _: apprt.Action.Value(action),
    ) !bool {
        return false;
    }

    /// Always return false as there is no apprt to communicate with.
    pub fn performIpc(
        _: Allocator,
        _: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        _: apprt.ipc.Action.Value(action),
    ) !bool {
        return false;
    }
};
pub const Surface = struct {};
