//! A cooperative multitasking framework.
//!
//! `Aten` is a callback framework with stackable byte streams. It
//! provides a main loop, timers and file descriptor monitoring. Its
//! special twist are byte streams (see `ByteStream`), which resemble
//! `std.io.Reader` but specialize in nonblocking communication. Also,
//! `Aten`'s philosophy is not to have writers; instead of A writing
//! to B, B reads from A.
//!
//! `Aten` assumes memory allocation always succeeds. `Aten` does not
//! have built-in thread-safety but offers the necessary locking hooks
//! to work with multithreading.
//!
//! `Aten`'s main loop can accommodate other file-descriptor-based
//! event frameworks. Also, `Aten` can be integrated with foreign main
//! loops that support file descriptor registration.
//!
//! `Aten` depends on the `r3` tracing package.

const std = @import("std");
const r3 = @import("r3");
const TRACE = r3.trace;
const TRACE_ENABLED = r3.enabled;

allocator: std.mem.Allocator,
uid: r3.UID,
immediate: TaskQueue,
timers: TimerQueue,
registrations: RegistrationMap,
quit: bool,
multiplexer: Multiplexer,
recent: PointInTime,
hw_clock: clock_serv_t,

const Aten = @This();
const clock_serv_t = switch (os.tag) {
    .macos => os.clock_serv_t,
    else => void,
};
const Multiplexer = switch (os.tag) {
    .linux => TimerFdMultiplexer,
    // .linux => PipeMultiplexer, // if timerfd is not available
    else => KqueueMultiplexer,
};

/// Create an `Aten` object. Typically, an `Aten` application has a
/// single `Aten` object.
///
/// Internally, `Aten` uses the given allocator extensively and
/// assumes memory allocation never fails.
///
/// On Linux, `epoll` is used for multiplexing. On BSD, `kqueue` is
/// used.
pub fn create(allocator: std.mem.Allocator) !*Aten {
    const multiplexer = try Multiplexer.make();
    const aten = allocator.create(Aten) catch unreachable;
    var hw_clock: clock_serv_t = undefined;
    if (os.tag == .macos) {
        os.host_get_clock_service(
            os.mach_host_self(),
            os.SYSTEM_CLOCK,
            &hw_clock,
        );
    }
    aten.* = .{
        .allocator = allocator,
        .uid = r3.newUID(),
        .immediate = .{},
        .timers = TimerQueue.init(allocator, {}),
        .registrations = RegistrationMap.init(allocator),
        .quit = false,
        .multiplexer = multiplexer,
        .hw_clock = hw_clock,
        .recent = PointInTime.getJitteryClock(hw_clock),
    };
    TRACE("ATEN-CREATE UID={}", .{aten.uid});
    return aten;
}

/// Destroy the `Aten` object. All file descriptor registrations
/// should be unregistered prior to calling `destroy`.
pub fn destroy(self: *Aten) void {
    TRACE("ATEN-DESTROY UID={}", .{self.uid});
    self.cancelWakeup();
    while (self.earliestTimer()) |timer| {
        timer.cancel();
    }
    self.timers.deinit();
    while (true) {
        var it = self.registrations.iterator();
        if (it.next()) |entry| {
            const fd = entry.key_ptr.*;
            self.unregister(fd) catch unreachable; // TBD
        } else break;
    }
    self.registrations.deinit();
    if (os.tag == .macos) {
        os.mach_port_deallocate(os.mach_task_self(), self.hw_clock);
    }
    self.multiplexer.close();
    self.allocator.destroy(self);
}

/// Allocate memory for the given object type using the `Aten`
/// object's allocator. The allocation is assumed never to fail.
pub fn alloc(self: *Aten, comptime T: type) *T {
    return self.allocator.create(T) catch unreachable;
}

/// Free an object allocated with `alloc`.
pub fn dealloc(self: *Aten, object: anytype) void {
    self.allocator.destroy(object);
}

/// Allocate and make a copy of a block of bytes.
pub fn dupe(self: *Aten, orig: []const u8) []u8 {
    return self.allocator.dupe(u8, orig) catch unreachable;
}

/// Return the current point in time, which can be assumed to grow
/// monotonically.
pub fn now(self: *Aten) PointInTime {
    self.recent = switch (os.tag) {
        .linux, .macos => PointInTime.getMonotonicClock(self.hw_clock),
        else => blk: {
            const timestamp = PointInTime.getJitteryClock(self.hw_clock);
            break :blk if (timestamp.order(self.recent) == .gt)
                timestamp
            else
                self.recent.add(Duration.us);
        },
    };
    TRACE("ATEN-NOW UID={} TIME={}", .{ self.uid, self.recent });
    return self.recent;
}

// Return the timer that is due to expire first or `null` if no timer
// is pending.
fn earliestTimer(self: *Aten) ?*Timer {
    while (self.timers.peek()) |timed| {
        if (timed.canceled) {
            _ = self.timers.remove();
            timed.destroy();
            continue;
        }
        while (self.immediate.first) |immediate_node| {
            const immediate = immediate_node.data;
            if (immediate.canceled) {
                immediate.destroy();
                _ = self.immediate.popFirst();
                self.allocator.destroy(immediate_node);
                continue;
            }
            if (Timer.compare({}, immediate, timed) == .gt)
                break;
            return immediate;
        }
        return timed;
    }
    while (self.immediate.first) |immediate_node| {
        const immediate = immediate_node.data;
        if (immediate.canceled) {
            immediate.destroy();
            _ = self.immediate.popFirst();
            self.allocator.destroy(immediate_node);
            continue;
        }
        return immediate;
    }
    return null;
}

/// Start a timer that will expire at a give point in time, or without
/// delay if the expiry is in the past. Once the timer expires, the
/// given action is performed.
pub fn startTimer(
    self: *Aten,
    expires: PointInTime,
    action: Action,
) *Timer {
    const timer = Timer.make(self, expires, action);
    self.timers.add(timer) catch unreachable;
    self.wakeUp();
    TRACE("ATEN-TIMER-START SEQ-NO={} ATEN={} EXPIRES={} ACT={}", //
        .{ timer.seq_no, self.uid, expires, action });
    return timer;
}

fn _execute(self: *Aten, action: Action) *Timer {
    const timer = Timer.make(self, self.recent, action);
    const node = self.alloc(TaskQueue.Node);
    node.* = .{ .data = timer };
    self.immediate.append(node);
    self.wakeUp();
    return timer;
}

/// Perform the given action without a delay but not before the main
/// loop gets control again. Equivalent to starting a timer whose
/// expiry is in the past.
pub fn execute(self: *Aten, action: Action) *Timer {
    const timer = self._execute(action);
    TRACE("ATEN-EXECUTE SEQ-NO={} ATEN={} EXPIRES={} ACT={}", //
        .{ timer.seq_no, self.uid, timer.expires, timer.action });
    return timer;
}

/// Schedule the deallocation of the given object. Often, objects
/// cannot be freed on the spot because references to them may be
/// outstanding. Instead of garbage collection or smart pointers,
/// "wounding" is used. Any pending activities that would access the
/// wounded objects would find the object in a "zombie" state. Once
/// all such pending actions have been processed, the object is
/// deallocated.
///
/// The user is responsible for guaranteeing the wounded object will
/// not be accessed through timers, event registrations, global
/// variables and similar.
pub fn wound(self: *Aten, object: anytype) void {
    const WoundedObject = struct {
        aten: *Aten,
        obj: @TypeOf(object),

        pub fn commit(w: *@This()) void {
            w.aten.dealloc(w.obj);
            w.aten.dealloc(w);
        }
    };
    const tie = self.alloc(WoundedObject);
    tie.* = .{ .aten = self, .obj = object };
    const action = Action.make(tie, WoundedObject.commit);
    const timer = self._execute(action);
    TRACE("ATEN-WOUND SEQ-NO={} ACT={}", .{ timer.seq_no, action });
}

