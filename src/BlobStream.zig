//! A blob stream offers a fixed in-memory sequence of bytes.

const std = @import("std");
const r3 = @import("r3");
const Aten = @import("Aten.zig");
const Action = Aten.Action;
const TRACE = r3.trace;

aten: *Aten,
uid: r3.UID,
state: State,
tail: []const u8,
memory: ?[]u8,

const BlobStream = @This();
const State = enum { open, closed };

/// Read from a blob stream.
pub fn read(self: *BlobStream, buffer: []u8) !usize {
    std.debug.assert(self.state != .closed);
    const count = @min(buffer.len, self.tail.len);
    @memcpy(buffer[0..count], self.tail[0..count]);
    self.tail = self.tail[count..];
    TRACE("ATEN-BLOBSTREAM-READ UID={} WANT={} GOT={}", //
        .{ self.uid, buffer.len, count });
    TRACE("ATEN-BLOBSTREAM-READ-TEXT UID={} TEXT={}", //
        .{ self.uid, r3.str(buffer[0..count]) });
    return count;
}

/// Close a blob stream.
pub fn close(self: *BlobStream) void {
    TRACE("ATEN-BLOBSTREAM-CLOSE UID={}", .{self.uid});
    std.debug.assert(self.state != .closed);
    self.state = .closed;
    if (self.memory) |memory| {
        self.aten.free(memory);
    }
    self.aten.wound(self);
}

/// Subscribe to readability notifications.
pub fn subscribe(self: *BlobStream, action: Action) void {
    TRACE("ATEN-BLOBSTREAM-SUBSCRIBE UID={} ACT={}", .{ self.uid, action });
}

fn _make(aten: *Aten, blob: []const u8, memory: ?[]u8) *BlobStream {
    const self = aten.alloc(BlobStream);
    self.* = .{
        .aten = aten,
        .uid = r3.newUID(),
        .state = .open,
        .tail = blob,
        .memory = memory,
    };
    TRACE("ATEN-BLOBSTREAM-CREATE UID={} PTR={} ATEN={} SIZE={}", //
        .{ self.uid, r3.ptr(self), aten.uid, blob.len });
    TRACE("ATEN-BLOBSTREAM-CREATE-TEXT UID={} TEXT={}", //
        .{ self.uid, r3.str(blob) });
    return self;
}

/// Create a blob stream. The caller must make sure the given blob
/// stays accessible until the stream is exhausted.
pub fn make(aten: *Aten, blob: []const u8) *BlobStream {
    return _make(aten, blob, null);
}

/// Create a blob stream. A copy is made of the given blob.
pub fn copy(aten: *Aten, blob: []const u8) *BlobStream {
    const dupe = aten.dupe(blob);
    return _make(aten, dupe, dupe);
}

/// Create a blob stream. The blob must have been allocated using
/// `Aten.dupe`. Its ownership is transferred to the blob stream.
pub fn adopt(aten: *Aten, blob: []u8) *BlobStream {
    return _make(aten, blob, blob);
}

/// Return the number of bytes that have not yet been read out of the
/// blob stream.
pub fn remaining(self: *BlobStream) usize {
    return self.tail.len;
}
