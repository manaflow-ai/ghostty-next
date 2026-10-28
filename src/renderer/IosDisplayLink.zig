//! iOS vsync for the renderer: a CADisplayLink on the main run loop that
//! wakes the renderer thread's `draw_now` once per display refresh, the
//! iOS counterpart of the macOS CVDisplayLink in `generic.zig`.
//!
//! Without it an iOS renderer has no vsync (`hasVsync` is false), so every
//! frame update draws at once: one frame per output batch, 190-270 frames
//! a second on a 120 Hz screen under heavy output (cmux-next-ios
//! verify/terminal-flood.md). With it, a frame update while the link runs
//! waits for the next tick, so a busy terminal draws at most once per
//! refresh; the first frame after idle still draws at once (`drawsNow`).
//!
//! The link asks for 120 Hz (ProMotion); on a 60 Hz screen it runs at 60.
//! A ProMotion iPhone also needs `CADisableMinimumFrameDurationOnPhone` in
//! the app's Info.plist, or iOS caps every link at 60.
//!
//! Threads: the renderer thread calls `create`, `setRunning`,
//! `isRunning` and `close`; every CADisplayLink call happens on the main
//! queue (`dispatch_async_f`), in that order, and the ticks arrive on the
//! main thread. `close` detaches `draw_now` under `mutex` before it
//! returns, so no tick touches the renderer thread's `xev.Async` after the
//! thread exits; the link and this struct are freed later, on main.
const IosDisplayLink = @This();

const std = @import("std");
const objc = @import("objc");
const macos = @import("macos");
const global = @import("../global.zig");
const xev = global.xev;

const log = std.log.scoped(.ios_display_link);

/// The frame rate range the link asks for: a ProMotion screen runs at
/// 120 Hz while frames come, and may drop to 80 under thermal pressure.
pub const frame_rate_range: FrameRateRange = .{ .minimum = 80, .maximum = 120, .preferred = 120 };

/// CAFrameRateRange.
pub const FrameRateRange = extern struct {
    minimum: f32,
    maximum: f32,
    preferred: f32,
};

/// Guards `draw_now` against `release` while a tick notifies it.
mutex: std.Io.Mutex = .init,

/// The renderer thread's draw_now, null once released.
draw_now: ?*xev.Async,

/// What the renderer thread last asked for (`start`/`stop`).
want_running: std.atomic.Value(bool) = .init(false),

/// A main-queue apply of `want_running` is queued and has not run yet.
apply_pending: std.atomic.Value(bool) = .init(false),

/// Ticks that reached the renderer thread (diagnostics).
ticks: std.atomic.Value(u64) = .init(0),

/// The CADisplayLink (retained) and its target. Main thread only.
link: ?objc.Object = null,
target: ?objc.Object = null,

/// Creates the link for `draw_now`, paused. The CADisplayLink itself is
/// made on the main queue. Same signature as `DisplayLink.create` (macOS):
/// a tick notifies `draw_now` directly, so `callbackFn` is not called and
/// `alloc` is unused (the struct is freed on main, after the last tick).
pub fn create(
    alloc: std.mem.Allocator,
    comptime Userdata: type,
    comptime callbackFn: anytype,
    draw_now: ?*Userdata,
) !*IosDisplayLink {
    _ = alloc;
    _ = callbackFn;
    comptime std.debug.assert(Userdata == xev.Async);
    const self = try std.heap.c_allocator.create(IosDisplayLink);
    self.* = .{ .draw_now = draw_now orelse return error.NoDrawNow };
    dispatch_async_f(macos.dispatch.queue.getMain(), self, &createOnMain);
    return self;
}

/// A display change: a CADisplayLink follows the screen it is on, so
/// there is nothing to do (`DisplayLink.setDisplay` on macOS).
pub fn setDisplay(self: *IosDisplayLink, display_id: u32) void {
    _ = self;
    _ = display_id;
}

/// Whether the renderer asked for ticks: while true the renderer thread
/// draws on a tick (or a forced draw) only.
pub fn isRunning(self: *IosDisplayLink) bool {
    return self.want_running.load(.acquire);
}

/// Detaches `draw_now` now (no tick wakes it after this returns) and
/// invalidates and frees the link on the main queue. The pointer is
/// invalid after this call (`DisplayLink.close` on macOS).
pub fn close(self: *IosDisplayLink) void {
    self.want_running.store(false, .release);
    {
        self.mutex.lockUncancelable(global.io());
        defer self.mutex.unlock(global.io());
        self.draw_now = null;
    }
    dispatch_async_f(macos.dispatch.queue.getMain(), self, &destroyOnMain);
}