/// Return the readable file descriptor representing the `Aten`
/// object. The file descriptor can be registered in foreign main
/// loops. Whenever the file descriptor becomes readable, `poll` or
/// `poll2` must be called to dispatch callbacks.
pub fn getFd(self: *Aten) fd_t {
    return self.multiplexer.getFd();
}

/// When a foreign main loop is used and `getFd()` becomes readable,
/// `poll` or `poll2` must be called. If an expiry time is returned,
/// the caller is responsible for calling `poll` again at that time
/// (at the latest) even if `getFd()` is not triggered.
pub fn poll(self: *Aten) !?PointInTime {
    try self.setUpWakeup();
    self.armWakeup();
    const events: [1]*Event = undefined;
    const count = self.multiplexer.waitForEvents(events, 0) catch |err| {
        TRACE("ATEN-POLL-FAIL UID={} ERR={}", .{ self.uid, err });
        return err;
    };
    if (count == 1) {
        TRACE("ATEN-POLL-CALL-BACK UID={} EVENT={}", //
            .{ self.uid, events[0].uid });
        events[0].trigger();
        return self.scheduleWakeup(self.recent);
    }
    TRACE("ATEN-POLL-SPURIOUS UID={}", .{self.uid});
    if (self.earliestTimer()) |timer| {
        if (timer.expires > self.now()) {
            TRACE("ATEN-POLL-NEXT-TIMER UID={} EXPIRES={}", //
                .{ self.uid, timer.expires });
            return self.scheduleWakeup(timer.expires);
        }
        const action = timer.action;
        TRACE("ATEN-POLL-TIMEOUT SEQ-NO={} ACT={}", //
            .{ timer.seq_no, timer.action });
        if (TRACE_ENABLED("ATEN-TIMER-BT")) {
            if (timer.stack_trace) |stack_trace| {
                TRACE("ATEN-TIMER-BT SEQ-NO={} BT={}", //
                    .{ timer.seq_no, stack_trace });
            }
        }
        timer.cancel();
        action.perform();
        return self.scheduleWakeup(self.recent);
    }
    self.cancelWakeup(); // not absolutely necessary
    TRACE("ATEN-POLL-NO-TIMERS UID={}", .{self.uid});
    return null;
}

/// On modern Linux systems, `poll2` can be used instead of `poll`.
/// The return value does not require the foreign main loop to wake up
/// at a particular time but can simply monitor `getFd()`.
pub fn poll2(self: *Aten) !void {
    const nextTimeout = try self.poll();
    std.debug.assert(nextTimeout == null);
}

/// Make `loop` (the native main loop) return immediately.
pub fn quitLoop(self: *Aten) void {
    TRACE("ATEN-QUIT-LOOP UID={}", .{self.uid});
    self.quit = true;
    self.wakeUp();
}

/// After finishing the main loop, give an opportunity for immediately
/// pending actions to be executed. Do not wait for unexpired timers.
/// If immediate actions trigger further immediate actions, the
/// process can take a long time or indefinitely. Thus, the `flush`
/// operation is time-limited.
pub fn flush(self: *Aten, expires: PointInTime) !void {
    TRACE("ATEN-FLUSH UID={} EXPIRES={}", .{ self.uid, expires });
    while (self.now() < expires) {
        const next_timeout = self.poll() catch |err| {
            TRACE("ATEN-FLUSH-FAIL UID={} ERR={}", .{ self.uid, err });
            return err;
        };
        if (next_timeout) |timeout| {
            if (timeout <= self.now())
                continue;
        }
        TRACE("ATEN-FLUSHED UID={}", .{self.uid});
        return;
    }
    TRACE("ATEN-FLUSH-EXPIRED UID={}", .{self.uid});
    return error.ETIME;
}

// Return the duration till the next timer expiry.
fn takeImmediateAction(self: *Aten) ?Duration {
    const MaxIOStarvation = 20;
    var i: u8 = MaxIOStarvation;
    while (!self.quit and i > 0) : (i -= 1) {
        if (self.earliestTimer()) |timer| {
            const delay = timer.expires.diff(self.now());
            if (!delay.done()) {
                TRACE("ATEN-LOOP-NEXT-TIMER UID={} EXPIRES={}", //
                    .{ self.uid, timer.expires });
                return delay;
            }
            TRACE("ATEN-LOOP-TIMEOUT SEQ-NO={} ACT={}", //
                .{ timer.seq_no, timer.action });
            if (TRACE_ENABLED("ATEN-TIMER-BT")) {
                if (timer.stack_trace) |stack_trace| {
                    TRACE("ATEN-TIMER-BT SEQ-NO={} BT={}", //
                        .{ timer.seq_no, stack_trace });
                }
            }
            timer.cancel();
            timer.action.perform();
            continue;
        }
        TRACE("ATEN-LOOP-NO-TIMERS UID={}", .{self.uid});
        return null;
    }
    return Duration.zero;
}

/// The native, single-threaded `Aten` main loop, which keeps running
/// until `quitLoop` is called or an uncaught error takes place.
pub fn loop(self: *Aten) !void {
    TRACE("ATEN-LOOP UID={}", .{self.uid});
    try self._loop(Action.Null, Action.Null, Action.Null);
}

/// The native `Aten` main loop with generic hooks for locking and
/// unlocking. The function must be called in a locked state, and it
/// returns in a locked state. It releases the lock in a safe way.
///
/// All callbacks issued by `loopProtected` take place in a locked
/// state. Other threads invoking `Aten` functions must do it in a
/// locked state, as well, as all `Async` activities must be strictly
/// serialized.
pub fn loopProtected(self: *Aten, lock: Action, unlock: Action) !void {
    TRACE("ATEN-LOOP-PROTECTED UID={}", .{self.uid});
    try self.setUpWakeup();
    try self._loop(lock, unlock, Action.make(self, armWakeup));
}

fn _loop(
    self: *Aten,
    lock: Action,
    unlock: Action,
    rearm: Action,
) !void {
    self.quit = false;
    while (!self.quit) {
        const MaxIOBurst = 20;
        const delay = self.takeImmediateAction();
        if (self.quit) {
            TRACE("ATEN-LOOP-QUIT UID={}", .{self.uid});
            return;
        }
        TRACE("ATEN-LOOP-WAIT UID={} DELAY={?}", .{ self.uid, delay });
        var events: [MaxIOBurst]*Event = undefined;
        const count = blk: {
            unlock.perform();
            defer lock.perform();
            break :blk self.multiplexer.waitForEvents(
                &events,
                delay,
            ) catch |err| {
                TRACE("ATEN-LOOP-FAIL UID={} ERR={}", .{ self.uid, err });
                return err;
            };
        };
        rearm.perform();
        for (0..count) |i| {
            if (events[i] != &SentinelEvent) {
                events[i].trigger();
                TRACE("ATEN-LOOP-EXECUTE UID={} EVENT={}", //
                    .{ self.uid, events[i].uid });
            }
        }
    }
}

/// Register a file descriptor for edge-triggered monitoring. The
/// given action is invoked whenever the file descriptor becomes
/// readable or writable. However, the callback is guaranteed only if
/// the user has previously run into `error.EAGAIN` or
/// `error.EINPROGRESS`. A callback can also be invoked spuriously.
pub fn register(self: *Aten, fd: fd_t, action: Action) !void {
    const event = Event.make(self, action);
    errdefer event.destroy();
    self.multiplexer.register(fd, event) catch |err| {
        TRACE("ATEN-REGISTER-FAIL UID={} FD={} ACT={} ERR={}", //
            .{ self.uid, fd, action, err });
        return err;
    };
    self.registrations.put(fd, event) catch unreachable;
    self.wakeUp();
    TRACE("ATEN-REGISTER UID={} FD={} ACT={}", .{ self.uid, fd, action });
}

