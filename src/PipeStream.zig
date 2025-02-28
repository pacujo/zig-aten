//! A pipe stream converts an open file descriptor to a byte stream.

const std = @import("std");
const r3 = @import("r3");
const Aten = @import("Aten.zig");
const Action = Aten.Action;
const ByteStream = Aten.ByteStream;
const fd_t = Aten.fd_t;
const TRACE = r3.trace;

aten: *Aten,
uid: r3.UID,
callback: Action,
fd: fd_t,
state: State,
monitored: bool,

const PipeStream = @This();
const State = enum { open, closed };
pub const Monitor = enum { yes, no, if_possible };

/// Read from a pipe stream.
pub fn read(self: *PipeStream, buffer: []u8) !usize {
    std.debug.assert(self.state != .closed);
    const count = Aten.read(self.fd, buffer) catch |err| {
        TRACE("ATEN-PIPESTREAM-READ-FAIL UID={} WANT={} ERR={}", //
            .{ self.uid, buffer.len, err });
        return err;
    };
    TRACE("ATEN-PIPESTREAM-READ UID={} WANT={} GOT={}", //
        .{ self.uid, buffer.len, count });
    TRACE("ATEN-PIPESTREAM-READ-DUMP UID={} DATA={}", //
        .{ self.uid, r3.str(buffer[0..count]) });
    return count;
}

/// Close a pipe stream and the associated file descriptor with it.
pub fn close(self: *PipeStream) void {
    TRACE("ATEN-PIPESTREAM-CLOSE UID={}", .{self.uid});
    std.debug.assert(self.state != .closed);
    if (self.monitored)
        self.aten.unregister(self.fd) catch unreachable;
    Aten.close(self.fd);
    self.state = .closed;
    self.aten.wound(self);
}

/// Subscribe to readability notifications.
pub fn subscribe(self: *PipeStream, action: Action) void {
    TRACE("ATEN-PIPESTREAM-SUBSCRIBE UID={} ACT={}", .{ self.uid, action });
    self.callback = action;
}

/// Create a byte stream wrapper for an open, readable file
/// descriptor. If `monitor` is `.yes`, the file descriptor is made
/// nonblocking and registered for readability notifications. This may
/// fail for some file types such as regular files. The `monitor`
/// value `.no` should be used for regular files, which are always
/// readable. The value `.if_possible` tries the register the file
/// descriptor for notifications but does not cause a failure if the
/// registration fails; this value can be used if the file type is not
/// known at compile time.
pub fn make(aten: *Aten, fd: fd_t, monitor: Monitor) !*PipeStream {
    const self = aten.alloc(PipeStream);
    self.* = .{
        .aten = aten,
        .uid = r3.newUID(),
        .callback = Action.Null,
        .fd = fd,
        .state = .open,
        .monitored = false, // updated below
    };
    if (monitor != .no) {
        self.monitored = true;
        aten.register(fd, ByteStream.makeCallbackProbe(self)) catch |err| {
            self.monitored = false;
            if (monitor == .yes or err != error.EPERM) {
                TRACE("ATEN-PIPESTREAM-CREATE-FAIL UID={} ATEN={} FD={} " ++
                    "MONITOR={} ERR={}", //
                    .{ self.uid, aten.uid, fd, monitor, err });
                return err;
            }
        };
    }
    TRACE("ATEN-PIPESTREAM-CREATE UID={} PTR={} ATEN={} FD={} MONITOR={}:{}", //
        .{ self.uid, r3.ptr(self), aten.uid, fd, monitor, self.monitored });
    return self;
}
