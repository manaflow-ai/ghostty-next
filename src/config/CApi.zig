const builtin = @import("builtin");
const std = @import("std");
const inputpkg = @import("../input.zig");
const global = @import("../global.zig");
const String = @import("../main_c.zig").String;

const Config = @import("Config.zig");
const c_get = @import("c_get.zig");
const edit = @import("edit.zig");
const Key = @import("key.zig").Key;

const log = std.log.scoped(.config);

/// Create a new configuration filled with the initial default values.
export fn ghostty_config_new() ?*Config {
    const result = global.alloc().create(Config) catch |err| {
        log.err("error allocating config err={}", .{err});
        return null;
    };

    result.* = Config.default(global.alloc()) catch |err| {
        log.err("error creating config err={}", .{err});
        global.alloc().destroy(result);
        return null;
    };

    return result;
}

export fn ghostty_config_free(ptr: ?*Config) void {
    if (ptr) |v| {
        v.deinit();
        global.alloc().destroy(v);
    }
}

/// Deep clone the configuration.
export fn ghostty_config_clone(self: *Config) ?*Config {
    const result = global.alloc().create(Config) catch |err| {
        log.err("error allocating config err={}", .{err});
        return null;
    };

    result.* = self.clone(global.alloc()) catch |err| {
        log.err("error cloning config err={}", .{err});
        global.alloc().destroy(result);
        return null;
    };

    return result;
}

/// Load the configuration from the CLI args.
export fn ghostty_config_load_cli_args(self: *Config) void {
    self.loadCliArgs(global.alloc()) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

/// Load the configuration from the default file locations. This
/// is usually done first. The default file locations are locations
/// such as the home directory.
export fn ghostty_config_load_default_files(self: *Config) void {
    self.loadDefaultFiles(global.alloc()) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

/// Load the configuration from a specific file path.
/// The path must be null-terminated.
export fn ghostty_config_load_file(self: *Config, path: [*:0]const u8) void {
    const path_slice = std.mem.span(path);
    self.loadFile(global.alloc(), path_slice) catch |err| {
        log.err("error loading config from file path={s} err={}", .{ path_slice, err });
    };
}

/// Load the configuration from in-memory contents.
/// The path is only used as a synthetic source path for diagnostics and
/// relative path expansion.
export fn ghostty_config_load_string(
    self: *Config,
    contents: [*]const u8,
    contents_len: usize,
    path: [*:0]const u8,
) void {
    const contents_slice = contents[0..contents_len];
    const path_slice = std.mem.span(path);
    self.loadString(global.alloc(), contents_slice, path_slice) catch |err| {
        log.err("error loading config from string path={s} err={}", .{ path_slice, err });
    };
}

/// Load the configuration from the user-specified configuration
/// file locations in the previously loaded configuration. This will
/// recursively continue to load up to a built-in limit.
export fn ghostty_config_load_recursive_files(self: *Config) void {
    self.loadRecursiveFiles(global.alloc()) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

export fn ghostty_config_finalize(self: *Config) void {
    self.finalize() catch |err| {
        log.err("error finalizing config err={}", .{err});
    };
}

export fn ghostty_config_get(
    self: *Config,
    ptr: *anyopaque,
    key_str: [*]const u8,
    len: usize,
) bool {
    @setEvalBranchQuota(10_000);
    const key = std.meta.stringToEnum(Key, key_str[0..len]) orelse return false;
    return c_get.get(self, key, ptr);
}

export fn ghostty_config_trigger(
    self: *Config,
    str: [*]const u8,
    len: usize,
) inputpkg.Binding.Trigger.C {
    return config_trigger_(self, str[0..len]) catch |err| err: {
        log.err("error finding trigger err={}", .{err});
        break :err .{};
    };
}

fn config_trigger_(
    self: *Config,
    str: []const u8,
) !inputpkg.Binding.Trigger.C {
    const action = try inputpkg.Binding.Action.parse(str);
    const trigger: inputpkg.Binding.Trigger = self.keybind.set.getTrigger(action) orelse .{};
    return trigger.cval();
}

export fn ghostty_config_diagnostics_count(self: *Config) u32 {
    return @intCast(self._diagnostics.items().len);
}

export fn ghostty_config_get_diagnostic(self: *Config, idx: u32) Diagnostic {
    const items = self._diagnostics.items();
    if (idx >= items.len) return .{};
    const message = self._diagnostics.precompute.messages.items[idx];
    return .{ .message = message.ptr };
}

export fn ghostty_config_open_path() String {
    const path = edit.openPath(global.alloc()) catch |err| {
        log.err("error opening config in editor err={}", .{err});
        return .empty;
    };

    return .fromSlice(path);
}

/// Sync with ghostty_diagnostic_s
const Diagnostic = extern struct {
    message: [*:0]const u8 = "",
};

/// Number of configuration keys (every `Config` field an embedder can
/// set; internal fields excluded). With `ghostty_config_key_name` an
/// embedder can enumerate the keys of the libghostty it links.
export fn ghostty_config_key_count() usize {
    return std.meta.fields(Key).len;
}

/// The name of key `index` (0 ..< `ghostty_config_key_count()`), a static
/// NUL-terminated string; null when the index is out of range.
export fn ghostty_config_key_name(index: usize) ?[*:0]const u8 {
    const names = comptime names: {
        const fields = std.meta.fields(Key);
        var result: [fields.len][*:0]const u8 = undefined;
        for (fields, 0..) |field, i| result[i] = field.name;
        break :names result;
    };
    if (index >= names.len) return null;
    return names[index];
}

/// Sync with ghostty_config_source_s
const Source = extern struct {
    /// NUL-terminated; owned by the config (valid until it is freed).
    path: [*:0]const u8 = "",
    line: usize = 0,
};

/// Where `key` got its current value: the file (or synthetic path of
/// `ghostty_config_load_string`) and 1-based line of its last assignment.
/// False when the key is at its default, came from the command line, or
/// is not a key.
export fn ghostty_config_key_source(
    self: *Config,
    key_ptr: [*]const u8,
    key_len: usize,
    out: *Source,
) bool {
    const location = self.keySource(key_ptr[0..key_len]) orelse return false;
    switch (location) {
        .file => |file| {
            const arena = self._arena.?.allocator();
            const path = arena.dupeZ(u8, file.path) catch return false;
            out.* = .{ .path = path.ptr, .line = file.line };
            return true;
        },
        .none, .cli => return false,
    }
}

/// Number of files read while loading the config (config files,
/// `config-file` includes, theme files), for a file watcher.
export fn ghostty_config_loaded_file_count(self: *Config) usize {
    return self.loadedFiles().len;
}

/// Loaded file `index`, NUL-terminated and owned by the config; null when
/// the index is out of range.
export fn ghostty_config_loaded_file(self: *Config, index: usize) ?[*:0]const u8 {
    const files = self.loadedFiles();
    if (index >= files.len) return null;
    return files[index].ptr;
}

test "ghostty_config_get: bool" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.maximize = true;

    var out = false;
    const key = "maximize";
    try testing.expect(ghostty_config_get(&cfg, &out, key, key.len));
    try testing.expect(out);
}

test "ghostty_config_get: enum" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"window-theme" = .dark;

    var out: [*:0]const u8 = undefined;
    const key = "window-theme";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    const str = std.mem.sliceTo(out, 0);
    try testing.expectEqualStrings("dark", str);
}

test "ghostty_config_get: optional null returns false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"unfocused-split-fill" = null;

    var out: Config.Color.C = undefined;
    const key = "unfocused-split-fill";
    try testing.expect(!ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
}

test "ghostty_config_get: unknown key returns false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    var out = false;
    const key = "not-a-real-key";
    try testing.expect(!ghostty_config_get(&cfg, &out, key, key.len));
}

