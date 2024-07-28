pub const Aten = @import("Aten.zig");

const r3 = @import("r3");
const TRACE = r3.trace;
const test_options = @import("test_options");

test "Aten-initialize-tests" {
    @import("std").testing.refAllDecls(@This());
    try r3.select(test_options.trace_include, test_options.trace_exclude);
    TRACE("ATEN-TEST-INITIALIZE", .{});
}
