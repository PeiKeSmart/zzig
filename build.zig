const std = @import("std");

const builtin = @import("builtin");

const min_zig_string = "0.15.2";

const current_zig = builtin.zig_version;

comptime {
    const min_zig = std.SemanticVersion.parse(min_zig_string) catch unreachable;
    if (current_zig.order(min_zig) == .lt) {
        const err_msg = std.fmt.comptimePrint(
            "Your Zig version v{} does not meet the minimum build requirement of v{}",
            .{ current_zig, min_zig },
        );
        @compileError(err_msg);
    }
}

pub fn build(b: *std.Build) void {
    switch (current_zig.minor) {
        15 => version_15.build(b),
        else => @compileError("unknown version!"),
    }
}

const version_15 = struct {
    const Build = std.Build;
    const Module = Build.Module;
    const OptimizeMode = std.builtin.OptimizeMode;

    pub fn build(b: *std.Build) void {
        const target = b.standardTargetOptions(.{});
        const optimize = b.standardOptimizeOption(.{});

        const zzig = b.addModule("zzig", .{
            .root_source_file = b.path(b.pathJoin(&.{ "src", "zzig.zig" })),
        });

        generateDocs(b, optimize, target);

        // 异步日志器演示程序
        const async_demo_module = b.createModule(.{
            .root_source_file = b.path(b.pathJoin(&.{ "src", "async_logger_test.zig" })),
            .target = target,
            .optimize = optimize,
        });
        async_demo_module.addImport("zzig", zzig);

        const async_demo = b.addExecutable(.{
            .name = "async_logger_demo",
            .root_module = async_demo_module,
        });
        b.installArtifact(async_demo);

        const run_async_demo = b.addRunArtifact(async_demo);
        run_async_demo.step.dependOn(b.getInstallStep());

        const async_demo_step = b.step("async-demo", "Run async logger demo");
        async_demo_step.dependOn(&run_async_demo.step);

        // 配置文件示例程序
        const config_demo_module = b.createModule(.{
            .root_source_file = b.path(b.pathJoin(&.{ "examples", "async_logger_with_config.zig" })),
            .target = target,
            .optimize = optimize,
        });
        config_demo_module.addImport("zzig", zzig);

        const config_demo = b.addExecutable(.{
            .name = "async_logger_config_demo",
            .root_module = config_demo_module,
        });
        b.installArtifact(config_demo);

        const run_config_demo = b.addRunArtifact(config_demo);
        run_config_demo.step.dependOn(b.getInstallStep());

        const config_demo_step = b.step("config-demo", "Run async logger with config file demo");
        config_demo_step.dependOn(&run_config_demo.step);

        // 文件输出测试程序
        const file_output_demo_module = b.createModule(.{
            .root_source_file = b.path(b.pathJoin(&.{ "examples", "async_logger_file_output.zig" })),
            .target = target,
            .optimize = optimize,
        });
        file_output_demo_module.addImport("zzig", zzig);

        const file_output_demo = b.addExecutable(.{
            .name = "async_logger_file_output_demo",
            .root_module = file_output_demo_module,
        });
        b.installArtifact(file_output_demo);

        const run_file_output_demo = b.addRunArtifact(file_output_demo);
        run_file_output_demo.step.dependOn(b.getInstallStep());

        const file_output_demo_step = b.step("file-demo", "Run async logger file output demo");
        file_output_demo_step.dependOn(&run_file_output_demo.step);

        // 日志轮转压力测试程序
        const rotation_test_module = b.createModule(.{
            .root_source_file = b.path(b.pathJoin(&.{ "examples", "async_logger_rotation_test.zig" })),
            .target = target,
            .optimize = optimize,
        });
        rotation_test_module.addImport("zzig", zzig);

        const rotation_test = b.addExecutable(.{
            .name = "async_logger_rotation_test",
            .root_module = rotation_test_module,
        });
        b.installArtifact(rotation_test);

        const run_rotation_test = b.addRunArtifact(rotation_test);
        run_rotation_test.step.dependOn(b.getInstallStep());

        const rotation_test_step = b.step("rotation-test", "Run async logger rotation stress test");
        rotation_test_step.dependOn(&run_rotation_test.step);

        // both模式测试程序
        const both_test_module = b.createModule(.{
            .root_source_file = b.path(b.pathJoin(&.{ "examples", "async_logger_both_mode_test.zig" })),
            .target = target,
            .optimize = optimize,
        });
        both_test_module.addImport("zzig", zzig);

        const both_test = b.addExecutable(.{
            .name = "async_logger_both_test",
            .root_module = both_test_module,
        });
        b.installArtifact(both_test);

        const run_both_test = b.addRunArtifact(both_test);
        run_both_test.step.dependOn(b.getInstallStep());

        const both_test_step = b.step("both-test", "Run async logger both mode test");
        both_test_step.dependOn(&run_both_test.step);

        // 零分配模式演示程序（推荐 ARM 设备）
        const zero_alloc_demo_module = b.createModule(.{
            .root_source_file = b.path(b.pathJoin(&.{ "examples", "async_logger_zero_alloc_demo.zig" })),
            .target = target,
            .optimize = optimize,
        });
        zero_alloc_demo_module.addImport("zzig", zzig);

        const zero_alloc_demo = b.addExecutable(.{
            .name = "async_logger_zero_alloc_demo",
            .root_module = zero_alloc_demo_module,
        });
        b.installArtifact(zero_alloc_demo);

        const run_zero_alloc_demo = b.addRunArtifact(zero_alloc_demo);
        run_zero_alloc_demo.step.dependOn(b.getInstallStep());

        const zero_alloc_demo_step = b.step("zero-alloc-demo", "Run async logger zero allocation demo (recommended for ARM devices)");
        zero_alloc_demo_step.dependOn(&run_zero_alloc_demo.step);

        // 控制台工具演示程序（UTF-8 + ANSI 颜色）
        const console_demo_module = b.createModule(.{
            .root_source_file = b.path(b.pathJoin(&.{ "examples", "console_example.zig" })),
            .target = target,
            .optimize = optimize,
        });
        console_demo_module.addImport("zzig", zzig);

        const console_demo = b.addExecutable(.{
            .name = "console_example",
            .root_module = console_demo_module,
        });
        b.installArtifact(console_demo);

        const run_console_demo = b.addRunArtifact(console_demo);
        run_console_demo.step.dependOn(b.getInstallStep());

        const console_demo_step = b.step("console-demo", "Run console utility demo (UTF-8 + ANSI colors)");
        console_demo_step.dependOn(&run_console_demo.step);

        const test_step = b.step("test", "Run unit tests");

        // 创建测试模块
        const test_module = b.createModule(.{
            .root_source_file = b.path(b.pathJoin(&.{ "src", "test.zig" })),
            .target = target,
            .optimize = optimize,
        });
        test_module.addImport("zzig", zzig);

        const zzig_unit_tests = b.addTest(.{
            .name = "zzig-tests",
            .root_module = test_module,
        });

        const run_zzig_tests = b.addRunArtifact(zzig_unit_tests);
        test_step.dependOn(&run_zzig_tests.step);
    }
    fn generateDocs(b: *Build, optimize: OptimizeMode, target: Build.ResolvedTarget) void {
        const sources = [_]struct { name: []const u8, path: []const []const u8 }{
            .{ .name = "zig-zzig", .path = &.{ "src", "zzig.zig" } },
            .{ .name = "zig-strings", .path = &.{ "src", "string", "strings.zig" } },
            .{ .name = "zig-logger", .path = &.{ "src", "logs", "logger.zig" } },
            .{ .name = "zig-random", .path = &.{ "src", "random", "randoms.zig" } },
            .{ .name = "zig-file", .path = &.{ "src", "file", "file.zig" } },
        };

        var lib: *Build.Step.Compile = undefined;
        for (sources, 0..) |source, i| {
            const module = b.createModule(.{
                .root_source_file = b.path(b.pathJoin(source.path)),
                .target = target,
                .optimize = optimize,
            });

            lib = b.addObject(.{
                .name = source.name,
                .root_module = module,
            });
            if (i == sources.len - 1) break;
        }

        const docs_step = b.step("docs", "Emit docs");

        const docs_install = b.addInstallDirectory(.{
            .source_dir = lib.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "docs",
        });

        docs_step.dependOn(&docs_install.step);
    }
};

