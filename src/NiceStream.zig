//! Wrapper stream that prevents the underlying stream from
//! monopolizing the scheduler.

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
this_burst: usize,
max_burst: usize,

const NiceStream = @This();
const State = enum { open, closed };

/// Read from a nice stream.
pub fn read(self: *NiceStream, buffer: []u8) !usize {
    std.debug.assert(self.state != .closed);

    if (self.this_burst > self.max_burst) {
        TRACE("ATEN-NICESTREAM-BACK-OFF UID={} WANT={}", //
            .{ self.uid, buffer.len });
        self.this_burst = 0;
        _ = self.aten.execute(ByteStream.makeCallbackProbe(self));
        return error.EAGAIN;
    }
    const count = self.underlying_stream.read(buffer) catch |err| {
        TRACE("ATEN-NICESTREAM-READ-FAIL UID={} WANT={} ERR={}", //
            .{ self.uid, buffer.len, err });
        if (err == error.EAGAIN)
            self.this_burst = 0;
        return err;
    };
    self.this_burst += count;
    TRACE("ATEN-NICESTREAM-READ UID={} WANT={} GOT={}", //
        .{ self.uid, buffer.len, buffer.len });
    TRACE("ATEN-NICESTREAM-READ-DUMP UID={} DATA={}", //
        .{ self.uid, r3.str(buffer[0..count]) });
    return count;
}

/// Close a nice stream.
pub fn close(self: *NiceStream) void {
    TRACE("ATEN-NICESTREAM-CLOSE UID={}", .{self.uid});
    std.debug.assert(self.state != .closed);
    self.underlying_stream.close();
    self.state = .closed;
    self.aten.wound(self);
}

/// Subscribe to readability notifications.
pub fn subscribe(self: *NiceStream, action: Action) void {
    TRACE("ATEN-NICESTREAM-SUBSCRIBE UID={} ACT={}", .{ self.uid, action });
    self.callback = action;
}

/// Create a nice stream.
pub fn make(
    aten: *Aten,
    underlying_stream: ByteStream,
    max_burst: usize,
) *NiceStream {
    const self = aten.alloc(NiceStream);
    self.* = .{
        .aten = aten,
        .uid = r3.newUID(),
        .callback = Action.Null,
        .state = .open,
        .underlying_stream = underlying_stream,
        .this_burst = 0,
        .max_burst = max_burst,
    };
    TRACE("ATEN-NICESTREAM-CREATE UID={} PTR={} ATEN={} U-STR={} MAX={}", //
        .{ self.uid, r3.ptr(self), aten.uid, underlying_stream, max_burst });
    return self;
}