/// Register a file descriptor for level-triggered monitoring. The
/// given action is invoked whenever the file descriptor is readable.
/// A callback can also be invoked spuriously.
pub fn registerOldSchool(self: *Aten, fd: fd_t, action: Action) !void {
    nonblock(fd) catch |err| {
        TRACE("ATEN-REGISTER-OLD-SCHOOL-NONBLOCK-FAIL " ++
            "UID={} FD={} ACT={} ERR={}", //
            .{ self.uid, fd, action, err });
        return err;
    };
    const event = try Event.make(self, action);
    errdefer event.destroy();
    self.multiplexer.registerOldSchool(fd, event) catch |err| {
        TRACE("ATEN-REGISTER-OLD-SCHOOL-FAIL UID={} FD={} ACT={} ERR={}", //
            .{ self.uid, fd, action, err });
        return err;
    };
    self.registrations.put(fd, event) catch unreachable;
    self.wakeUp();
    TRACE("ATEN-REGISTER-OLD-SCHOOL UID={} FD={} ACT={}", //
        .{ self.uid, fd, action });
}

/// Modify the monitoring condition of a file descriptor that is
/// monitored in the level-triggered mode.
pub fn modifyOldSchool(
    self: *Aten,
    fd: fd_t,
    readable: bool,
    writable: bool,
) !void {
    const event = self.registrations.get(fd) orelse unreachable;
    self.multiplexer.modifyOldSchool(
        fd,
        event,
        readable,
        writable,
    ) catch |err| {
        TRACE("ATEN-MODIFY-OLD-SCHOOL-FAIL UID={} FD={} RD={} WR={} ERR={}", //
            .{ self.uid, fd, readable, writable, err });
        return err;
    };
    self.wakeUp();
    TRACE("ATEN-MODIFY-OLD-SCHOOL UID={} FD={} RD={} WR={}", //
        .{ self.uid, fd, readable, writable });
}

/// Cancel the registration of a file descriptor.
pub fn unregister(self: *Aten, fd: fd_t) !void {
    self.multiplexer.unregister(fd) catch |err| {
        TRACE("ATEN-UNREGISTER-FAIL UID={} FD={}", .{ self.uid, fd });
        return err;
    };
    const event = self.registrations.get(fd) orelse unreachable;
    event.destroy();
    if (!self.registrations.remove(fd))
        unreachable;
    TRACE("ATEN-UNREGISTER UID={} FD={}", .{ self.uid, fd });
}

fn setUpWakeup(self: *Aten) !void {
    self.multiplexer.setUpWakeup() catch |err| {
        TRACE("ATEN-SET-UP-WAKEUP-FAIL UID={} ERR={}", .{ self.uid, err });
        return err;
    };
    TRACE("ATEN-SET-UP-WAKEUP UID={}", .{self.uid});
}

fn armWakeup(self: *Aten) void {
    self.multiplexer.armWakeup();
    TRACE("ATEN-ARM-WAKEUP UID={}", .{self.uid});
}

// Wake up the (native or foreign) main loop from any thread.
fn wakeUp(self: *Aten) void {
    TRACE("ATEN-WAKE-UP UID={}", .{self.uid});
    self.multiplexer.wakeUp();
}

fn cancelWakeup(self: *Aten) void {
    self.multiplexer.cancelWakeup();
}

/// The operating-system primitives as seen by `Aten`. The
/// applications are encouraged to use the same primitives.
pub const os = switch (@import("builtin").os.tag) {
    .linux => |os_tag| struct {
        const tag = os_tag;
        const linux = std.os.linux;
        const E = linux.E;
        const errno = linux.E.init;
        const fd_t = linux.fd_t;
        const close = linux.close;
        const O = linux.O;
        const fcntl = linux.fcntl;
        const F = linux.F;
        const FD_CLOEXEC = linux.FD_CLOEXEC;
        const read = linux.read;
        const write = linux.write;
        const pipe = linux.pipe;
        const epoll_create1 = linux.epoll_create1;
        const epoll_ctl = linux.epoll_ctl;
        const epoll_wait = linux.epoll_wait;
        const epoll_event = linux.epoll_event;
        const EPOLL = linux.EPOLL;
        const clock_gettime = linux.clock_gettime;
        const CLOCK = linux.CLOCK;
        const timespec = linux.timespec;
        const itimerspec = linux.itimerspec;
        const timerfd_create = linux.timerfd_create;
        const timerfd_settime = linux.timerfd_settime;
        const TFD = linux.TFD;
    },
    else => |os_tag| struct {
        const tag = os_tag;
        const c = std.os.c;
        const E = c.E;
        fn errno(rc: anytype) E {
            return if (rc == -1) @enumFromInt(c._errno().*) else .SUCCESS;
        }
        const fd_t = c.fd_t;
        const close = c.close;
        const O = c.O;
        fn fcntl(fd: c.fd_t, cmd: c_int, arg: c_int) c_int {
            return c.fcntl(fd, cmd, arg);
        }
        const F = c.F;
        const FD_CLOEXEC = c.FD_CLOEXEC;
    },
};

/// A typed, parameterless callback interface that is used for
/// signaling, triggering etc.
pub const Action = struct {
    object: *const anyopaque,
    method: *const fn (*const anyopaque) void,

    /// Create an `Action` value.
    pub fn make(
        object: anytype,
        method: *const fn (@TypeOf(object)) void,
    ) Action {
        return .{
            .object = @ptrCast(object),
            .method = @ptrCast(method),
        };
    }

    /// Apply the `Action`'s method to its object.
    pub fn perform(self: Action) void {
        self.method(self.object);
    }

    /// A representation of an `Action` value.
    pub fn format(
        self: Action,
        _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("{x}/{x}", //
            .{ @intFromPtr(self.object), @intFromPtr(self.method) });
    }

    fn noOp(_: *const void) void {}

    /// An action that does nothing.
    pub const Null = Action.make(&{}, noOp);
};

/// A black-box data type representing a point in time.
pub const PointInTime = struct {
    ns_since_epoch: u64,

    fn getMonotonicClock(hw_clock: clock_serv_t) PointInTime {
        switch (os.tag) {
            .linux => {
                var t: os.timespec = undefined;
                _ = os.clock_gettime(os.CLOCK.MONOTONIC, &t);
                return .{
                    .ns_since_epoch = @intCast(
                        t.tv_sec * 1_000_000_000 + t.tv_nsec,
                    ),
                };
            },
            .macos => {
                var t: std.c.darwin.mach_timespec_t = undefined;
                _ = std.c.darwin.clock_get_time(hw_clock, &t);
                return .{
                    .ns_since_epoch = t.tv_sec * 1_000_000_000 + t.tv_nsec,
                };
            },
            else => unreachable,
        }
    }

    fn getJitteryClock(hw_clock: clock_serv_t) PointInTime {
        switch (os.tag) {
            .linux, .macos => {
                return getMonotonicClock(hw_clock);
            },
            else => {
                var t: os.timeval = undefined;
                _ = os.gettimeofday(&t, 0);
                const us = t.tv_sec * 1_000_000 + t.tv_usec;
                return .{ .ns_since_epoch = us * 1_000 };
            },
        }
    }

    pub fn add(self: PointInTime, delta: Duration) PointInTime {
        const udelta: u64 = @bitCast(delta.ns_delta);
        return .{ .ns_since_epoch = self.ns_since_epoch +% udelta };
    }

    pub fn sub(self: PointInTime, delta: Duration) PointInTime {
        const udelta: u64 = @bitCast(delta.ns_delta);
        return .{ .ns_since_epoch = self.ns_since_epoch -% udelta };
    }

    pub fn diff(self: PointInTime, other: PointInTime) Duration {
        const udelta: u64 = self.ns_since_epoch -% other.ns_since_epoch;
        return .{ .ns_delta = @bitCast(udelta) };
    }

    pub fn order(self: PointInTime, other: PointInTime) std.math.Order {
        return std.math.order(self.ns_since_epoch, other.ns_since_epoch);
    }

    /// A representation of a `PointInTime` value.
    pub fn format(
        self: PointInTime,
        _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("{}.{:0>9}", .{
            @divFloor(self.ns_since_epoch, 1_000_000_000),
            @mod(self.ns_since_epoch, 1_000_000_000),
        });
    }
};

