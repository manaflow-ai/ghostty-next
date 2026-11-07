//! PROMPT_REDRAW record: the prompt clear a resize put off.
//!
//! With `Terminal.flags.prompt_redraw_waits_for_shell`, a resize does not
//! clear the shell's prompt at once. It records the grid the shell drew the
//! prompt at, and the clear runs before the shell's next byte, only if the
//! grid is still different (`Terminal.settlePromptRedraw`). A snapshot taken
//! between the resize and that byte carries this record, so a restored
//! terminal clears the prompt at the same byte as the source.
//!
//! Optional: the encoder writes it only while a clear is pending, between
//! CONTINUATION and READY. A decoder that does not know the tag skips it and
//! restores the terminal without the pending clear, as before this record.
//!
//! ## Binary Format
//!
//! All integers are little-endian.
//!
//! | Offset | Size | Field |
//! | --- | --- | --- |
//! | 0 | 2 | cols the shell drew the prompt at |
//! | 2 | 2 | rows the shell drew the prompt at |
//! | 4 | 1 | OSC 133 redraw value (0 true, 1 false, 2 last) |
//! | 5 | 1 | 1 if a prompt row count follows, else 0 |
//! | 6 | 4 | prompt rows at and below the cursor at the old width |

const std = @import("std");
const record = @import("record.zig");
const size = @import("../size.zig");
const Terminal = @import("../Terminal.zig");
const Redraw = @import("../osc.zig").semantic_prompt.Redraw;

pub const payload_len = 10;

pub const EncodeError = record.Writer.FinishError;

/// Append one PROMPT_REDRAW record for `pending`.
pub fn encode(
    pending: Terminal.PromptRedrawPending,
    stream: *record.Writer,
) EncodeError!void {
    const payload = stream.begin(.prompt_redraw);
    errdefer stream.cancel();
    try payload.writeInt(u16, pending.cols, .little);
    try payload.writeInt(u16, pending.rows, .little);
    try payload.writeByte(@intCast(@backingInt(pending.redraw)));
    const rows_before: u32 = if (pending.rows_before) |rows|
        std.math.cast(u32, rows) orelse std.math.maxInt(u32)
    else
        0;
    try payload.writeByte(@intFromBool(pending.rows_before != null));
    try payload.writeInt(u32, rows_before, .little);
    try stream.finish();
}

pub const DecodeError = record.Reader.FinishError ||
    std.Io.Reader.Error ||
    error{
        /// The record is valid but is not PROMPT_REDRAW.
        UnexpectedRecordTag,

        /// The payload is not the fixed PROMPT_REDRAW layout.
        InvalidPromptRedraw,
    };

/// Decode one PROMPT_REDRAW record. `record_header` is the record's header,
/// already read from `source`. A value this build cannot use (a zero grid or
/// an unknown redraw value) decodes as null: the terminal then restores
/// without the pending clear, which is how a decoder without this record
/// restores it.
pub fn decode(
    source: *std.Io.Reader,
    record_header: record.Header,
) DecodeError!?Terminal.PromptRedrawPending {
    var record_reader: record.Reader = undefined;
    record_reader.initHeader(source, record_header);
    if (record_reader.header.tag != .prompt_redraw) {
        return error.UnexpectedRecordTag;
    }
    if (record_reader.header.payload_len != payload_len) {
        return error.InvalidPromptRedraw;
    }
    var bytes: [payload_len]u8 = undefined;
    try record_reader.payloadReader().readSliceAll(&bytes);
    try record_reader.finish();

    const cols = std.mem.readInt(u16, bytes[0..2], .little);
    const rows = std.mem.readInt(u16, bytes[2..4], .little);
    const redraw_raw = std.math.cast(@typeInfo(Redraw).@"enum".tag_type, bytes[4]) orelse return null;
    const redraw = std.enums.fromInt(Redraw, redraw_raw) orelse return null;
    if (cols == 0 or rows == 0 or redraw == .false) return null;
    const rows_before: ?usize = switch (bytes[5]) {
        0 => null,
        1 => std.mem.readInt(u32, bytes[6..10], .little),
        else => return null,
    };
    return .{
        .cols = std.math.cast(size.CellCountInt, cols) orelse return null,
        .rows = std.math.cast(size.CellCountInt, rows) orelse return null,
        .redraw = redraw,
        .rows_before = rows_before,
    };
}

test "PROMPT_REDRAW round trip" {
    const testing = std.testing;
    const cases = [_]Terminal.PromptRedrawPending{
        .{ .cols = 10, .rows = 4, .redraw = .true, .rows_before = 2 },
        .{ .cols = 80, .rows = 24, .redraw = .last, .rows_before = null },
    };
    for (cases) |pending| {
        var snapshot: std.Io.Writer.Allocating = .init(testing.allocator);
        defer snapshot.deinit();
        var stream: record.Writer = .init(testing.allocator, &snapshot.writer);
        defer stream.deinit();
        try encode(pending, &stream);

        var source: std.Io.Reader = .fixed(snapshot.written());
        const decoded = try decode(&source, try record.nextHeader(&source));
        try testing.expectEqual(@as(?Terminal.PromptRedrawPending, pending), decoded);
    }
}
