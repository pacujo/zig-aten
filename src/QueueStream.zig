//! A queue of byte streams. A queue stream offers a way to "write"
//! into one end of a byte stream and read it from the other end.
//! Instead of writing individual bytes to a queue stream, other byte
//! streams are enqueued to it.

const std = @import("std");
const r3 = @import("r3");
const Aten = @import("Aten.zig");
const Action = Aten.Action;
const Event = Aten.Event;
const BlobStream = Aten.BlobStream;
const ByteStream = Aten.ByteStream;
const TRACE = r3.trace;

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
    self.consumption_state.open.notifier.trigger();
}

fn doRead(self: *QueueStream, buffer: []u8) !usize {
    if (buffer.len == 0)
        return 0;
    while (self.queue.first) |first_node| {
        const substream = first_node.data;
        const count = substream.read(buffer) catch |err| {
            if (!self.consumption_state.open.head_subscribed) {
                substream.subscribe(Action.make(self, notify));
                self.consumption_state.open.head_subscribed = true;
            }
            return err;
        };
        if (count > 0)
            return count;
        substream.close();
        _ = self.queue.popFirst();
        self.aten.dealloc(first_node);
        self.consumption_state.open.head_subscribed = false;
    }
    if (self.production_state == .open)
        return error.EAGAIN;
    return 0;
}

/// Read from a queue stream. If the queue is empty but the queue
/// stream has not been terminated, `error.EAGAIN` is returned. If the
/// queue is empty and teh queue stream has been terminated, `0` is
/// returned.
///
/// Otherwise, deliver bytes from the first underlying byte stream in
/// the queue. If it is exhausted, it is closed and removed and
/// reading moves to the next byte stream in the queue.
pub fn read(self: *QueueStream, buffer: []u8) !usize {
    std.debug.assert(self.consumption_state == .open);
    const count = self.doRead(buffer) catch |err| {
        TRACE("ATEN-QUEUESTREAM-READ-FAIL UID={} WANT={} ERR={}", //
            .{ self.uid, buffer.len, err });
        return err;
    };
    TRACE("ATEN-QUEUESTREAM-READ UID={} WANT={} GOT={}", //
        .{ self.uid, buffer.len, count });
    TRACE("ATEN-QUEUESTREAM-READ-DUMP UID={} DATA={}", //
        .{ self.uid, r3.str(buffer[0..count]) });
    return count;
}

fn flushQueue(self: *QueueStream) void {
    while (self.queue.popFirst()) |first_node| {
        const substream = first_node.data;
        substream.close();
        self.aten.dealloc(first_node);
    }
}

/// Close a queue stream and all enqueued underlying byte streams.
pub fn close(self: *QueueStream) void {
    std.debug.assert(self.consumption_state == .open);
    TRACE("ATEN-QUEUESTREAM-CLOSE UID={} P-STATE={}", //
        .{ self.uid, self.production_state });
    self.flushQueue();
    self.consumption_state.open.notifier.destroy();
    self.consumption_state = .closed;
    if (self.production_state == .terminated) {
        self.aten.wound(self);
    }
}

/// Subscribe to readability notifications.
pub fn subscribe(self: *QueueStream, action: Action) void {
    TRACE("ATEN-QUEUESTREAM-SUBSCRIBE UID={} ACT={}", .{ self.uid, action });
    self.callback = action;
}

/// Create a queue stream with an empty queue of underlying byte
/// streams. Byte streams can be appended to the queue with `enqueue`
/// and prepended with `push`.
pub fn make(aten: *Aten) *QueueStream {
    const self = aten.alloc(QueueStream);
    const notifier = Event.make(aten, ByteStream.makeCallbackProbe(self));
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

/// Append a byte stream to the queue of a queue stream. If the user
/// is due it, a notification is issued.
pub fn enqueue(self: *QueueStream, substream: ByteStream) void {
    std.debug.assert(self.production_state == .open);
    const node = self.aten.alloc(Queue.Node);
    node.data = substream;
    self.queue.append(node);
    TRACE("ATEN-QUEUESTREAM-ENQUEUE UID={} SUB={}", .{ self.uid, substream });
    if (self.consumption_state == .open) {
        if (self.queue.first.? == node) {
            self.consumption_state.open.notifier.trigger();
            self.consumption_state.open.head_subscribed = false;
        }
    }
}

/// Prepend a byte stream to the queue of a queue stream. If the user
/// is due it, a readability notification is issued.
pub fn push(self: *QueueStream, substream: ByteStream) void {
    std.debug.assert(self.production_state == .open);
    const node = self.aten.alloc(Queue.Node);
    node.data = substream;
    self.queue.preend(node);
    TRACE("ATEN-QUEUESTREAM-PUSH UID={} SUB={}", .{ self.uid, substream });
    if (self.consumption_state == .open) {
        self.consumption_state.open.notifier.trigger();
        self.consumption_state.open.head_subscribed = false;
    }
}

/// A convenience function to enqueue a blob of bytes. The blob is
/// copied.
pub fn enqueueBlob(self: *QueueStream, blob: []const u8) void {
    TRACE("ATEN-QUEUESTREAM-ENQUEUE-BLOB UID={} BLOB={}", //
        .{ self.uid, r3.str(blob) });
    self.enqueue(ByteStream.from(BlobStream.copy(self.aten, blob)));
}

/// A convenience function to push a blob of bytes. The blob is
/// copied.
pub fn pushBlob(self: *QueueStream, blob: []const u8) void {
    TRACE("ATEN-QUEUESTREAM-ENQUEUE-BLOB UID={} BLOB={}", //
        .{ self.uid, r3.str(blob) });
    self.push(ByteStream.from(BlobStream.copy(self.aten, blob)));
}

fn wrapUp(self: *QueueStream) void {
    std.debug.assert(self.production_state == .terminating);
    std.debug.assert(self.consumption_state == .closed);
    self.flushQueue();
    self.aten.wound(self);
}

/// Inform a queue stream that no more data will be enqueued or
/// pushed. If the user is due it, a readability notification is
/// issued.
pub fn terminate(self: *QueueStream) void {
    std.debug.assert(self.production_state == .open);
    TRACE("ATEN-QUEUESTREAM-TERMINATE UID={}", .{self.uid});
    switch (self.consumption_state) {
        .open => {
            self.production_state = .terminated;
            self.consumption_state.open.notifier.trigger();
        },
        .closed => {
            self.production_state = .terminating;
            _ = self.aten.execute(Action.make(self, wrapUp));
        },
    }
}