/// A black-box data type representing a duration.
pub const Duration = struct {
    ns_delta: i64,

    /// A zero duration.
    pub const zero = Duration{ .ns_delta = 0 };

    /// A nanosecond duration.
    pub const ns = Duration{ .ns_delta = 1 };

    /// A microsecond duration.
    pub const us = ns.mul(1_000);

    /// A millisecond duration.
    pub const ms = us.mul(1_000);

    /// A one-second duration.
    pub const s = ms.mul(1_000);

    /// A one-minute duration.
    pub const min = s.mul(60);

    /// A one-hour duration.
    pub const h = min.mul(60);

    /// A 24-hour duration.
    pub const day = h.mul(24);

    /// Return the duration multiplied by a `multiplier`.
    pub fn mul(self: Duration, multiplier: anytype) Duration {
        return .{ .ns_delta = self.ns_delta * multiplier };
    }

    /// The sum of two durations.
    pub fn add(self: Duration, other: Duration) PointInTime {
        return .{ .ns_delta = self.ns_delta +% other.ns_delta };
    }

    pub fn sub(self: Duration, other: Duration) Duration {
        return .{ .ns_delta = self.ns_delta -% other.ns_delta };
    }

    pub fn order(self: Duration, other: Duration) std.math.Order {
        return std.math.order(self.ns_delta, other.ns_delta);
    }

    /// Return the duration in seconds converted to a numeric type.
    pub fn to(self: Duration, comptime T: type) T {
        const fdelta: T = @floatFromInt(self.ns_delta);
        return fdelta * 1e-9;
    }

    /// Construct a duration from a number of seconds.
    pub fn from(seconds: anytype) Duration {
        return .{ .ns_delta = @intFromFloat(seconds * 1e9) };
    }

    /// Return `true` iff the duration is less than zero.
    pub fn done(self: Duration) bool {
        return self.ns_delta <= 0;
    }

    /// Round upward saturating at maxInt. A missing duration results
    /// in -1 (epoll: infinite wait).
    pub fn toMilliseconds(delay: ?Duration) i32 {
        if (delay) |duration| {
            const cap = @as(i64, std.math.maxInt(i32)) * 1_000_000;
            if (duration.ns_delta >= cap)
                return std.math.maxInt(i32);
            return @intCast(@divFloor(duration.ns_delta + 999_999, 1_000_000));
        }
        return -1;
    }

    /// Convert a duration to a `timespec` value or `null` to `null`.
    pub fn toTimespec(delay: ?Duration) ?*os.timespec {
        if (delay) |duration| {
            return .{
                .tv_sec = @divFloor(duration.ns_delta, 1_000_000_000),
                .tv_nsec = @mod(duration.ns_delta, 1_000_000_000),
            };
        }
        return null;
    }

    /// A representation of a `Duration` value.
    pub fn format(
        self: Duration,
        _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("{}.{:0>9}", .{
            @divFloor(self.ns_delta, 1_000_000_000),
            @as(u64, @intCast(@mod(self.ns_delta, 1_000_000_000))),
        });
    }
};

/// `Aten`'s timer object used for scheduled timers as well as
/// immediate actions.
pub const Timer = struct {
    var next_seq_no: u64 = 0;

    aten: *Aten,
    expires: PointInTime,
    seq_no: u64,
    canceled: bool,
    action: Action,
    stack_trace: ?*Backtrace,

    fn compare(_: void, a: *const Timer, b: *const Timer) std.math.Order {
        const expiry_order = a.expires.order(b.expires);
        if (expiry_order != .eq)
            return expiry_order;
        return std.math.order(a.seq_no, b.seq_no);
    }

    fn make(aten: *Aten, expires: PointInTime, action: Action) *Timer {
        const timer = aten.alloc(Timer);
        var stack_trace: ?*Backtrace = null;
        if (TRACE_ENABLED("ATEN-TIMER-BT")) {
            stack_trace = aten.alloc(Backtrace);
            Backtrace.generate(stack_trace.?);
        }
        timer.* = .{
            .aten = aten,
            .expires = expires,
            .seq_no = next_seq_no,
            .canceled = false,
            .action = action,
            .stack_trace = stack_trace,
        };
        next_seq_no += 1;
        return timer;
    }

    fn destroy(self: *Timer) void {
        if (self.stack_trace) |stack_trace| {
            self.aten.allocator.destroy(stack_trace);
        }
        self.aten.allocator.destroy(self);
    }

    fn _cancel(self: *Timer) void {
        self.canceled = true;
    }

    /// Cancel a timer. A timer is canceled when it expires and its
    /// `Action` callback is invoked. The caller should make sure the
    /// timer is not canceled afterward.
    pub fn cancel(self: *Timer) void {
        TRACE("ATEN-TIMER-CANCEL SEQ-NO={}", .{self.seq_no});
        self._cancel();
    }
};

/// A "callback absorber" object. As callbacks are generated from
/// various sources, there is a risk of a high rate of spurious
/// notifications. An `Event` object can be triggered arbitrarily
/// often, but multiple pending callback events are folded into a
/// single callback event.
pub const Event = struct {
    const State = enum { idle, triggered, canceled, zombie };

    aten: *Aten,
    uid: r3.UID,
    state: State,
    action: Action,
    stack_trace: ?*Backtrace,

    /// Create an event.
    pub fn make(aten: *Aten, action: Action) *Event {
        const event = aten.alloc(Event);
        event.* = .{
            .aten = aten,
            .uid = r3.newUID(),
            .state = .idle,
            .action = action,
            .stack_trace = null,
        };
        TRACE("ATEN-EVENT-CREATE UID={} ATEN={} ACT={}", //
            .{ event.uid, aten.uid, action });
        return event;
    }

    fn setState(self: *Event, state: State) void {
        TRACE("ATEN-EVENT-SET-STATE UID={} OLD={} NEW={}", //
            .{ self.uid, self.state, state });
        self.state = state;
    }

    fn perform(self: *Event) void {
        TRACE("ATEN-EVENT-PERFORM UID={}", .{self.uid});
        switch (self.state) {
            .idle => unreachable,
            .triggered => {
                self.setState(.idle);
                self.action.perform();
            },
            .canceled => self.setState(.idle),
            .zombie => self.aten.allocator.destroy(self),
        }
    }

    /// Trigger an event. The associated callback action is guaranteed
    /// to be invoked subsequently at least once.
    pub fn trigger(self: *Event) void {
        TRACE("ATEN-EVENT-TRIGGER UID={}", .{self.uid});
        switch (self.state) {
            .idle => {
                self.setState(.triggered);
                _ = self.aten.execute(Action.make(self, Event.perform));
            },
            .triggered => {},
            .canceled => self.setState(.triggered),
            .zombie => unreachable,
        }
    }

    /// Cancel an event. Even pending callbacks are canceled right away.
    pub fn cancel(self: *Event) void {
        TRACE("ATEN-EVENT-CANCEL UID={}", .{self.uid});
        switch (self.state) {
            .idle, .canceled => {},
            .triggered => self.setState(.canceled),
            .zombie => unreachable,
        }
    }

    /// Destroy an event.
    pub fn destroy(self: *Event) void {
        TRACE("ATEN-EVENT-DESTROY UID={}", .{self.uid});
        switch (self.state) {
            .idle => self.aten.allocator.destroy(self),
            .triggered, .canceled => self.setState(.zombie),
            .zombie => unreachable,
        }
    }
};

const TaskQueue = std.DoublyLinkedList(*Timer);
const TimerQueue = std.PriorityQueue(*Timer, void, Timer.compare);
const RegistrationMap = std.AutoHashMap(fd_t, *Event);

/// The file descriptor type.
pub const fd_t = os.fd_t;

var SentinelEvent: Event = undefined; // a dummy sentinel

