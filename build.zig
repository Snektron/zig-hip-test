const std = @import("std");
const Step = std.Build.Step;
const CompileStep = std.build.CompileStep;
const LazyPath = std.Build.LazyPath;

pub fn build(b: *std.Build) void {
    const host_target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const device_target = b.resolveTargetQuery(.{
        .cpu_arch = .amdgcn,
        .os_tag = .amdhsa,
        .abi = .none,
        .cpu_model = .{ .explicit = &std.Target.amdgpu.cpu.gfx1101 },
    });

    // Build Zig device code
    const device_code = b.addSharedLibrary(.{
        .name = "device-code-gfx1101",
        .root_source_file = b.path("src/kernel.zig"),
        .target = device_target,
        .optimize = optimize,
    });
    device_code.linker_allow_shlib_undefined = false;
    device_code.bundle_compiler_rt = false;
    // device_code.force_pic = true;

    const zig_bundle_cmd = b.addSystemCommand(&.{
        "clang-offload-bundler",
        "-type=o",
        "-bundle-align=4096",
        "-targets=host-x86_64-unknown-linux,hipv4-amdgcn-amd-amdhsa--gfx1101",
        "-input=/dev/null",
    });
    zig_bundle_cmd.addPrefixedFileArg("-input=", device_code.getEmittedBin());
    const zig_bundle = zig_bundle_cmd.addPrefixedOutputFileArg("-output=", "module.co");

    // Build HIP device code
    const hip_cmd = b.addSystemCommand(&.{ "hipcc", "--genco", "--offload-arch=gfx1101", "-o" });
    const hip_bundle = hip_cmd.addOutputFileArg("module.co");
    hip_cmd.addFileArg(b.path("src/device_reduce.hip"));

    // Build final executable
    const exe = b.addExecutable(.{
        .name = "zig-hip-test",
        .root_source_file = b.path("src/main.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    b.installArtifact(exe);
    exe.linkLibC();
    exe.addIncludePath(.{ .cwd_relative = "/opt/rocm/include" });
    exe.addLibraryPath(.{ .cwd_relative = "/opt/rocm/lib" });
    exe.linkSystemLibrary("amdhip64");
    exe.root_module.addAnonymousImport("zig-offload-bundle", .{
        .root_source_file = zig_bundle,
    });
    exe.root_module.addAnonymousImport("hip-offload-bundle", .{
        .root_source_file = hip_bundle,
    });

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