// // Although this function looks imperative, note that its job is to
// // declaratively construct a build graph that will be executed by an external
// // runner.
// pub fn build(b: *std.Build) void {
//     // Standard target options allows the person running `zig build` to choose
//     // what target to build for. Here we do not override the defaults, which
//     // means any target is allowed, and the default is native. Other options
//     // for restricting supported target set are available.
//     const target = b.standardTargetOptions(.{});

//     // Standard optimization options allow the person running `zig build` to select
//     // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
//     // set a preferred release mode, allowing the user to decide how to optimize.
//     const optimize = b.standardOptimizeOption(.{});

//     const lib = b.addStaticLibrary(.{
//         .name = "ZZig",
//         // In this case the main source file is merely a path, however, in more
//         // complicated build scripts, this could be a generated file.
//         .root_source_file = b.path("src/root.zig"),
//         .target = target,
//         .optimize = optimize,
//     });

//     // This declares intent for the library to be installed into the standard
//     // location when the user invokes the "install" step (the default step when
//     // running `zig build`).
//     b.installArtifact(lib);

//     const exe = b.addExecutable(.{
//         .name = "ZZig",
//         .root_source_file = b.path("src/main.zig"),
//         .target = target,
//         .optimize = optimize,
//     });

//     // This declares intent for the executable to be installed into the
//     // standard location when the user invokes the "install" step (the default
//     // step when running `zig build`).
//     b.installArtifact(exe);