fn epollWaitForEvents(
    epollfd: fd_t,
    events: []*Event,
    delay: ?Duration,
) !usize {
    const MaxEvents = 200;
    const wish = @min(MaxEvents, events.len);
    var epoll_events: [MaxEvents]os.epoll_event = undefined;
    const count = try checkSyscall(
        os.epoll_wait(
            epollfd,
            &epoll_events,
            wish,
            Duration.toMilliseconds(delay),
        ),
    );
    for (0..count) |i| {
        events[i] = @ptrFromInt(epoll_events[i].data.ptr);
    }
    return count;
}

fn epollRegister(
    epollfd: fd_t,
    op: u32,
    fd: fd_t,
    event: *Event,
    triggers: u32,
) !void {
    var epoll_event = os.epoll_event{
        .events = triggers,
        .data = .{ .ptr = @intFromPtr(event) },
    };
    try doSyscall(os.epoll_ctl(epollfd, op, fd, &epoll_event));
}

const TimerFdMultiplexer = struct {
    epollfd: fd_t,

    // A timerfd is set up only if needed (multithreaded or foreign
    // main loop).
    timerfd: ?fd_t = null,

    fn make() !TimerFdMultiplexer {
        const epollfd = try fdSyscall(os.epoll_create1(os.EPOLL.CLOEXEC));
        return TimerFdMultiplexer{ .epollfd = epollfd };
    }

    fn waitForEvents(
        self: TimerFdMultiplexer,
        events: []*Event,
        delay: ?Duration,
    ) !usize {
        return try epollWaitForEvents(self.getFd(), events, delay);
    }

    fn register(self: TimerFdMultiplexer, fd: fd_t, event: *Event) !void {
        try nonblock(fd);
        const triggers = os.EPOLL.IN | os.EPOLL.OUT | os.EPOLL.ET;
        try epollRegister(self.getFd(), os.EPOLL.CTL_ADD, fd, event, triggers);
    }

    fn registerOldSchool(
        self: TimerFdMultiplexer,
        fd: fd_t,
        event: *Event,
    ) !void {
        try epollRegister(self.getFd(), os.EPOLL.CTL_ADD, fd, event, os.EPOLLIN);
    }

    fn modifyOldSchool(
        self: TimerFdMultiplexer,
        fd: fd_t,
        event: *Event,
        readable: bool,
        writable: bool,
    ) !void {
        const triggers =
            (if (readable) os.EPOLLIN else 0) |
            (if (writable) os.EPOLLOUT else 0);
        try epollRegister(self.getFd(), os.EPOLL.CTL_MOD, fd, event, triggers);
    }

    fn unregister(self: TimerFdMultiplexer, fd: fd_t) !void {
        try doSyscall(os.epoll_ctl(self.getFd(), os.EPOLL.CTL_DEL, fd, null));
    }

    fn close(self: TimerFdMultiplexer) void {
        if (self.timerfd) |timerfd| {
            self.unregister(timerfd) catch unreachable;
        }
        close_opt_fd(self.epollfd);
        close_opt_fd(self.timerfd);
    }

    fn getFd(self: TimerFdMultiplexer) fd_t {
        return self.epollfd;
    }

    fn setUpWakeup(self: *TimerFdMultiplexer) !void {
        if (self.timerfd != null)
            return;
        const timerfd = try fdSyscall(
            os.timerfd_create(os.CLOCK.MONOTONIC, .{ .CLOEXEC = true }),
        );
        self.timerfd = timerfd;
        try self.register(timerfd, &SentinelEvent);
        self.armWakeup();
    }

    fn armWakeup(self: TimerFdMultiplexer) void {
        if (self.timerfd) |fd| {
            var buffer: [1024]u8 = undefined;
            while (read(fd, &buffer) catch return > 0) {}
        }
    }

    fn wakeUp(self: TimerFdMultiplexer) void {
        if (self.timerfd) |timerfd| {
            // in the past but not zero
            const immediate = os.itimerspec{
                .it_interval = undefined,
                .it_value = .{ .tv_sec = 0, .tv_nsec = 1 },
            };
            doSyscall(os.timerfd_settime(
                timerfd,
                os.TFD.TIMER{ .ABSTIME = true },
                &immediate,
                null,
            )) catch unreachable;
        }
    }

    fn cancelWakeup(self: TimerFdMultiplexer) void {
        if (self.timerfd) |timerfd| {
            const never = os.itimerspec{
                .it_interval = undefined,
                .it_value = .{ .tv_sec = 0, .tv_nsec = 0 },
            };
            doSyscall(os.timerfd_settime(
                timerfd,
                os.TFD.TIMER{ .ABSTIME = true },
                &never,
                null,
            )) catch unreachable;
        }
    }
};

const PipeMultiplexer = struct {
    epollfd: fd_t,
    wakeup_readfd: ?fd_t = null, // set up only if needed
    wakeup_writefd: ?fd_t = null, // set up only if needed

    fn make() !PipeMultiplexer {
        const epollfd = try fdSyscall(os.epoll_create1(os.EPOLL.CLOEXEC));
        return PipeMultiplexer{ .epollfd = epollfd };
    }

    fn waitForEvents(
        self: PipeMultiplexer,
        events: []*Event,
        delay: ?Duration,
    ) !usize {
        return try epollWaitForEvents(self.getFd(), events, delay);
    }

    fn register(self: PipeMultiplexer, fd: fd_t, event: *Event) !void {
        try nonblock(fd);
        const triggers = os.EPOLL.IN | os.EPOLL.OUT | os.EPOLL.ET;
        try epollRegister(self.getFd(), os.EPOLL.CTL_ADD, fd, event, triggers);
    }

    fn registerOldSchool(self: PipeMultiplexer, fd: fd_t, event: *Event) !void {
        try epollRegister(self.getFd(), os.EPOLL.CTL_ADD, fd, event, os.EPOLLIN);
    }

    fn modifyOldSchool(
        self: PipeMultiplexer,
        fd: fd_t,
        event: *Event,
        readable: bool,
        writable: bool,
    ) !void {
        const triggers =
            (if (readable) os.EPOLLIN else 0) |
            (if (writable) os.EPOLLOUT else 0);
        try epollRegister(self.getFd(), os.EPOLL.CTL_MOD, fd, event, triggers);
    }

    fn unregister(self: PipeMultiplexer, fd: fd_t) !void {
        try doSyscall(os.epoll_ctl(self.getFd(), os.EPOLL.CTL_DEL, fd, null));
    }

    fn close(self: PipeMultiplexer) void {
        if (self.wakeup_readfd) |readfd| {
            self.unregister(readfd) catch unreachable;
        }
        close_opt_fd(self.epollfd);
        close_opt_fd(self.wakeup_readfd);
        close_opt_fd(self.wakeup_writefd);
    }

    fn getFd(self: PipeMultiplexer) fd_t {
        return self.epollfd;
    }

    fn setUpWakeup(self: *PipeMultiplexer) !void {
        if (self.wakeup_writefd != null)
            return;
        var fds: [2]fd_t = undefined;
        try doSyscall(os.pipe(&fds));
        self.wakeup_readfd = fds[0];
        self.wakeup_writefd = fds[1];
        try self.register(fds[0], &SentinelEvent);
        try nonblock(fds[1]);
        self.armWakeup();
    }

    fn armWakeup(self: PipeMultiplexer) void {
        if (self.wakeup_readfd) |fd| {
            var buffer: [1024]u8 = undefined;
            while (read(fd, &buffer) catch return > 0) {}
        }
    }

    fn wakeUp(self: PipeMultiplexer) void {
        const byte = [1]u8{0};
        if (self.wakeup_writefd) |writefd| {
            doSyscall(os.write(writefd, &byte, 1)) catch |err| {
                std.debug.assert(err == error.EAGAIN);
            };
        }
    }

    fn cancelWakeup(self: PipeMultiplexer) void {
        _ = self;
    }
};