/// Ticks resume (true) or pause (false), applied on main at the next
/// display refresh. Never blocks (`DisplayLink.setRunning` on macOS).
pub fn setRunning(self: *IosDisplayLink, running: bool) void {
    if (self.want_running.swap(running, .acq_rel) == running) return;
    // One queued apply reads the latest wish, however many changes come
    // before it runs.
    if (self.apply_pending.swap(true, .acq_rel)) return;
    dispatch_async_f(macos.dispatch.queue.getMain(), self, &applyOnMain);
}

fn tick(self: *IosDisplayLink) void {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    const draw_now = self.draw_now orelse return;
    _ = self.ticks.fetchAdd(1, .monotonic);
    draw_now.notify() catch |err| log.err("error notifying draw_now err={}", .{err});
}

fn createOnMain(ctx: ?*anyopaque) callconv(.c) void {
    const self: *IosDisplayLink = @ptrCast(@alignCast(ctx.?));
    const class = targetClass() catch {
        log.warn("error creating the display link target class; no vsync", .{});
        return;
    };
    const CADisplayLink = objc.getClass("CADisplayLink") orelse {
        log.warn("no CADisplayLink class; no vsync", .{});
        return;
    };
    const target = class.msgSend(objc.Object, objc.sel("new"), .{});
    target.setInstanceVariable("owner", objc.Object.fromId(@as(?*anyopaque, @ptrCast(self))));
    const link = CADisplayLink.msgSend(objc.Object, objc.sel("displayLinkWithTarget:selector:"), .{
        target.value,
        objc.sel("tick:").value,
    }).retain();
    link.msgSend(void, objc.sel("setPreferredFrameRateRange:"), .{frame_rate_range});
    link.setProperty("paused", !self.want_running.load(.acquire));
    const NSRunLoop = objc.getClass("NSRunLoop").?;
    const main_loop = NSRunLoop.msgSend(objc.Object, objc.sel("mainRunLoop"), .{});
    link.msgSend(void, objc.sel("addToRunLoop:forMode:"), .{ main_loop.value, NSRunLoopCommonModes });
    self.link = link;
    self.target = target;
}

fn applyOnMain(ctx: ?*anyopaque) callconv(.c) void {
    const self: *IosDisplayLink = @ptrCast(@alignCast(ctx.?));
    self.apply_pending.store(false, .release);
    const link = self.link orelse return;
    link.setProperty("paused", !self.want_running.load(.acquire));
}

fn destroyOnMain(ctx: ?*anyopaque) callconv(.c) void {
    const self: *IosDisplayLink = @ptrCast(@alignCast(ctx.?));
    if (self.link) |link| {
        // invalidate releases the link's hold on the target.
        link.msgSend(void, objc.sel("invalidate"), .{});
        link.release();
    }
    if (self.target) |target| {
        target.setInstanceVariable("owner", objc.Object.fromId(@as(?*anyopaque, null)));
        target.release();
    }
    std.heap.c_allocator.destroy(self);
}

/// The link's target class, an NSObject with an `owner` pointer ivar and a
/// `tick:` method. Made once, on the main thread.
var target_class: ?objc.Class = null;

fn targetClass() error{ObjCFailed}!objc.Class {
    if (target_class) |c| return c;
    const NSObject = objc.getClass("NSObject") orelse return error.ObjCFailed;
    const class = objc.allocateClassPair(NSObject, "GhosttyIosDisplayLinkTarget") orelse
        return error.ObjCFailed;
    errdefer objc.disposeClassPair(class);
    if (!class.addIvar("owner")) return error.ObjCFailed;
    if (!class.addMethod("tick:", struct {
        fn tick(target: objc.c.id, sel: objc.c.SEL, link: objc.c.id) callconv(.c) void {
            _ = sel;
            _ = link;
            const obj = objc.Object.fromId(target);
            const owner: ?*IosDisplayLink = @ptrCast(@alignCast(obj.getInstanceVariable("owner").value));
            if (owner) |o| o.tick();
        }
    }.tick)) return error.ObjCFailed;
    objc.registerClassPair(class);
    target_class = class;
    return class;
}

extern "c" const NSRunLoopCommonModes: objc.c.id;

extern "c" fn dispatch_async_f(
    queue: *anyopaque,
    context: ?*anyopaque,
    work: *const fn (?*anyopaque) callconv(.c) void,
) void;
