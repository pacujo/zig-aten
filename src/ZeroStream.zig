//! A zero stream produces an endless stream of zero bytes.

const std = @import("std");
const r3 = @import("r3");
const Aten = @import("Aten.zig");
const Action = Aten.Action;
const TRACE = r3.trace;

aten: *Aten,
uid: r3.UID,
state: State,

const ZeroStream = @This();
const State = enum { open, closed };

/// Read from a zero stream.
pub fn read(self: *ZeroStream, buffer: []u8) !usize {
    std.debug.assert(self.state != .closed);
    @memset(buffer, 0);
    TRACE("ATEN-ZEROSTREAM-READ UID={} WANT={} GOT={}", //
        .{ self.uid, buffer.len, buffer.len });
    return buffer.len;
}

/// Close a zero stream.
pub fn close(self: *ZeroStream) void {
    TRACE("ATEN-ZEROSTREAM-CLOSE UID={}", .{self.uid});
    std.debug.assert(self.state != .closed);
    self.state = .closed;
    self.aten.wound(self);
}

/// Subscribe to readability notifications.
pub fn subscribe(self: *ZeroStream, action: Action) void {
    TRACE("ATEN-ZEROSTREAM-SUBSCRIBE UID={} ACT={}", .{ self.uid, action });
}

/// Create a zero stream.
pub fn make(aten: *Aten) *ZeroStream {
    const self = aten.alloc(ZeroStream);
    self.* = .{
        .aten = aten,
        .uid = r3.newUID(),
        .state = .open,
    };
    TRACE("ATEN-ZEROSTREAM-CREATE UID={} PTR={} ATEN={}", //
        .{ self.uid, r3.ptr(self), aten.uid });
    return self;
}