// KqueueMultiplexer has not yet been tested at all. It may not even
// compile.
const KqueueMultiplexer = struct {
    kqueuefd: fd_t,
    wakeup_needed: bool = false,

    fn make() !KqueueMultiplexer {
        const kqueuefd = try fdSyscall(os.kqueue());
        try cloexec(kqueuefd);
        return KqueueMultiplexer{ .kqueuefd = kqueuefd };
    }

    fn waitForEvents(
        self: KqueueMultiplexer,
        events: []*Event,
        delay: ?Duration,
    ) !usize {
        const MaxEvents = 200;
        const wish = @min(MaxEvents, events.len);
        var kevents: [MaxEvents]os.Kevent = undefined;
        const wait = Duration.toTimespec(delay);
        const count = try checkSyscall(os.kevent(
            self.getFd(),
            &kevents, // dummy
            0,
            &kevents,
            wish,
            &wait,
        ));
        for (0..count) |i| {
            events[i] = @ptrCast(kevents[i].udata);
        }
        return count;
    }

    fn kqueueRegister(
        self: KqueueMultiplexer,
        fd: fd_t,
        event: *Event,
        read_flags: u16,
        write_flags: u16,
    ) !void {
        const changes = [2]os.Kevent{
            .{
                .ident = @intCast(fd),
                .filter = os.EVFILT_READ,
                .flags = read_flags,
                .fflags = 0,
                .data = 0,
                .udata = @intFromPtr(event),
            },
            .{
                .ident = @intCast(fd),
                .filter = os.EVFILT_WRITE,
                .flags = write_flags,
                .fflags = 0,
                .data = 0,
                .udata = @intFromPtr(event),
            },
        };
        try os.doSyscall(
            os.kevent(
                self.getFd(),
                &changes,
                2,
                &changes, // dummy
                0,
                null,
            ),
        );
    }

    fn register(self: KqueueMultiplexer, fd: fd_t, event: *Event) !void {
        try nonblock(fd);
        const read_flags = os.EV_ADD | os.EV_CLEAR;
        const write_flags = os.EV_ADD | os.EV_CLEAR;
        try self.kqueueRegister(fd, event, read_flags, write_flags);
    }

    fn registerOldSchool(
        self: KqueueMultiplexer,
        fd: fd_t,
        event: *Event,
    ) !void {
        const read_flags = os.EV_ADD;
        const write_flags = os.EV_ADD | os.EV_DISABLE;
        try self.kqueueRegister(fd, event, read_flags, write_flags);
    }

    fn modifyOldSchool(
        self: KqueueMultiplexer,
        fd: fd_t,
        event: *Event,
        readable: bool,
        writable: bool,
    ) !void {
        const read_flags = if (readable) os.EV_ENABLE else os.DISABLE;
        const write_flags = if (writable) os.EV_ENABLE else os.DISABLE;
        try self.kqueueRegister(fd, event, read_flags, write_flags);
    }

    fn unregister(self: KqueueMultiplexer, fd: fd_t) !void {
        const dummyEvent: Event = undefined;
        const read_flags = os.EV_DELETE;
        const write_flags = os.EV_DELETE;
        try self.kqueueRegister(fd, &dummyEvent, read_flags, write_flags);
    }

    fn close(self: KqueueMultiplexer) void {
        close_opt_fd(self.kqueuefd);
    }

    fn getFd(self: KqueueMultiplexer) fd_t {
        return self.kqueuefd;
    }

    fn setUpWakeup(self: *KqueueMultiplexer) !void {
        if (self.wakeup_needed)
            return;
        self.wakeup_needed = true;
        self.armWakeup();
    }

    fn armWakeup(self: KqueueMultiplexer) void {
        _ = self;
    }

    fn wakeUp(self: KqueueMultiplexer) void {
        if (self.wakeup_needed)
            self.setWakeupTime(0);
    }

    fn cancelWakeup(self: KqueueMultiplexer) void {
        const changes = [1]os.Kevent{
            .{
                .ident = 0,
                .filter = os.EVFILT_TIMER,
                .flags = os.EV_DELETE,
                .fflags = 0,
                .data = 0,
                .udata = null,
            },
        };
        try os.checkSyscall(
            os.kevent(
                self.getFd(),
                &changes,
                1,
                &changes, // dummy
                0,
                null,
            ),
        );
    }
};

const Backtrace = struct {
    store: [16]usize,
    stack: []usize,

    inline fn generate(bt: *Backtrace) void {
        var it = std.debug.StackIterator.init(@returnAddress(), null);
        defer it.deinit();
        var i: u8 = 0;
        while (it.next()) |address| {
            if (i == bt.store.len)
                break;
            bt.store[i] = address;
            i += 1;
        }
        bt.stack = bt.store[0..i];
    }

    pub fn format(
        self: Backtrace,
        _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        if (self.stack.len > 0) {
            try writer.print("{x}", .{self.stack[0]});
            for (self.stack[1..]) |address|
                try writer.print(":{x}", .{address});
        }
    }
};

/// The `read` system call of the operating system.
pub fn read(fd: fd_t, buffer: []u8) !usize {
    return checkSyscall(os.read(fd, buffer.ptr, buffer.len));
}

/// The `close` system call of the operating system.
pub fn close(fd: fd_t) void {
    doSyscall(os.close(fd)) catch unreachable;
}

fn close_opt_fd(opt_fd: ?fd_t) void {
    if (opt_fd) |fd|
        doSyscall(os.close(fd)) catch unreachable;
}

// Turn on the `FD_CLOEXEC` flag of the file descriptor.
fn cloexec(fd: fd_t) !void {
    const flags = try checkSyscall(os.fcntl(fd, os.F.GETFD, 0));
    try doSyscall(os.fcntl(fd, os.F.SETFD, flags | os.FD_CLOEXEC));
}

// Turn on the `O_NONBLOCK` flag of the file descriptor.
fn nonblock(fd: fd_t) !void {
    var flags = try checkSyscall(os.fcntl(fd, os.F.GETFL, 0));
    var o_flags: os.O = @bitCast(@as(u32, @intCast(flags)));
    o_flags.NONBLOCK = true;
    flags = @intCast(@as(u32, @bitCast(o_flags)));
    try doSyscall(os.fcntl(fd, os.F.SETFL, flags));
}

// Native error constants corresponding to the familiar `errno` enums.
const SystemError = error{
    EPERM,
    ENOENT,
    ESRCH,
    EINTR,
    EIO,
    ENXIO,
    E2BIG,
    ENOEXEC,
    EBADF,
    ECHILD,
    EAGAIN,
    ENOMEM,
    EACCES,
    EFAULT,
    ENOTBLK,
    EBUSY,
    EEXIST,
    EXDEV,
    ENODEV,
    ENOTDIR,
    EISDIR,
    EINVAL,
    ENFILE,
    EMFILE,
    ENOTTY,
    ETXTBSY,
    EFBIG,
    ENOSPC,
    ESPIPE,
    EROFS,
    EMLINK,
    EPIPE,
    EDOM,
    ERANGE,
    EDEADLK,
    ENAMETOOLONG,
    ENOLCK,
    ENOSYS,
    ENOTEMPTY,
    ELOOP,
    EWOULDBLOCK,
    ENOMSG,
    EIDRM,
    ECHRNG,
    EL2NSYNC,
    EL3HLT,
    EL3RST,
    ELNRNG,
    EUNATCH,
    ENOCSI,
    EL2HLT,
    EBADE,
    EBADR,
    EXFULL,
    ENOANO,
    EBADRQC,
    EBADSLT,
    EDEADLOCK,
    EBFONT,
    ENOSTR,
    ENODATA,
    ETIME,
    ENOSR,
    ENONET,
    ENOPKG,
    EREMOTE,
    ENOLINK,
    EADV,
    ESRMNT,
    ECOMM,
    EPROTO,
    EMULTIHOP,
    EDOTDOT,
    EBADMSG,
    EOVERFLOW,
    ENOTUNIQ,
    EBADFD,
    EREMCHG,
    ELIBACC,
    ELIBBAD,
    ELIBSCN,
    ELIBMAX,
    ELIBEXEC,
    EILSEQ,
    ERESTART,
    ESTRPIPE,
    EUSERS,
    ENOTSOCK,
    EDESTADDRREQ,
    EMSGSIZE,
    EPROTOTYPE,
    ENOPROTOOPT,
    EPROTONOSUPPORT,
    ESOCKTNOSUPPORT,
    EOPNOTSUPP,
    EPFNOSUPPORT,
    EAFNOSUPPORT,
    EADDRINUSE,
    EADDRNOTAVAIL,
    ENETDOWN,
    ENETUNREACH,
    ENETRESET,
    ECONNABORTED,
    ECONNRESET,
    ENOBUFS,
    EISCONN,
    ENOTCONN,
    ESHUTDOWN,
    ETOOMANYREFS,
    ETIMEDOUT,
    ECONNREFUSED,
    EHOSTDOWN,
    EHOSTUNREACH,
    EALREADY,
    EINPROGRESS,
    ESTALE,
    EUCLEAN,
    ENOTNAM,
    ENAVAIL,
    EISNAM,
    EREMOTEIO,
    EDQUOT,
    ENOMEDIUM,
    EMEDIUMTYPE,
    ECANCELED,
    ENOKEY,
    EKEYEXPIRED,
    EKEYREVOKED,
    EKEYREJECTED,
    EOWNERDEAD,
    ENOTRECOVERABLE,
    ERFKILL,
    EHWPOISON,
} || std.posix.UnexpectedError;