test "ghostty_config_get: optional string null returns true" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.title = null;

    var out: ?[*:0]const u8 = undefined;
    const key = "title";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    try testing.expect(out == null);
}

test "ghostty_config_get: float" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"background-opacity" = 0.42;

    var out: f64 = 0;
    const key = "background-opacity";
    try testing.expect(ghostty_config_get(&cfg, &out, key, key.len));
    try testing.expectApproxEqAbs(@as(f64, 0.42), out, 0.000001);
}

test "ghostty_config_get: struct cval conversion" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.background = .{ .r = 12, .g = 34, .b = 56 };

    var out: Config.Color.C = undefined;
    const key = "background";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    try testing.expectEqual(@as(u8, 12), out.r);
    try testing.expectEqual(@as(u8, 34), out.g);
    try testing.expectEqual(@as(u8, 56), out.b);
}

test "ghostty_config_trigger: default keybind" {
    const testing = std.testing;

    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();

    // Default commands should be fetchable through config_trigger_
    {
        const trigger = try config_trigger_(&cfg, "open_config");
        try testing.expectEqual(.unicode, trigger.tag);
        try testing.expectEqual(@as(u32, ','), trigger.key.unicode);
    }
    {
        const trigger = try config_trigger_(&cfg, "reload_config");
        try testing.expectEqual(.unicode, trigger.tag);
        try testing.expectEqual(@as(u32, ','), trigger.key.unicode);
    }
    // Performable bindings are not tracked in the reverse map,
    // so config_trigger_ should return a default (empty) trigger.
    if (comptime builtin.target.os.tag.isDarwin()) {
        const next = try config_trigger_(&cfg, "navigate_search:next");
        try testing.expectEqual(.physical, next.tag);
        try testing.expectEqual(.unidentified, next.key.physical);

        const prev = try config_trigger_(&cfg, "navigate_search:previous");
        try testing.expectEqual(.physical, prev.tag);
        try testing.expectEqual(.unidentified, prev.key.physical);
    }
    {
        const trigger = try config_trigger_(&cfg, "adjust_selection:left");
        try testing.expectEqual(.physical, trigger.tag);
        try testing.expectEqual(.unidentified, trigger.key.physical);
    }
}

test "ghostty_config_key_name: every key, then null" {
    const testing = std.testing;
    const count = ghostty_config_key_count();
    try testing.expectEqual(std.meta.fields(Key).len, count);
    var saw_font_size = false;
    for (0..count) |i| {
        const name = std.mem.span(ghostty_config_key_name(i).?);
        try testing.expect(name.len > 0 and name[0] != '_');
        if (std.mem.eql(u8, name, "font-size")) saw_font_size = true;
    }
    try testing.expect(saw_font_size);
    try testing.expect(ghostty_config_key_name(count) == null);
}

test "ghostty_config_key_source and ghostty_config_loaded_file" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    try cfg.loadString(alloc, "\nfont-size = 14\n", "/cfg/main");
    try cfg.finalize();

    var source: Source = undefined;
    try testing.expect(ghostty_config_key_source(&cfg, "font-size", 9, &source));
    try testing.expectEqualStrings("/cfg/main", std.mem.span(source.path));
    try testing.expectEqual(@as(usize, 2), source.line);
    try testing.expect(!ghostty_config_key_source(&cfg, "background", 10, &source));

    // In-memory loads are not files on disk.
    try testing.expectEqual(@as(usize, 0), ghostty_config_loaded_file_count(&cfg));
    try testing.expect(ghostty_config_loaded_file(&cfg, 0) == null);
}

