//! Build tool behind LibsystemOverrideStep: rewrite a Darwin static
//! archive so that consumers bind the libc/libm symbols libSystem
//! provides (memcpy, memset, cos, ...) to libSystem instead of the
//! bundled Zig compiler-rt. See libsystem_override.sh for why.
//!
//! It does what `nmedit` does in libsystem_override.sh, without the
//! Apple toolchain, so a Linux or Windows host that cross-compiles for
//! macOS produces the same archive as a Mac: in the archive's
//! compiler_rt.o member, each listed symbol becomes non-external
//! (private extern, like nmedit's output). The Mach-O symbol table is
//! reordered so the localized symbols join the local range
//! (LC_DYSYMTAB), and relocation and indirect-symbol indices follow.
//! Then `zig ranlib` rebuilds the archive index.
//!
//! It also marks compiler_rt.o's remaining global definitions weak
//! (N_WEAK_DEF). Zig declares them weak (lib/compiler_rt.zig: "we prefer
//! weak linkage because some of the routines ... may also be provided by
//! system/dynamic libc"), and an ELF build keeps that, but Zig 0.16's
//! Mach-O objects carry them as strong definitions. Apple ld64 tolerates
//! a strong duplicate from an archive; ld64.lld does not (for example
//! __negdf2 from Rust's compiler_builtins).
//!
//! Without this, a non-Darwin host shipped compiler-rt's strong memset
//! beside quirks_memset.zig's (ld64.lld: "duplicate symbol: memset")
//! and bound memcpy and friends to compiler-rt.
//!
//! Usage: libsystem_override <zig_exe> <input.a> <output.a>

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The symbols to prefer from libSystem. Keep in sync with
/// libsystem_override.sh (the Darwin-host path).
pub const localize = [_][]const u8{
    "_bcmp",         "_memcmp",       "_memcpy",       "_memmove",
    "_memset",       "_strlen",       "___memcpy_chk", "___memmove_chk",
    "___memset_chk", "___strcat_chk", "___strcpy_chk", "_ceil",
    "_ceilf",        "_ceill",        "_cos",          "_cosf",
    "_cosl",         "_exp",          "_exp2",         "_exp2f",
    "_exp2l",        "_expf",         "_expl",         "_fabs",
    "_fabsf",        "_fabsl",        "_floor",        "_floorf",
    "_floorl",       "_fma",          "_fmaf",         "_fmal",
    "_fmax",         "_fmaxf",        "_fmaxl",        "_fmin",
    "_fminf",        "_fminl",        "_fmod",         "_fmodf",
    "_fmodl",        "_log",          "_log10",        "_log10f",
    "_log10l",       "_log2",         "_log2f",        "_log2l",
    "_logf",         "_logl",         "_round",        "_roundf",
    "_roundl",       "_sin",          "_sinf",         "_sinl",
    "_sqrt",         "_sqrtf",        "_sqrtl",        "_tan",
    "_tanf",         "_tanl",         "_trunc",        "_truncf",
    "_truncl",
};

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);
    if (args.len != 4) {
        std.log.err("usage: libsystem_override <zig_exe> <input.a> <output.a>", .{});
        std.process.exit(1);
    }

    const archive = try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], alloc, .unlimited);
    const localized = patchArchive(alloc, archive) catch |err| {
        std.log.err("libsystem_override: {s}: {t}", .{ args[2], err });
        std.process.exit(1);
    };
    std.log.info("libsystem_override: {d} compiler_rt.o symbols left to libSystem", .{localized});

    const out_file = try std.Io.Dir.cwd().createFile(init.io, args[3], .{});
    try out_file.writePositionalAll(init.io, archive, 0);
    out_file.close(init.io);

    // The archive index still lists the localized symbols; rebuild it.
    var child = try std.process.spawn(init.io, .{
        .argv = &.{ args[1], "ranlib", args[3] },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(init.io);
    if (term.exited != 0) {
        std.log.err("zig ranlib exited with code {d}", .{term.exited});
        std.process.exit(1);
    }
}

pub const Error = error{ InvalidArchive, InvalidMachO, UnsupportedMachO } || Allocator.Error;

/// Localize the libSystem symbols of every `compiler_rt.o` member, in
/// place (member sizes do not change). Returns how many were localized.
pub fn patchArchive(alloc: Allocator, archive: []u8) Error!usize {
    const magic = "!<arch>\n";
    if (archive.len < magic.len or !std.mem.eql(u8, archive[0..magic.len], magic)) return error.InvalidArchive;

    var gnu_names: []const u8 = "";
    var total: usize = 0;
    var pos: usize = magic.len;
    while (pos + 60 <= archive.len) {
        const header = archive[pos..][0..60];
        if (!std.mem.eql(u8, header[58..60], "`\n")) return error.InvalidArchive;
        const size = std.fmt.parseInt(usize, std.mem.trimEnd(u8, header[48..58], " "), 10) catch return error.InvalidArchive;
        const data_start = pos + 60;
        if (data_start + size > archive.len) return error.InvalidArchive;
        const raw_name = std.mem.trimEnd(u8, header[0..16], " ");

        // BSD (#1/<len>, name before the data), GNU (name/, or /<offset>
        // into the // table) and plain names.
        var name: []const u8 = raw_name;
        var body_start = data_start;
        if (std.mem.startsWith(u8, raw_name, "#1/")) {
            const len = std.fmt.parseInt(usize, raw_name[3..], 10) catch return error.InvalidArchive;
            if (len > size) return error.InvalidArchive;
            name = std.mem.trimEnd(u8, archive[data_start..][0..len], "\x00");
            body_start = data_start + len;
        } else if (std.mem.eql(u8, raw_name, "//")) {
            gnu_names = archive[data_start..][0..size];
        } else if (raw_name.len > 1 and raw_name[0] == '/' and std.ascii.isDigit(raw_name[1])) {
            const offset = std.fmt.parseInt(usize, raw_name[1..], 10) catch return error.InvalidArchive;
            if (offset >= gnu_names.len) return error.InvalidArchive;
            const rest = gnu_names[offset..];
            name = rest[0 .. std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len];
        }
        name = std.mem.trimEnd(u8, name, "/");

        if (std.mem.eql(u8, name, "compiler_rt.o")) {
            const obj = archive[body_start .. data_start + size];
            total += try localizeObject(alloc, obj, &localize);
            _ = try weakenObject(obj);
        }
        pos = data_start + size;
        pos += pos & 1; // members are 2-byte aligned
    }
    return total;
}

const N_EXT: u8 = 0x01;
const N_PEXT: u8 = 0x10;
const N_TYPE: u8 = 0x0e;
const N_SECT: u8 = 0x0e;
const N_WEAK_DEF: u16 = 0x0080;
const INDIRECT_SYMBOL_LOCAL: u32 = 0x80000000;
const INDIRECT_SYMBOL_ABS: u32 = 0x40000000;

fn rd(comptime T: type, bytes: []const u8, at: usize) Error!T {
    if (at + @sizeOf(T) > bytes.len) return error.InvalidMachO;
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}

fn wr(comptime T: type, bytes: []u8, at: usize, value: T) void {
    std.mem.writeInt(T, bytes[at..][0..@sizeOf(T)], value, .little);
}

/// Make each defined external symbol of a 64-bit Mach-O object whose
/// name is in `names` a private extern local, as nmedit does. Returns
/// how many symbols changed.
pub fn localizeObject(alloc: Allocator, obj: []u8, names: []const []const u8) Error!usize {
    if (try rd(u32, obj, 0) != 0xfeedfacf) return error.UnsupportedMachO;
    if (try rd(u32, obj, 12) != 0x1) return error.UnsupportedMachO; // MH_OBJECT
    const ncmds = try rd(u32, obj, 16);

    var symtab: ?usize = null;
    var dysymtab: ?usize = null;
    var sections: std.ArrayListUnmanaged(usize) = .empty;
    var cmd_pos: usize = 32;
    for (0..ncmds) |_| {
        const cmd = try rd(u32, obj, cmd_pos);
        const cmdsize = try rd(u32, obj, cmd_pos + 4);
        switch (cmd) {
            0x2 => symtab = cmd_pos, // LC_SYMTAB
            0xb => dysymtab = cmd_pos, // LC_DYSYMTAB
            0x19 => { // LC_SEGMENT_64: section_64 headers follow
                const nsects = try rd(u32, obj, cmd_pos + 64);
                for (0..nsects) |i| try sections.append(alloc, cmd_pos + 72 + i * 80);
            },
            else => {},
        }
        if (cmdsize == 0) return error.InvalidMachO;
        cmd_pos += cmdsize;
    }
    const st = symtab orelse return 0;
    const ds = dysymtab orelse return error.UnsupportedMachO;
    const symoff = try rd(u32, obj, st + 8);
    const nsyms = try rd(u32, obj, st + 12);
    const stroff = try rd(u32, obj, st + 16);
    const strsize = try rd(u32, obj, st + 20);
    if (symoff + @as(usize, nsyms) * 16 > obj.len or stroff + @as(usize, strsize) > obj.len) return error.InvalidMachO;
    const nlocal = try rd(u32, obj, ds + 12);
    const iextdef = try rd(u32, obj, ds + 16);
    const nextdef = try rd(u32, obj, ds + 20);
    // An object has no table of contents, module table or external
    // reference table; refuse anything that does.
    for ([_]usize{ 36, 44, 52, 68 }) |field| if (try rd(u32, obj, ds + field) != 0) return error.UnsupportedMachO;
    if (iextdef != nlocal or iextdef + nextdef > nsyms) return error.UnsupportedMachO;

    const strtab = obj[stroff..][0..strsize];
    const symbols = obj[symoff..][0 .. @as(usize, nsyms) * 16];

    // New order: locals, localized, remaining external definitions, undefined.
    var order: std.ArrayListUnmanaged(u32) = .empty;
    var moved: usize = 0;
    for (0..nlocal) |i| try order.append(alloc, @intCast(i));
    for (iextdef..iextdef + nextdef) |i| {
        if (wantsLocal(symbols, strtab, i, names)) {
            try order.append(alloc, @intCast(i));
            moved += 1;
        }
    }
    if (moved == 0) return 0;
    for (iextdef..iextdef + nextdef) |i| {
        if (!wantsLocal(symbols, strtab, i, names)) try order.append(alloc, @intCast(i));
    }
    for (iextdef + nextdef..nsyms) |i| try order.append(alloc, @intCast(i));

    const new_index = try alloc.alloc(u32, nsyms);
    const copy = try alloc.dupe(u8, symbols);
    for (order.items, 0..) |old, new| {
        new_index[old] = @intCast(new);
        @memcpy(symbols[new * 16 ..][0..16], copy[@as(usize, old) * 16 ..][0..16]);
        if (new >= nlocal and new < nlocal + moved) {
            symbols[new * 16 + 4] = (symbols[new * 16 + 4] & ~N_EXT) | N_PEXT;
        }
    }
    wr(u32, obj, ds + 12, @intCast(nlocal + moved)); // nlocalsym
    wr(u32, obj, ds + 16, @intCast(iextdef + moved)); // iextdefsym
    wr(u32, obj, ds + 20, @intCast(nextdef - moved)); // nextdefsym

    // Relocations that name a symbol (r_extern) follow it.
    for (sections.items) |sect| {
        const reloff = try rd(u32, obj, sect + 56);
        const nreloc = try rd(u32, obj, sect + 60);
        for (0..nreloc) |r| {
            const at = reloff + r * 8 + 4;
            const info = try rd(u32, obj, at);
            if (info & (1 << 27) == 0) continue; // r_extern
            const sym = info & 0x00ff_ffff;
            if (sym >= nsyms) return error.InvalidMachO;
            wr(u32, obj, at, (info & 0xff00_0000) | new_index[sym]);
        }
    }

    // Indirect symbol table entries (rare in objects) follow too.
    const indirectoff = try rd(u32, obj, ds + 56);
    const nindirect = try rd(u32, obj, ds + 60);
    for (0..nindirect) |i| {
        const at = indirectoff + i * 4;
        const sym = try rd(u32, obj, at);
        if (sym & (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS) != 0) continue;
        if (sym >= nsyms) return error.InvalidMachO;
        wr(u32, obj, at, new_index[sym]);
    }
    return moved;
}

/// Mark every global definition of a 64-bit Mach-O object weak, as
/// Zig declares compiler-rt's. Returns how many changed.
pub fn weakenObject(obj: []u8) Error!usize {
    if (try rd(u32, obj, 0) != 0xfeedfacf) return error.UnsupportedMachO;
    const ncmds = try rd(u32, obj, 16);
    var cmd_pos: usize = 32;
    var changed: usize = 0;
    for (0..ncmds) |_| {
        const cmd = try rd(u32, obj, cmd_pos);
        const cmdsize = try rd(u32, obj, cmd_pos + 4);
        if (cmd == 0x2) { // LC_SYMTAB
            const symoff = try rd(u32, obj, cmd_pos + 8);
            const nsyms = try rd(u32, obj, cmd_pos + 12);
            for (0..nsyms) |i| {
                const at = symoff + i * 16;
                if (at + 16 > obj.len) return error.InvalidMachO;
                const n_type = obj[at + 4];
                if (n_type & N_EXT == 0 or n_type & N_TYPE != N_SECT) continue;
                const n_desc = try rd(u16, obj, at + 6);
                if (n_desc & N_WEAK_DEF != 0) continue;
                wr(u16, obj, at + 6, n_desc | N_WEAK_DEF);
                changed += 1;
            }
        }
        if (cmdsize == 0) return error.InvalidMachO;
        cmd_pos += cmdsize;
    }
    return changed;
}

fn wantsLocal(symbols: []const u8, strtab: []const u8, i: usize, names: []const []const u8) bool {
    const entry = symbols[i * 16 ..][0..16];
    const n_type = entry[4];
    if (n_type & N_EXT == 0 or n_type & N_TYPE != N_SECT) return false;
    const strx = std.mem.readInt(u32, entry[0..4], .little);
    if (strx >= strtab.len) return false;
    const name = std.mem.sliceTo(strtab[strx..], 0);
    for (names) |want| if (std.mem.eql(u8, name, want)) return true;
    return false;
}

// ---------------------------------------------------------------------
// Tests

const testing = std.testing;

const TestSym = struct { name: []const u8, n_type: u8 };

/// A minimal MH_OBJECT: one __TEXT,__text section with one extern
/// relocation per entry of `relocs` (symbol indices), LC_SYMTAB and
/// LC_DYSYMTAB. Symbols are given in symbol-table order.
fn testObject(alloc: Allocator, syms: []const TestSym, nlocal: u32, nextdef: u32, relocs: []const u32) ![]u8 {
    var strtab: std.ArrayListUnmanaged(u8) = .empty;
    try strtab.append(alloc, 0);
    var strx: std.ArrayListUnmanaged(u32) = .empty;
    for (syms) |s| {
        try strx.append(alloc, @intCast(strtab.items.len));
        try strtab.appendSlice(alloc, s.name);
        try strtab.append(alloc, 0);
    }
    const seg_size: u32 = 72 + 80;
    const cmds_size: u32 = seg_size + 24 + 80;
    const text_off: u32 = 32 + cmds_size;
    const reloff: u32 = text_off + 4;
    const symoff: u32 = reloff + @as(u32, @intCast(relocs.len)) * 8;
    const stroff: u32 = symoff + @as(u32, @intCast(syms.len)) * 16;
    const total = stroff + @as(u32, @intCast(strtab.items.len));
    const obj = try alloc.alloc(u8, total);
    @memset(obj, 0);
    wr(u32, obj, 0, 0xfeedfacf);
    wr(u32, obj, 4, 0x0100000c);
    wr(u32, obj, 12, 0x1);
    wr(u32, obj, 16, 3);
    wr(u32, obj, 20, cmds_size);
    var p: u32 = 32;
    wr(u32, obj, p, 0x19);
    wr(u32, obj, p + 4, seg_size);
    wr(u32, obj, p + 64, 1);
    const sect = p + 72;
    @memcpy(obj[sect..][0..6], "__text");
    @memcpy(obj[sect + 16 ..][0..6], "__TEXT");
    wr(u32, obj, sect + 48, text_off);
    wr(u32, obj, sect + 56, reloff);
    wr(u32, obj, sect + 60, @intCast(relocs.len));
    p += seg_size;
    wr(u32, obj, p, 0x2);
    wr(u32, obj, p + 4, 24);
    wr(u32, obj, p + 8, symoff);
    wr(u32, obj, p + 12, @intCast(syms.len));
    wr(u32, obj, p + 16, stroff);
    wr(u32, obj, p + 20, @intCast(strtab.items.len));
    p += 24;
    wr(u32, obj, p, 0xb);
    wr(u32, obj, p + 4, 80);
    wr(u32, obj, p + 12, nlocal);
    wr(u32, obj, p + 16, nlocal);
    wr(u32, obj, p + 20, nextdef);
    wr(u32, obj, p + 24, nlocal + nextdef);
    wr(u32, obj, p + 28, @as(u32, @intCast(syms.len)) - nlocal - nextdef);
    for (relocs, 0..) |sym, i| {
        // r_symbolnum, r_length 2, r_extern, ARM64_RELOC_BRANCH26 (2)
        wr(u32, obj, reloff + @as(u32, @intCast(i)) * 8 + 4, sym | (2 << 25) | (1 << 27) | (2 << 28));
    }
    for (syms, 0..) |s, i| {
        const at = symoff + @as(u32, @intCast(i)) * 16;
        wr(u32, obj, at, strx.items[i]);
        obj[at + 4] = s.n_type;
        obj[at + 5] = if (s.n_type & N_TYPE == N_SECT) 1 else 0;
    }
    @memcpy(obj[stroff..][0..strtab.items.len], strtab.items);
    return obj;
}

fn symName(obj: []const u8, i: usize) []const u8 {
    const symoff = std.mem.readInt(u32, obj[32 + 152 + 8 ..][0..4], .little);
    const stroff = std.mem.readInt(u32, obj[32 + 152 + 16 ..][0..4], .little);
    const strx = std.mem.readInt(u32, obj[symoff + i * 16 ..][0..4], .little);
    return std.mem.sliceTo(obj[stroff + strx ..], 0);
}

fn symType(obj: []const u8, i: usize) u8 {
    const symoff = std.mem.readInt(u32, obj[32 + 152 + 8 ..][0..4], .little);
    return obj[symoff + i * 16 + 4];
}

test "localizes listed definitions and keeps relocations on their symbols" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const ext = N_SECT | N_EXT | N_PEXT; // hidden definition, as Zig emits
    const obj = try testObject(alloc, &.{
        .{ .name = "ltmp0", .n_type = N_SECT },
        .{ .name = "___udivti3", .n_type = ext },
        .{ .name = "_memcpy", .n_type = ext },
        .{ .name = "_memset", .n_type = ext },
        .{ .name = "_undefined", .n_type = N_EXT },
    }, 1, 3, &.{ 1, 2, 3, 4 });

    try testing.expectEqual(@as(usize, 2), try localizeObject(alloc, obj, &localize));

    // Locals first (the two localized ones join them), then the
    // remaining definition, then the undefined symbol.
    try testing.expectEqualStrings("ltmp0", symName(obj, 0));
    try testing.expectEqualStrings("_memcpy", symName(obj, 1));
    try testing.expectEqualStrings("_memset", symName(obj, 2));
    try testing.expectEqualStrings("___udivti3", symName(obj, 3));
    try testing.expectEqualStrings("_undefined", symName(obj, 4));
    try testing.expectEqual(N_SECT | N_PEXT, symType(obj, 1));
    try testing.expectEqual(N_SECT | N_PEXT, symType(obj, 2));
    try testing.expectEqual(ext, symType(obj, 3));

    const ds = 32 + 152 + 24;
    try testing.expectEqual(@as(u32, 3), try rd(u32, obj, ds + 12)); // nlocalsym
    try testing.expectEqual(@as(u32, 3), try rd(u32, obj, ds + 16)); // iextdefsym
    try testing.expectEqual(@as(u32, 1), try rd(u32, obj, ds + 20)); // nextdefsym

    // Each relocation still names the same symbol.
    const reloff = try rd(u32, obj, 32 + 72 + 56);
    const want = [_][]const u8{ "___udivti3", "_memcpy", "_memset", "_undefined" };
    for (want, 0..) |name, r| {
        const info = try rd(u32, obj, reloff + r * 8 + 4);
        try testing.expectEqualStrings(name, symName(obj, info & 0x00ff_ffff));
        try testing.expect(info & (1 << 27) != 0);
    }

    // A second pass finds nothing left to localize.
    try testing.expectEqual(@as(usize, 0), try localizeObject(alloc, obj, &localize));

    // Weakening touches only the remaining global definition.
    try testing.expectEqual(@as(usize, 1), try weakenObject(obj));
    const symoff = try rd(u32, obj, 32 + 152 + 8);
    try testing.expectEqual(N_WEAK_DEF, try rd(u16, obj, symoff + 3 * 16 + 6)); // ___udivti3
    try testing.expectEqual(@as(u16, 0), try rd(u16, obj, symoff + 1 * 16 + 6)); // _memcpy, now local
    try testing.expectEqual(@as(u16, 0), try rd(u16, obj, symoff + 4 * 16 + 6)); // undefined
    try testing.expectEqual(@as(usize, 0), try weakenObject(obj));
}

