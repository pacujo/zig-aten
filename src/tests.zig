pub const Aten = @import("Aten.zig");

const r3 = @import("r3");
const test_options = @import("test_options");

test "One test to bring them all" {
    @import("std").testing.refAllDecls(@This());
    try r3.select(test_options.trace_include, test_options.trace_exclude);
}
