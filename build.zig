const std = @import("std");

pub fn build(b: *std.Build) void {
    const root_source_file = b.path("src/Aten.zig");
    const root_test_file = b.path("src/tests.zig");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_r3 = b.dependency("r3", .{
        .target = target,
        .optimize = optimize,
    });

    const module = b.addModule("Aten", .{
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
    });
    module.addImport("r3", dep_r3.module("r3"));

    const tests = b.addTest(.{
        .root_source_file = root_test_file,
        .target = target,
        .optimize = optimize,
    });

    const test_options = b.addOptions();
    const trace_include = b.option([]const u8, "trace-include", "regex");
    test_options.addOption(?[]const u8, "trace_include", trace_include);
    const trace_exclude = b.option([]const u8, "trace-exclude", "regex");
    test_options.addOption(?[]const u8, "trace_exclude", trace_exclude);
    tests.root_module.addOptions("test_options", test_options);
    tests.root_module.addImport("r3", dep_r3.module("r3"));
    tests.linkLibC();

    const test_step = b.step("test", "Run unit tests");
    const run_unit_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_unit_tests.step);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "doc",
    });
    const docs_step = b.step("docs", "Build and install documentation");
    docs_step.dependOn(&install_docs.step);
}
