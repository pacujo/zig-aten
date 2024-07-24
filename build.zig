const std = @import("std");

pub fn build(b: *std.Build) void {
    const root_source_file = b.path("src/Aten.zig");
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

    const autodoc = b.addObject(.{
        .name = "Aten",
        .root_source_file = root_source_file,
        .target = target,
        .optimize = .Debug,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = autodoc.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "doc",
    });
    const docs_step = b.step("docs", "Build and install documentation");
    docs_step.dependOn(&install_docs.step);
}