fn errnoToError(err: os.E) SystemError {
    return switch (err) {
        .SUCCESS => unreachable,
        .PERM => error.EPERM,
        .NOENT => error.ENOENT,
        .SRCH => error.ESRCH,
        .INTR => error.EINTR,
        .IO => error.EIO,
        .NXIO => error.ENXIO,
        .@"2BIG" => error.E2BIG,
        .NOEXEC => error.ENOEXEC,
        .BADF => error.EBADF,
        .CHILD => error.ECHILD,
        .AGAIN => error.EAGAIN,
        .NOMEM => error.ENOMEM,
        .ACCES => error.EACCES,
        .FAULT => error.EFAULT,
        .NOTBLK => error.ENOTBLK,
        .BUSY => error.EBUSY,
        .EXIST => error.EEXIST,
        .XDEV => error.EXDEV,
        .NODEV => error.ENODEV,
        .NOTDIR => error.ENOTDIR,
        .ISDIR => error.EISDIR,
        .INVAL => error.EINVAL,
        .NFILE => error.ENFILE,
        .MFILE => error.EMFILE,
        .NOTTY => error.ENOTTY,
        .TXTBSY => error.ETXTBSY,
        .FBIG => error.EFBIG,
        .NOSPC => error.ENOSPC,
        .SPIPE => error.ESPIPE,
        .ROFS => error.EROFS,
        .MLINK => error.EMLINK,
        .PIPE => error.EPIPE,
        .DOM => error.EDOM,
        .RANGE => error.ERANGE,
        .DEADLK => error.EDEADLK,
        .NAMETOOLONG => error.ENAMETOOLONG,
        .NOLCK => error.ENOLCK,
        .NOSYS => error.ENOSYS,
        .NOTEMPTY => error.ENOTEMPTY,
        .LOOP => error.ELOOP,
        .NOMSG => error.ENOMSG,
        .IDRM => error.EIDRM,
        .CHRNG => error.ECHRNG,
        .L2NSYNC => error.EL2NSYNC,
        .L3HLT => error.EL3HLT,
        .L3RST => error.EL3RST,
        .LNRNG => error.ELNRNG,
        .UNATCH => error.EUNATCH,
        .NOCSI => error.ENOCSI,
        .L2HLT => error.EL2HLT,
        .BADE => error.EBADE,
        .BADR => error.EBADR,
        .XFULL => error.EXFULL,
        .NOANO => error.ENOANO,
        .BADRQC => error.EBADRQC,
        .BADSLT => error.EBADSLT,
        .BFONT => error.EBFONT,
        .NOSTR => error.ENOSTR,
        .NODATA => error.ENODATA,
        .TIME => error.ETIME,
        .NOSR => error.ENOSR,
        .NONET => error.ENONET,
        .NOPKG => error.ENOPKG,
        .REMOTE => error.EREMOTE,
        .NOLINK => error.ENOLINK,
        .ADV => error.EADV,
        .SRMNT => error.ESRMNT,
        .COMM => error.ECOMM,
        .PROTO => error.EPROTO,
        .MULTIHOP => error.EMULTIHOP,
        .DOTDOT => error.EDOTDOT,
        .BADMSG => error.EBADMSG,
        .OVERFLOW => error.EOVERFLOW,
        .NOTUNIQ => error.ENOTUNIQ,
        .BADFD => error.EBADFD,
        .REMCHG => error.EREMCHG,
        .LIBACC => error.ELIBACC,
        .LIBBAD => error.ELIBBAD,
        .LIBSCN => error.ELIBSCN,
        .LIBMAX => error.ELIBMAX,
        .LIBEXEC => error.ELIBEXEC,
        .ILSEQ => error.EILSEQ,
        .RESTART => error.ERESTART,
        .STRPIPE => error.ESTRPIPE,
        .USERS => error.EUSERS,
        .NOTSOCK => error.ENOTSOCK,
        .DESTADDRREQ => error.EDESTADDRREQ,
        .MSGSIZE => error.EMSGSIZE,
        .PROTOTYPE => error.EPROTOTYPE,
        .NOPROTOOPT => error.ENOPROTOOPT,
        .PROTONOSUPPORT => error.EPROTONOSUPPORT,
        .SOCKTNOSUPPORT => error.ESOCKTNOSUPPORT,
        .OPNOTSUPP => error.EOPNOTSUPP,
        .PFNOSUPPORT => error.EPFNOSUPPORT,
        .AFNOSUPPORT => error.EAFNOSUPPORT,
        .ADDRINUSE => error.EADDRINUSE,
        .ADDRNOTAVAIL => error.EADDRNOTAVAIL,
        .NETDOWN => error.ENETDOWN,
        .NETUNREACH => error.ENETUNREACH,
        .NETRESET => error.ENETRESET,
        .CONNABORTED => error.ECONNABORTED,
        .CONNRESET => error.ECONNRESET,
        .NOBUFS => error.ENOBUFS,
        .ISCONN => error.EISCONN,
        .NOTCONN => error.ENOTCONN,
        .SHUTDOWN => error.ESHUTDOWN,
        .TOOMANYREFS => error.ETOOMANYREFS,
        .TIMEDOUT => error.ETIMEDOUT,
        .CONNREFUSED => error.ECONNREFUSED,
        .HOSTDOWN => error.EHOSTDOWN,
        .HOSTUNREACH => error.EHOSTUNREACH,
        .ALREADY => error.EALREADY,
        .INPROGRESS => error.EINPROGRESS,
        .STALE => error.ESTALE,
        .UCLEAN => error.EUCLEAN,
        .NOTNAM => error.ENOTNAM,
        .NAVAIL => error.ENAVAIL,
        .ISNAM => error.EISNAM,
        .REMOTEIO => error.EREMOTEIO,
        .DQUOT => error.EDQUOT,
        .NOMEDIUM => error.ENOMEDIUM,
        .MEDIUMTYPE => error.EMEDIUMTYPE,
        .CANCELED => error.ECANCELED,
        .NOKEY => error.ENOKEY,
        .KEYEXPIRED => error.EKEYEXPIRED,
        .KEYREVOKED => error.EKEYREVOKED,
        .KEYREJECTED => error.EKEYREJECTED,
        .OWNERDEAD => error.EOWNERDEAD,
        .NOTRECOVERABLE => error.ENOTRECOVERABLE,
        .RFKILL => error.ERFKILL,
        .HWPOISON => error.EHWPOISON,
        else => std.posix.unexpectedErrno(err),
    };
}

