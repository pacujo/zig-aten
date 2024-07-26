const std = @import("std");
const r3 = @import("r3");
const Aten = @import("Aten.zig");
const Action = Aten.Action;
const TRACE = r3.trace;
const TRACE_ENABLED = r3.enabled;

const State = enum { open, closed };

pub fn makeType(readResult: anyerror!usize) type {
    return struct {
        aten: *Aten,
        uid: r3.UID,
        state: State,

        const Self = @This();

        const result = readResult;

        pub fn read(self: *Self, buffer: []u8) !usize {
            std.debug.assert(self.state != .closed);
            TRACE("ATEN-DUMMYSTREAM-READ UID={} WANT={} GOT={!}", //
                .{ self.uid, buffer.len, result });
            return result;
        }

        pub fn close(self: *Self) void {
            TRACE("ATEN-DUMMYSTREAM-CLOSE UID={}", .{self.uid});
            std.debug.assert(self.state != .closed);
            self.state = .closed;
            self.aten.wound(self);
        }

        pub fn subscribe(self: *Self, action: Action) void {
            TRACE("ATEN-DUMMYSTREAM-SUBSCRIBE UID={} ACT={}", //
                .{ self.uid, action });
        }

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
