const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const quickjs_dep = b.dependency("quickjs", .{
        .target = target,
        .optimize = optimize,
    });

    const c_mod = CModule.build(b, .{
        .quickjs = quickjs_dep,
        .target = target,
        .optimize = optimize,
    });

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    lib_mod.addImport("c", c_mod);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_mod.addImport("compotent_lib", lib_mod);
    exe_mod.addImport("c", c_mod);

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "compotent",
        .root_module = lib_mod,
    });

    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "compotent",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}

const CModule = struct {
    const header_bytes = (
        \\#include <quickjs.h>
        \\#include <quickjs-libc.h>
    );

    pub const Options = struct {
        quickjs: *std.Build.Dependency,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    };

    pub fn build(b: *std.Build, opts: Options) *std.Build.Module {
        const c = translateC(b, opts);
        const mod = createModule(c, opts);
        return mod;
    }

    fn translateC(b: *std.Build, opts: Options) *std.Build.Step.TranslateC {
        const header_file = b.addWriteFiles().add("c.h", header_bytes);

        const c = b.addTranslateC(.{
            .root_source_file = header_file,
            .target = opts.target,
            .optimize = opts.optimize,
            .link_libc = true,
        });
        c.addIncludePath(opts.quickjs.artifact("quickjs").getEmittedIncludeTree());

        return c;
    }

    fn createModule(c: *std.Build.Step.TranslateC, opts: Options) *std.Build.Module {
        const mod = c.createModule();
        mod.linkLibrary(opts.quickjs.artifact("quickjs"));
        return mod;
    }
};
