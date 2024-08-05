//! The abstract byte stream interface. A unidirectional byte stream
//! can be read from. It must be closed by the user before the `Aten`
//! object is destroyed.

const std = @import("std");
const r3 = @import("r3");
const Aten = @import("Aten.zig");
const Action = Aten.Action;

object: *anyopaque,
vt: *const Vt,

const ByteStream = @This();

/// The virtual table of the byte stream interface.
pub const Vt = struct {
    read: *const fn (*anyopaque, []u8) anyerror!usize,
    close: *const fn (*anyopaque) void,
    subscribe: *const fn (*anyopaque, Action) void,
};

/// Convert any byte stream to a `ByteStream` interface object.
pub fn from(stream: anytype) ByteStream {
    return @import("Interface.zig").cast(ByteStream, stream);
}

/// Transfer bytes from the stream in a non-blocking fashion. If no
/// bytes are available, return `error.EAGAIN`. Other errors are
/// possible. If the stream is exhausted, return `0`. Otherwise, bytes
/// are transferred to `buffer` and the number of bytes transferred is
/// returned. The returned number of bytes is more than `0` unless
/// `buffer.len` is `0`.
pub fn read(self: ByteStream, buffer: []u8) !usize {
    return self.vt.read(self.object, buffer);
}

/// Dismantle the byte stream and release resources associated with
/// it. No access to the byte stream is allowed after it has been
/// closed. Typically, the `close` method of a byte stream object
/// would explicitly make a note for itself that it has been closed,
/// release all resources and finally call `Aten.wound`. An immediate
/// deallocation of the byte stream would be hazardous as the system
/// may have active references to byte stream in its internal queues.
pub fn close(self: ByteStream) void {
    self.vt.close(self.object);
}

/// Subscribe to edge-triggered notifications canceling the previous
/// subscription. The given action is called from `Aten.loop`,
/// `Aten.loopProtected`, `Aten.poll` or `Aten.poll2` to indicate more
/// data might be available for reading. Such notifications may be
/// spurious, though. Also, they are only guaranteed after `read` has
/// returned `error.EAGAIN`.
///
/// Initially, a byte stream has `Action.Null` as the notification
/// action. Subscribing with `Action.Null` is equivalent to canceling
/// a previous subscription.
///
/// The byte stream approach does not offer a way for the producer to
/// write bytes directly to the consumer. Instead, the producer
/// invokes a notification to the consumer, and the consumer calls
/// `read` to input the bytes.
///
/// A byte stream must be careful never to perform the notification
/// action in the middle of a `read` or `close` method or any other
/// "downstream" method to avoid preemptive callback chains. If such
/// need should arise, the notification must be invoked indirectly via
/// `Aten.execute`. A direct `Action.perform` call is ok from another
/// "upstream" callback, though.
pub fn subscribe(self: ByteStream, action: Action) void {
    self.vt.subscribe(self.object, action);
}

/// A convenience utility. Many implementers of the `ByteStream`
/// interface store the subscribed notification action to a field
/// called `callback`. This function returns an `Action` that invokes
/// the stored notification.
pub fn makeCallbackProbe(stream: anytype) Action {
    const S = struct {
        pub fn probe(self: @TypeOf(stream)) void {
            self.callback.perform();
        }
    };
    return Action.make(stream, S.probe);
}

/// Write a representation of a byte stream to a writer object.
pub fn format(
    self: ByteStream,
    _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    try writer.print("{}:{}", .{ r3.ptr(self.object), r3.ptr(self.vt) });
}