test "an object without listed symbols is unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const obj = try testObject(alloc, &.{
        .{ .name = "___udivti3", .n_type = N_SECT | N_EXT },
    }, 0, 1, &.{0});
    const before = try alloc.dupe(u8, obj);
    try testing.expectEqual(@as(usize, 0), try localizeObject(alloc, obj, &localize));
    try testing.expectEqualSlices(u8, before, obj);
}

test "patches the compiler_rt.o member of a BSD archive in place" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const obj = try testObject(alloc, &.{
        .{ .name = "_memset", .n_type = N_SECT | N_EXT },
    }, 0, 1, &.{});
    var ar: std.ArrayListUnmanaged(u8) = .empty;
    try ar.appendSlice(alloc, "!<arch>\n");
    var header: [60]u8 = @splat(' ');
    const name = "compiler_rt.o\x00\x00\x00"; // BSD pads the name to 8
    @memcpy(header[0..5], "#1/16");
    const size_text = try std.fmt.allocPrint(alloc, "{d}", .{name.len + obj.len});
    @memcpy(header[48..][0..size_text.len], size_text);
    @memcpy(header[58..60], "`\n");
    try ar.appendSlice(alloc, &header);
    try ar.appendSlice(alloc, name);
    try ar.appendSlice(alloc, obj);

    try testing.expectEqual(@as(usize, 1), try patchArchive(alloc, ar.items));
    const member = ar.items[8 + 60 + name.len ..];
    try testing.expectEqual(N_SECT | N_PEXT, symType(member, 0));
}
