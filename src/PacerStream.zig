const std = @import("std");
const r3 = @import("r3");
const Aten = @import("Aten.zig");
const Action = Aten.Action;
const ByteStream = Aten.ByteStream;
const PointInTime = Aten.PointInTime;
const Duration = Aten.Duration;
const Timer = Aten.Timer;
const TRACE = r3.trace;
const TRACE_ENABLED = r3.enabled;

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

pub fn read(self: *PacerStream, buffer: []u8) !usize {
    std.debug.assert(self.state != .closed);
    if (self.retry_timer) |timer| {
        timer.cancel();
        self.retry_timer = null;
    }
    const t = self.aten.now();
    const delta = t.sub(self.prev_t).to(Float);
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
        TRACE(
            "ATEN-PACERSTREAM-READ-POSTPONE UID={} WANT={} DELAY={d}",
            .{ self.uid, buffer.len, delay },
        );
        return error.EAGAIN;
    }
    const limit = @min(buffer.len, @as(usize, @intFromFloat(self.quota)));
    const count = self.underlying_stream.read(buffer[0..limit]) catch |err| {
        TRACE(
            "ATEN-PACERSTREAM-READ-FAIL UID={} WANT={} LIMIT={} ERR={}",
            .{ self.uid, buffer.len, limit, err },
        );
        return err;
    };
    self.quota -= @floatFromInt(count);
    TRACE(
        "ATEN-PACERSTREAM-READ UID={} WANT={} LIMIT={} GOT={}",
        .{ self.uid, buffer.len, limit, count },
    );
    TRACE(
        "ATEN-PACERSTREAM-READ-DUMP UID={} DATA={}",
        .{ self.uid, r3.str(buffer[0..count]) },
    );
    return count;
}

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

pub fn subscribe(self: *PacerStream, action: Action) void {
    TRACE("ATEN-PACERSTREAM-SUBSCRIBE UID={} ACT={}", .{ self.uid, action });
    self.callback = action;
}

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
    const probe = ByteStream.makeCallbackProbe(PacerStream);
    const action = Action.make(self, probe);
    underlying_stream.subscribe(action);
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
