const std = @import("std");
const r3 = @import("r3");
const Aten = @import("Aten.zig");

object: *const anyopaque,
vt: *const Vt,

const ByteStream = @This();

pub const Vt = struct {
    read: *const fn (
        object: *const anyopaque,
        buffer: []u8,
    ) anyerror!usize,
    close: *const fn (
        object: *const anyopaque,
    ) anyerror!void,
    subscribe: *const fn (
        object: *const anyopaque,
        action: Aten.Action,
    ) anyerror!void,
};

pub fn from(stream: anytype) ByteStream {
    const Stream = @TypeOf(stream.*);
    const vt = Vt{
        .read = @ptrCast(&Stream.read),
        .close = @ptrCast(&Stream.close),
        .subscribe = @ptrCast(&Stream.subscribe),
    };
    return .{ .object = @ptrCast(stream), .vt = &vt };
}

pub fn read(bs: ByteStream, buffer: []u8) !usize {
    return try bs.vt.read(bs.object, buffer);
}

pub fn close(bs: ByteStream) !void {
    try bs.vt.close(bs.object);
}

pub fn subscribe(bs: ByteStream, action: Aten.Action) !void {
    try bs.vt.subscribe(bs.object, action);
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
