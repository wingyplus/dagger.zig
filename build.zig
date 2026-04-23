const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const dagger_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "dagger",
        .root_module = dagger_module,
    });

    b.installArtifact(lib);

    const codegen_exe = b.addExecutable(.{
        .name = "codegen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/codegen/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(codegen_exe);

    const run_codegen_cmd = b.addRunArtifact(codegen_exe);
    if (b.args) |args| {
        run_codegen_cmd.addArgs(args);
    }
    const codegen_step = b.step("codegen", "Generate Zig SDK from introspection JSON");
    codegen_step.dependOn(&run_codegen_cmd.step);

    const lib_tests = b.addTest(.{
        .root_module = dagger_module,
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build test`
    // This will evaluate the `test` step rather than the default, which is "install".
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_tests.step);

    const integration_tests_module = b.createModule(.{
        .root_source_file = b.path("src/sdk_integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_tests_module.addImport("dagger", dagger_module);

    const integration_tests = b.addTest(.{
        .root_module = integration_tests_module,
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_test_step = b.step("test-integration", "Run SDK integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);
}
