const std = @import("std");
const r3 = @import("r3");
const Aten = @import("Aten.zig");
const Action = Aten.Action;
const Event = Aten.Event;
const BlobStream = Aten.BlobStream;
const ByteStream = Aten.ByteStream;
const TRACE = r3.trace;
const TRACE_ENABLED = r3.enabled;

aten: *Aten,
uid: r3.UID,
callback: Action,
production_state: ProductionState,
consumption_state: union(ConsumptionState) {
    open: struct {
        notifier: *Event, // to buffer excessive callbacks
        head_subscribed: bool,
    },
    closed: void,
},
queue: Queue,

const QueueStream = @This();
const ProductionState = enum { open, terminating, terminated };
const ConsumptionState = enum { open, closed };
const Queue = std.DoublyLinkedList(ByteStream);

fn notify(self: *QueueStream) void {
    if (self.production_state == .open)
        self.open.notifier.trigger();
}

fn doRead(self: *QueueStream, buffer: []u8) !usize {
    while (self.queue.first) |first_node| {
        const substream = first_node.data;
        const count = try substream.read(buffer);
        if (count > 0)
            return count;
        substream.close();
        _ = self.queue.popFirst();
        self.aten.dealloc(first_node);
        self.open.head_subscribed = false;
    }
    if (self.production_state == .open) {
        if (self.queue.first) |first_node| {
            if (!self.open.head_subscribed) {
                const substream = first_node.data;
                substream.subscribe(Action.make(self, notify));
                self.open.head_subscribed = true;
            }
        }
        return error.EAGAIN;
    }
    return 0;
}

pub fn read(self: *QueueStream, buffer: []u8) !usize {
    std.debug.assert(self.consumption_state == .open);
    const count = self.doRead(buffer) catch |err| {
        TRACE(
            "ATEN-QUEUESTREAM-READ-FAIL UID={} WANT={} ERR={}",
            .{ self.uid, buffer.len, err },
        );
        return err;
    };
    TRACE(
        "ATEN-QUEUESTREAM-READ UID={} WANT={} GOT={}",
        .{ self.uid, buffer.len, count },
    );
    TRACE(
        "ATEN-QUEUESTREAM-READ-DUMP UID={} DATA={}",
        .{ self.uid, r3.str(buffer[0..count]) },
    );
    return count;
}

fn flushQueue(self: *QueueStream) void {
    while (self.queue.popFirst()) |first_node| {
        const substream = first_node.data;
        substream.close();
        self.aten.dealloc(first_node);
    }
}

pub fn close(self: *QueueStream) void {
    std.debug.assert(self.consumption_state == .open);
    TRACE(
        "ATEN-QUEUESTREAM-CLOSE UID={} P-STATE={}",
        .{ self.uid, self.production_state },
    );
    self.flushQueue();
    self.open.notifier.destroy();
    self.consumption_state = .closed;
    if (self.production_state == .terminated) {
        self.aten.wound(self);
    }
}

pub fn subscribe(self: *QueueStream, action: Action) void {
    TRACE("ATEN-QUEUESTREAM-SUBSCRIBE UID={} ACT={}", .{ self.uid, action });
    self.callback = action;
}

pub fn make(aten: *Aten) *QueueStream {
    const self = aten.alloc(QueueStream);
    const probe = ByteStream.makeCallbackProbe(QueueStream);
    const notifier = Event.make(self.aten, Action.make(self, probe));
    self.* = .{
        .aten = aten,
        .uid = r3.newUID(),
        .callback = Action.Null,
        .production_state = .open,
        .consumption_state = .{
            .open = .{
                .notifier = notifier,
                .head_subscribed = false,
            },
        },
        .queue = .{},
    };
    TRACE(
        "ATEN-QUEUESTREAM-CREATE UID={} PTR={} ATEN={}",
        .{ self.uid, r3.ptr(self), aten.uid },
    );
    return self;
}

pub fn enqueue(self: *QueueStream, substream: ByteStream) void {
    std.debug.assert(self.production_state == .open);
    const node = self.aten.alloc(Queue.Node);
    node.data = substream;
    self.queue.append(node);
    TRACE("ATEN-QUEUESTREAM-ENQUEUE UID={} SUB={}", .{ self.uid, substream });
    if (self.consumption_state == .open) {
        if (self.queue.first.? == node) {
            self.open.notifier.trigger();
            self.open.subscribed = false;
        }
    }
}

pub fn push(self: *QueueStream, substream: ByteStream) void {
    std.debug.assert(self.production_state == .open);
    const node = self.aten.alloc(Queue.Node);
    node.data = substream;
    self.queue.preend(node);
    TRACE("ATEN-QUEUESTREAM-PUSH UID={} SUB={}", .{ self.uid, substream });
    if (self.consumption_state == .open) {
        self.open.notifier.trigger();
        self.open.subscribed = false;
    }
}

pub fn enqueueBlob(self: *QueueStream, blob: []const u8) void {
    TRACE(
        "ATEN-QUEUESTREAM-ENQUEUE-BLOB UID={} BLOB={}",
        .{ self.uid, r3.str(blob) },
    );
    self.enqueue(ByteStream.from(BlobStream.copy(self.aten, blob)));
}

pub fn pushBlob(self: *QueueStream, blob: []const u8) void {
    TRACE(
        "ATEN-QUEUESTREAM-ENQUEUE-BLOB UID={} BLOB={}",
        .{ self.uid, r3.str(blob) },
    );
    self.push(ByteStream.from(BlobStream.copy(self.aten, blob)));
}

fn wrapUp(self: *QueueStream) void {
    std.debug.assert(self.production_state == .terminating);
    std.debug.assert(self.consumption_state == .closed);
    self.flushQueue();
    self.aten.wound(self);
}

pub fn terminate(self: *QueueStream) void {
    std.debug.assert(self.production_state == .open);
    switch (self.consumption_state) {
        .open => {
            self.production_state = .terminated;
            self.open.notifier.trigger();
        },
        .closed => {
            self.production_state = .terminating;
            self.aten.execute(Action.make(self, wrapUp));
        },
    }
}