//     // This *creates* a Run step in the build graph, to be executed when another
//     // step is evaluated that depends on it. The next line below will establish
//     // such a dependency.
//     const run_cmd = b.addRunArtifact(exe);

//     // By making the run step depend on the install step, it will be run from the
//     // installation directory rather than directly from within the cache directory.
//     // This is not necessary, however, if the application depends on other installed
//     // files, this ensures they will be present and in the expected location.
//     run_cmd.step.dependOn(b.getInstallStep());

//     // This allows the user to pass arguments to the application in the build
//     // command itself, like this: `zig build run -- arg1 arg2 etc`
//     if (b.args) |args| {
//         run_cmd.addArgs(args);
//     }

//     // This creates a build step. It will be visible in the `zig build --help` menu,
//     // and can be selected like this: `zig build run`
//     // This will evaluate the `run` step rather than the default, which is "install".
//     const run_step = b.step("run", "Run the app");
//     run_step.dependOn(&run_cmd.step);

//     // Creates a step for unit testing. This only builds the test executable
//     // but does not run it.
//     const lib_unit_tests = b.addTest(.{
//         .root_source_file = b.path("src/root.zig"),
//         .target = target,
//         .optimize = optimize,
//     });

//     const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

//     const exe_unit_tests = b.addTest(.{
//         .root_source_file = b.path("src/main.zig"),
//         .target = target,
//         .optimize = optimize,
//     });

//     const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

//     // Similar to creating the run step earlier, this exposes a `test` step to
//     // the `zig build --help` menu, providing a way for the user to request
//     // running the unit tests.
//     const test_step = b.step("test", "Run unit tests");
//     test_step.dependOn(&run_lib_unit_tests.step);
//     test_step.dependOn(&run_exe_unit_tests.step);
// }
