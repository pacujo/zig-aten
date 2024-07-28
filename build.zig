const std = @import("std");

pub fn build(b: *std.Build) void {
    var aten_build: AtenBuild = undefined;
    aten_build.build(b);
}

// To build, run: zig build
// To run, run: zig build run
// To test, run: zig build test
//
// To enable test trace logging, run:
//   zig build -Dtrace-include=REGEX [ -Dtrace-exclude=REGEX ] test
//
// To filter unit test cases by name, run:
//   zig build -Dtest-filter=SUBSTR [ -Dtest-filter=SUBSTR ] ... test
const AtenBuild = struct {
    b: *std.Build,
    root_source_file: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dep_r3: *std.Build.Dependency,
    tests: *std.Build.Step.Compile,

    fn build(self: *AtenBuild, builder: *std.Build) void {
        self.init(builder);
        self.declareDependencies();
        self.declareModule();
        self.declareTests();
        self.installDocs();
    }

    fn init(self: *AtenBuild, builder: *std.Build) void {
        self.b = builder;
        self.root_source_file = "src/Aten.zig";
        self.target = self.b.standardTargetOptions(.{});
        self.optimize = self.b.standardOptimizeOption(.{});
    }

    fn declareDependencies(self: *AtenBuild) void {
        self.dep_r3 = self.b.dependency("r3", .{
            .target = self.target,
            .optimize = self.optimize,
        });
    }

    fn declareModule(self: *AtenBuild) void {
        const module = self.b.addModule("Aten", .{
            .root_source_file = self.b.path(self.root_source_file),
            .target = self.target,
            .optimize = self.optimize,
        });
        module.addImport("r3", self.dep_r3.module("r3"));
    }

    fn declareTests(self: *AtenBuild) void {
        var test_filter_work_area: [100][]const u8 = undefined;
        self.tests = self.b.addTest(.{
            .root_source_file = self.b.path(self.root_source_file),
            .target = self.target,
            .optimize = self.optimize,
            .filters = self.getTestFilters(&test_filter_work_area),
        });
        self.addTestOptions();
        self.tests.root_module.addImport("r3", self.dep_r3.module("r3"));
        self.tests.linkLibC();
        const test_step = self.b.step("test", "Run unit tests");
        const run_unit_tests = self.b.addRunArtifact(self.tests);
        test_step.dependOn(&run_unit_tests.step);
        run_unit_tests.has_side_effects = true;
    }

    fn addTestOptions(self: *AtenBuild) void {
        const test_options = self.b.addOptions();
        const trace_include = self.b.option(
            []const u8,
            "trace-include",
            "Enable trace log events using a regular expression",
        );
        test_options.addOption(?[]const u8, "trace_include", trace_include);
        const trace_exclude = self.b.option(
            []const u8,
            "trace-exclude",
            "Disable trace log events using a regular expression",
        );
        test_options.addOption(?[]const u8, "trace_exclude", trace_exclude);
        self.tests.root_module.addOptions("test_options", test_options);
    }

    // Collect any number of "-Dtest-filter=XXX" options from the "zig
    // build test" command line. "XXX" is matched as a substring of the
    // test name. Test names begin with "test.". If no test-filter option
    // is given, all tests are run.
    fn getTestFilters(self: *AtenBuild, work_area: [][]const u8) [][]const u8 {
        const test_filters = self.b.option(
            []const []const u8,
            "test-filter",
            "Skip tests that do not match any filter",
        );
        if (test_filters) |filters| {
            // Tests are run in a single global state. No tests would be
            // run if the "Aten-initialize-tests" was not executed. Thus,
            // the slice is copied and the initialization test is added to
            // it.
            work_area[filters.len] = "test.Aten-initialize-tests";
            std.mem.copyForwards([]const u8, work_area[0..filters.len], filters);
            return work_area[0 .. filters.len + 1];
        }
        return work_area[0..0];
    }

    fn installDocs(self: *AtenBuild) void {
        const install_docs = self.b.addInstallDirectory(.{
            .source_dir = self.tests.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "doc",
        });
        const docs_step = self.b.step("docs", "Build and install documentation");
        docs_step.dependOn(&install_docs.step);
    }
};
