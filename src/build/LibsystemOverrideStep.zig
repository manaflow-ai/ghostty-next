//! Wraps a Darwin static archive with the libsystem_override.sh
//! post-processing step so that consumers linking the archive bind
//! well-known libc/libm symbols (memcpy, memmove, memset, cos, sin,
//! ...) to Apple's libSystem instead of the bundled Zig compiler-rt.
//! See src/build/libsystem_override.sh for the full rationale.
//!
//! This applies to every static archive we produce, public
//! (e.g. libghostty-vt) and app-internal alike: the compiler-rt
//! bundle must stay because the few symbols libSystem does not
//! provide (f128 conversions, *q math, sincos*, ___zig_probe_stack)
//! have live references, e.g. from the bundled ubsan runtime and
//! x86_64 stack probing in Debug builds.
//!
//! The script only edits the compiler_rt.o member. Its output does not
//! depend on the caller's locale or PATH. It fails the build, rather
//! than produce a broken archive, when the input has no compiler_rt.o
//! member or when the edited member doesn't define exactly the
//! expected global symbols.
//!
//! Shared libraries don't need this step. On Darwin, Apple's ld links
//! the libghostty-vt dylib from this step's output (see
//! GhosttyLibVt.initLibApple). A Mach-O dylib that Zig 0.17 links
//! against libc already takes memcpy, memmove, cos and friends from
//! libSystem.
const std = @import("std");
const builtin = @import("builtin");

pub const Result = struct {
    /// The step performing the override, or null if the override
    /// doesn't apply to this target/host (in which case `output` is
    /// the unmodified input).
    step: ?*std.Build.Step,
    output: std.Build.LazyPath,
};

/// Post-process the given static archive for a Darwin target. A Darwin
/// host uses the Apple toolchain (libsystem_override.sh, nmedit); any
/// other host uses the portable libsystem_override.zig tool, which
/// localizes the same symbols, so a cross-compiled archive matches a
/// Mac-built one. Without it, a non-Darwin host shipped compiler-rt's
/// strong memset beside quirks_memset.zig's, which strict linkers
/// (ld64.lld) reject as a duplicate symbol. A non-Darwin target is a
/// no-op.
pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    input: std.Build.LazyPath,
    out_name: []const u8,
) Result {
    if (!target.result.os.tag.isDarwin()) {
        return .{ .step = null, .output = input };
    }

    if (comptime !builtin.os.tag.isDarwin()) {
        const tool = b.addExecutable(.{
            .name = "libsystem_override",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/build/libsystem_override.zig"),
                .target = b.graph.host,
            }),
        });
        const run = b.addRunArtifact(tool);
        run.setName("libsystem override");
        run.addArg(b.graph.zig_exe);
        run.addFileArg(input);
        const output = run.addOutputFileArg(out_name);
        return .{ .step = &run.step, .output = output };
    }

    const run = b.addSystemCommand(&.{"/bin/sh"});
    run.setName("libsystem override");
    run.addFileArg(b.path("src/build/libsystem_override.sh"));
    run.addFileArg(input);
    const output = run.addOutputFileArg(out_name);
    return .{ .step = &run.step, .output = output };
}
