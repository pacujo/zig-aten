const std = @import("std");
const r3 = @import("r3");
const Aten = @import("Aten.zig");
const Action = Aten.Action;

object: *const anyopaque,
vt: *const Vt,

const ByteStream = @This();

pub const Vt = struct {
    read: *const fn (object: *const anyopaque, buffer: []u8) anyerror!usize,
    close: *const fn (object: *const anyopaque) void,
    subscribe: *const fn (object: *const anyopaque, action: Action) void,
};

pub fn from(stream: anytype) ByteStream {
    const Stream = @TypeOf(stream.*);
    const readFn: *const fn (*Stream, []u8) anyerror!usize = &Stream.read;
    const closeFn: *const fn (*Stream) void = &Stream.close;
    const subscribeFn: *const fn (*Stream, Action) void =
        &Stream.subscribe;
    const S = struct {
        const vt = Vt{
            .read = @ptrCast(readFn),
            .close = @ptrCast(closeFn),
            .subscribe = @ptrCast(subscribeFn),
        };
    };
    return .{ .object = @ptrCast(stream), .vt = &S.vt };
}

pub fn read(self: ByteStream, buffer: []u8) !usize {
    return try self.vt.read(self.object, buffer);
}

pub fn close(self: ByteStream) void {
    self.vt.close(self.object);
}

pub fn subscribe(self: ByteStream, action: Action) void {
    self.vt.subscribe(self.object, action);
}

pub fn makeCallbackProbe(comptime Stream: type) *const fn (*Stream) void {
    const S = struct {
        pub fn probe(self: *Stream) void {
            self.callback.perform();
        }
    };
    return &S.probe;
}

pub fn format(
    self: ByteStream,
    _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    try writer.print("{}:{}", .{ r3.ptr(self.object), r3.ptr(self.vt) });
}
