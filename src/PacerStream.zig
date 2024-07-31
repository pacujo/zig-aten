//! Perform rate limiting for an underlying byte stream.

const std = @import("std");
const r3 = @import("r3");
const Aten = @import("Aten.zig");
const Action = Aten.Action;
const ByteStream = Aten.ByteStream;
const PointInTime = Aten.PointInTime;
const Duration = Aten.Duration;
const Timer = Aten.Timer;
const TRACE = r3.trace;

aten: *Aten,
uid: r3.UID,
callback: Action,
state: State,
underlying_stream: ByteStream,
byterate: Float,
quota: Float,
min_burst: Float,
max_burst: Float,
prev_t: PointInTime,
retry_timer: ?*Timer,

const PacerStream = @This();
const State = enum { open, closed };
const Float = f32;

fn retry(self: *PacerStream) void {
    if (self.state == .closed)
        return;
    TRACE("ATEN_PACERSTREAM_RETRY UID={}", .{self.uid});
    self.retry_timer = null;
    self.callback.perform();
}

/// Read from a pacer stream honoring the rate parameters.
pub fn read(self: *PacerStream, buffer: []u8) !usize {
    std.debug.assert(self.state != .closed);
    if (self.retry_timer) |timer| {
        timer.cancel();
        self.retry_timer = null;
    }
    const t = self.aten.now();
    const delta = t.diff(self.prev_t).to(Float);
    self.quota += delta * self.byterate;
    self.quota = @min(self.quota, self.max_burst);
    self.prev_t = t;
    const missing_quota = self.min_burst - self.quota;
    if (missing_quota > 0) {
        const delay = missing_quota / self.byterate;
        self.retry_timer = self.aten.startTimer(
            t.add(Duration.from(delay)),
            Action.make(self, retry),
        );
        TRACE("ATEN-PACERSTREAM-READ-POSTPONE UID={} WANT={} DELAY={d}", //
            .{ self.uid, buffer.len, delay });
        return error.EAGAIN;
    }
    const limit = @min(buffer.len, std.math.lossyCast(usize, self.quota));
    const count = self.underlying_stream.read(buffer[0..limit]) catch |err| {
        TRACE("ATEN-PACERSTREAM-READ-FAIL UID={} WANT={} LIMIT={} ERR={}", //
            .{ self.uid, buffer.len, limit, err });
        return err;
    };
    self.quota -= @floatFromInt(count);
    TRACE("ATEN-PACERSTREAM-READ UID={} WANT={} LIMIT={} GOT={}", //
        .{ self.uid, buffer.len, limit, count });
    TRACE("ATEN-PACERSTREAM-READ-DUMP UID={} DATA={}", //
        .{ self.uid, r3.str(buffer[0..count]) });
    return count;
}

/// Close a pipe stream and the underlying byte stream with it.
pub fn close(self: *PacerStream) void {
    TRACE("ATEN-PACERSTREAM-CLOSE UID={}", .{self.uid});
    std.debug.assert(self.state != .closed);
    self.underlying_stream.close();
    if (self.retry_timer) |timer| {
        timer.cancel();
    }
    self.state = .closed;
    self.aten.wound(self);
}

/// Subscribe to readability notifications.
pub fn subscribe(self: *PacerStream, action: Action) void {
    TRACE("ATEN-PACERSTREAM-SUBSCRIBE UID={} ACT={}", .{ self.uid, action });
    self.callback = action;
}

/// Create a pacer stream on top of an underlying byte stream. The
/// pacer stream delivers the same bytes as the underlying stream at
/// the given constant data rate. Notifications are for more data are
/// timed so reads would deliver data in chunks no smaller than
/// `min_burst` bytes.
///
/// If the `read` rate temporarily falls behind the target byte rate,
/// the stream "catches up" within the limits of `max_burst`. A
/// shortfall larger than `max_burst` results in a dip in the data
/// rate that is not caught up with.
pub fn make(
    aten: *Aten,
    underlying_stream: ByteStream,
    byterate: Float,
    min_burst: usize,
    max_burst: usize,
) *PacerStream {
    const self = aten.alloc(PacerStream);
    self.* = .{
        .aten = aten,
        .uid = r3.newUID(),
        .callback = Action.Null,
        .state = .open,
        .underlying_stream = underlying_stream,
        .byterate = byterate,
        .min_burst = @floatFromInt(@max(min_burst, 1)),
        .max_burst = @floatFromInt(max_burst),
        .retry_timer = null,
        .quota = 0,
        .prev_t = aten.now(),
    };
    underlying_stream.subscribe(ByteStream.makeCallbackProbe(self));
    TRACE("ATEN-PACERSTREAM-CREATE UID={} PTR={} ATEN={} U-STR={} " ++
        "RATE={d} MIN={d} MAX={d}", .{
        self.uid,
        r3.ptr(self),
        aten.uid,
        self.underlying_stream,
        byterate,
        self.min_burst,
        self.max_burst,
    });
    return self;
}

pub fn reset(self: *PacerStream) void {
    TRACE("ATEN-PACERSTREAM-RESET UID={}", .{self.uid});
    self.quota = 0;
    self.prev_t = self.aten.now();
}
