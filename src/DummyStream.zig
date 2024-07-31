//! A dummy stream is a byte stream that returns a constant value from
//its `read` method.

const std = @import("std");
const r3 = @import("r3");
const Aten = @import("Aten.zig");
const Action = Aten.Action;
const TRACE = r3.trace;

const State = enum { open, closed };

/// Create a byte stream type and implementation that always returns
/// the given error or byte count. See `Aten.DryStream` and
/// `Aten.EmptyStream`.
pub fn makeType(readResult: anyerror!usize) type {
    return struct {
        aten: *Aten,
        uid: r3.UID,
        state: State,

        const Self = @This();

        const result = readResult;

        /// Read from a dummy stream. Always returns `readResult`.
        pub fn read(self: *Self, buffer: []u8) !usize {
            std.debug.assert(self.state != .closed);
            TRACE("ATEN-DUMMYSTREAM-READ UID={} WANT={} GOT={!}", //
                .{ self.uid, buffer.len, result });
            return result;
        }

        /// Close a dummy stream.
        pub fn close(self: *Self) void {
            TRACE("ATEN-DUMMYSTREAM-CLOSE UID={}", .{self.uid});
            std.debug.assert(self.state != .closed);
            self.state = .closed;
            self.aten.wound(self);
        }

        /// Subscribe to readability notifications.
        pub fn subscribe(self: *Self, action: Action) void {
            TRACE("ATEN-DUMMYSTREAM-SUBSCRIBE UID={} ACT={}", //
                .{ self.uid, action });
        }

        /// Create a dummy stream.
        pub fn make(aten: *Aten) *Self {
            const self = aten.alloc(Self);
            self.* = .{
                .aten = aten,
                .uid = r3.newUID(),
                .state = .open,
            };
            TRACE("ATEN-DUMMYSTREAM-CREATE UID={} PTR={} ATEN={} RESULT={!}", //
                .{ self.uid, r3.ptr(self), aten.uid, result });
            return self;
        }
    };
}