// Trigger an error if the system call result indicates one.
// Otherwise, pass the system call return value to the caller as-is.
inline fn checkSyscall(result: anytype) !@TypeOf(result) {
    return switch (os.errno(result)) {
        .SUCCESS => result,
        else => |errno| errnoToError(errno),
    };
}

// Trigger an error if the system call result indicates one.
// Otherwise, absorb the return value.
inline fn doSyscall(result: anytype) !void {
    _ = try checkSyscall(result);
}

// Trigger an error if the system call result indicates one.
// Otherwise, pass the system call return value to the caller as a
// file descriptor.
inline fn fdSyscall(result: anytype) !fd_t {
    return @intCast(try checkSyscall(result));
}

/// A byte stream that emits given bytes.
pub const BlobStream = @import("BlobStream.zig");

/// The generic byte stream interface. Any byte stream object `s` can
/// be converted to a `ByteStream` value with `ByteStream.from(s)`.
pub const ByteStream = @import("ByteStream.zig");

/// A byte stream template. The returned byte stream type hard-codes
/// the `read` return value.
pub const DummyStream = @import("DummyStream.zig").makeType;

/// A byte stream that never emits a byte but responds to `read` with
/// `error.EAGAIN`.
pub const DryStream = DummyStream(error.EAGAIN);

/// A byte stream that emits an end of file (that is, 0).
pub const EmptyStream = DummyStream(0);

/// A byte stream that emits the output of the underlying byte stream
/// at a constant rate.
pub const PacerStream = @import("PacerStream.zig");

/// A byte stream wrapper for an open, readable file descriptor.
pub const PipeStream = @import("PipeStream.zig");

/// A byte stream that allows concatenating byte streams dynamically.
/// In particular, a `QueueStream` is used to transmit data.
pub const QueueStream = @import("QueueStream.zig");

/// A byte stream that emits an unending sequence of zero bytes.
pub const ZeroStream = @import("ZeroStream.zig");

fn testingAllocator() std.mem.Allocator {
    const S = struct {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const allocator = gpa.allocator();
    };
    return S.allocator;
}

fn elapsed(start_instant: std.time.Instant, end_instant: std.time.Instant) f32 {
    const nanoseconds: f32 = @floatFromInt(end_instant.since(start_instant));
    return 1e-9 * nanoseconds;
}

test "Aten-immediate-quit" {
    const test_name = r3.str(@src().fn_name);
    TRACE("ATEN-TEST-BEGIN TEST={}", .{test_name});
    defer TRACE("ATEN-TEST-END TEST={}", .{test_name});
    errdefer TRACE("ATEN-TEST-FAIL TEST={}", .{test_name});
    const start_instant = try std.time.Instant.now();

    const TestApp = struct {
        aten: *Aten,

        const Self = @This();

        fn run(self: *Self) !void {
            _ = self.aten.execute(Action.make(self.aten, Aten.quitLoop));
            try self.aten.loop();
        }
    };

    const aten = try Aten.create(testingAllocator());
    defer aten.destroy();
    var app = TestApp{ .aten = aten };
    try app.run();
    const runtime = elapsed(start_instant, try std.time.Instant.now());
    try std.testing.expectApproxEqRel(0.0, runtime, 0.5);
}

test "Aten-timed-quit" {
    const test_name = r3.str(@src().fn_name);
    TRACE("ATEN-TEST-BEGIN TEST={}", .{test_name});
    defer TRACE("ATEN-TEST-END TEST={}", .{test_name});
    errdefer TRACE("ATEN-TEST-FAIL TEST={}", .{test_name});
    const start_instant = try std.time.Instant.now();

    const TestApp = struct {
        aten: *Aten,

        const Self = @This();

        fn run(self: *Self) !void {
            _ = self.aten.startTimer(
                self.aten.now().add(Duration.ms.mul(5_300)),
                Action.make(self.aten, Aten.quitLoop),
            );
            try self.aten.loop();
        }
    };

    const aten = try Aten.create(testingAllocator());
    defer aten.destroy();
    var app = TestApp{ .aten = aten };
    try app.run();
    const runtime = elapsed(start_instant, try std.time.Instant.now());
    try std.testing.expectApproxEqRel(5.3, runtime, 0.5);
}

test "Aten-overdue-quit" {
    const test_name = r3.str(@src().fn_name);
    TRACE("ATEN-TEST-BEGIN TEST={}", .{test_name});
    defer TRACE("ATEN-TEST-END TEST={}", .{test_name});
    errdefer TRACE("ATEN-TEST-FAIL TEST={}", .{test_name});
    const start_instant = try std.time.Instant.now();

    const TestApp = struct {
        aten: *Aten,

        const Self = @This();

        fn run(self: *Self) !void {
            _ = self.aten.startTimer(
                self.aten.now().sub(Duration.ms.mul(2_300)),
                Action.make(self.aten, Aten.quitLoop),
            );
            try self.aten.loop();
        }
    };

    const aten = try Aten.create(testingAllocator());
    defer aten.destroy();
    var app = TestApp{ .aten = aten };
    try app.run();
    const runtime = elapsed(start_instant, try std.time.Instant.now());
    try std.testing.expectApproxEqRel(0.0, runtime, 0.5);
}

test "Aten-read-in-stream" {
    const test_name = r3.str(@src().fn_name);
    TRACE("ATEN-TEST-BEGIN TEST={}", .{test_name});
    defer TRACE("ATEN-TEST-END TEST={}", .{test_name});
    errdefer TRACE("ATEN-TEST-FAIL TEST={}", .{test_name});
    const start_instant = try std.time.Instant.now();

    const TestApp = struct {
        aten: *Aten,
        feed: ByteStream,
        verdict: ?anyerror,

        const Self = @This();

        fn run(self: *Self) !void {
            self.feed.subscribe(Action.make(self, probe));
            _ = self.aten.execute(Action.make(self, probe));
            _ = self.aten.startTimer(
                self.aten.now().add(Duration.s.mul(30)),
                Action.make(self, timedOut),
            );
            try self.aten.loop();
        }

        fn timedOut(self: *Self) void {
            TRACE("ATEN-TEST-TIMEOUT", .{});
            self.verdict = error.ETIMEDOUT;
            self.aten.quitLoop();
        }

        fn probe(self: *Self) void {
            var buffer: [100]u8 = undefined;
            while (true) {
                const count = self.feed.read(&buffer) catch |err| {
                    if (err != error.EAGAIN) {
                        TRACE("ATEN-TEST-PROBE-FAIL ERR={}", .{err});
                        self.verdict = err;
                        self.aten.quitLoop();
                    }
                    TRACE("ATEN-TEST-PROBE-AGAIN", .{});
                    return;
                };
                if (count == 0) {
                    TRACE("ATEN-TEST-PROBE-EOF", .{});
                    self.aten.quitLoop();
                    return;
                }
                TRACE("ATEN-TEST-PROBE-READ GOT={}", .{count});
                TRACE("ATEN-TEST-PROBE-READ-DUMP TEXT={}", //
                    .{r3.str(buffer[0..count])});
            }
        }
    };

    const aten = try Aten.create(testingAllocator());
    defer aten.destroy();
    const test_data = "Hello, world!";
    const blob_stream = BlobStream.make(aten, test_data);
    const pacer_stream = PacerStream.make(
        aten,
        ByteStream.from(blob_stream),
        1,
        1,
        1,
    );
    defer pacer_stream.close();
    var app = TestApp{
        .aten = aten,
        .feed = ByteStream.from(pacer_stream),
        .verdict = null,
    };
    try app.run();
    if (app.verdict) |err| {
        return err;
    }
    const runtime = elapsed(start_instant, try std.time.Instant.now());
    const expected_duration: f32 = @floatFromInt(test_data.len);
    try std.testing.expectApproxEqRel(expected_duration, runtime, 0.5);
}
