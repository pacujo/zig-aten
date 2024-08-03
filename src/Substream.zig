//! Deliver bytes from the middle of an underlying byte stream.

const std = @import("std");
const r3 = @import("r3");
const Aten = @import("Aten.zig");
const Action = Aten.Action;
const ByteStream = Aten.ByteStream;
const TRACE = r3.trace;

aten: *Aten,
uid: r3.UID,
callback: Action,
state: State,
underlying_stream: ByteStream,
mode: Mode,
preamble_remaining: usize,
data_remaining: ?usize,

const Substream = @This();
const Mode = enum {
    close_together,
    fast_forward,
    close_at_end,
    detach_at_close,
};
const State = enum { preamble, data, postamble, eof, closed };

fn wrapUp(self: *Substream) usize {
    self.state = .eof;
    if (self.mode == .close_at_end)
        self.underlying_stream.close();
    return 0;
}

fn doRead(self: *Substream, buffer: []u8) !usize {
    if (buffer.len == 0)
        return 0;
    switch (self.state) {
        .preamble => {
            while (self.preamble_remaining > 0) {
                var skip_buf: [4096]u8 = undefined;
                const skip_amount = @min(self.preamble_remaining, skip_buf.len);
                const skip_area = skip_buf[0..skip_amount];
                const count = try self.underlying_stream.read(skip_area);
                if (count == 0)
                    return self.wrapUp();
                self.preamble_remaining -= count;
            }
            self.state = .data;
            return self.doRead(buffer);
        },
        .data => {
            const amount = @min(
                if (self.data_remaining) |n| n else buffer.len,
                buffer.len,
            );
            if (amount == 0) {
                if (self.mode != .fast_forward)
                    return self.wrapUp();
                self.state = .postamble;
                return self.doRead(buffer);
            }
            const count = try self.underlying_stream.read(buffer[0..amount]);
            if (count == 0)
                return self.wrapUp();
            if (self.data_remaining) |*n| n.* -= count;
            return count;
        },
        .postamble => {
            var skip_buf: [4096]u8 = undefined;
            while (try self.underlying_stream.read(&skip_buf) > 0) {}
            return self.wrapUp();
        },
        .eof => return 0,
        .closed => unreachable,
    }
}

/// Read from a substream.
pub fn read(self: *Substream, buffer: []u8) !usize {
    const count = self.doRead(buffer) catch |err| {
        TRACE("ATEN-SUBSTREAM-READ-FAIL UID={} WANT={} ERR={}", //
            .{ self.uid, buffer.len, err });
        return err;
    };
    TRACE("ATEN-SUBSTREAM-READ UID={} WANT={} GOT={}", //
        .{ self.uid, buffer.len, count });
    TRACE("ATEN-SUBSTREAM-READ-DUMP UID={} DATA={}", //
        .{ self.uid, r3.str(buffer[0..count]) });
    return count;
}

/// Close a substream.
pub fn close(self: *Substream) void {
    TRACE("ATEN-SUBSTREAM-CLOSE UID={}", .{self.uid});
    std.debug.assert(self.state != .closed);
    if (self.mode != .close_at_end or self.state != .eof)
        self.underlying_stream.close();
    self.state = .closed;
    self.aten.wound(self);
}

/// Subscribe to readability notifications.
pub fn subscribe(self: *Substream, action: Action) void {
    TRACE("ATEN-SUBSTREAM-SUBSCRIBE UID={} ACT={}", .{ self.uid, action });
    self.callback = action;
}

/// Wrap the underlying stream. Skip `begin` bytes from its beginning
/// and transfer bytes up to but not including `end`. If `end` is
/// `null`, transfer bytes up to the end of the underlying stream. If
/// `end` is less than `begin`, it is interpreted as equal to `begin`.
///
/// If `mode` is `.close_together`, the substream's reports an
/// end-of-file as soon as the underlying stream does and closing the
/// substream closes the underlying stream.
///
/// If `mode` is `.fast_forward`, the substream withholds its
/// end-of-file until it has exhausted the underlying stream.
///
/// If `mode` is `.close_at_end`, the underlying stream is closed when
/// its end-of-file is reached.
///
/// If `mode` is `.detach_at_close`, the underlying stream is not read
/// past `end` nor is it closed when the `substream` is closed.
///
/// The potentially long skips may monopolize the scheduler for a long
/// time. To prevent that, consider wrapping the underlying stream
/// with `NiceStream`.
pub fn make(
    aten: *Aten,
    underlying_stream: ByteStream,
    mode: Mode,
    begin: usize,
    end: ?usize,
) *Substream {
    const self = aten.alloc(Substream);
    self.* = .{
        .aten = aten,
        .uid = r3.newUID(),
        .callback = Action.Null,
        .state = .preamble,
        .underlying_stream = underlying_stream,
        .mode = mode,
        .preamble_remaining = begin,
        .data_remaining = if (end) |e| @max(e, begin) - begin else null,
    };
    underlying_stream.subscribe(ByteStream.makeCallbackProbe(self));
    TRACE("ATEN-SUBSTREAM-CREATE UID={} PTR={} ATEN={} U-STR={} " ++
        "MODE={} BEGIN={} END={?}", .{
        self.uid,
        r3.ptr(self),
        aten.uid,
        underlying_stream,
        mode,
        begin,
        end,
    });
    return self;
}
