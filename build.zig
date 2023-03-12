const std = @import("std");
const Step = std.Build.Step;
const CompileStep = std.build.CompileStep;
const FileSource = std.build.FileSource;

const OffloadLibraryOptions = struct {
    name: []const u8,
    root_source_file: FileSource,
    target: std.zig.CrossTarget,
    optimize: std.builtin.Mode,
};

fn buildOffloadBinary(
    b: *std.Build,
    options: OffloadLibraryOptions,
) *CompileStep {
    const lib = b.addSharedLibrary(.{
        .name = options.name,
        .root_source_file = options.root_source_file,
        .target = options.target,
        .optimize = options.optimize,
    });
    lib.linker_allow_shlib_undefined = false;
    lib.bundle_compiler_rt = false;
    lib.force_pic = true;
    // Not all the required intrinsics are available from Zig, and the linker hack
    // does not work anymore.
    lib.addCSourceFile("src/amdgcn_intrin.c", &.{});
    return lib;
}

const OffloadBundleStep = struct {
    const alignment = 4096;
    const magic = "__CLANG_OFFLOAD_BUNDLE__";
    const host_bundle = "host-x86_64-unknown-linux";

    b: *std.Build,
    step: std.Build.Step,
    entries: std.ArrayListUnmanaged(*CompileStep),
    bundle_generated: std.Build.GeneratedFile,
    zig_generated: std.Build.GeneratedFile,

    fn create(b: *std.Build) *OffloadBundleStep {
        const self = b.allocator.create(OffloadBundleStep) catch unreachable;
        self.* = .{
            .b = b,
            .step = std.Build.Step.init(.custom, "offload-bundle", b.allocator, make),
            .entries = .{},
            .bundle_generated = .{ .step = &self.step },
            .zig_generated = .{ .step = &self.step },
        };
        return self;
    }

    fn addEntry(self: *OffloadBundleStep, entry: *std.Build.CompileStep) void {
        self.entries.append(self.b.allocator, entry) catch unreachable;
        self.step.dependOn(&entry.step);
    }

    fn getOutputBundleSource(self: *OffloadBundleStep) FileSource {
        return .{ .generated = &self.bundle_generated };
    }

    fn getOutputZigSource(self: *OffloadBundleStep) FileSource {
        return .{ .generated = &self.zig_generated };
    }

    fn writeEntryId(writer: anytype, entry: *CompileStep) !void {
        const target = entry.target_info.target;
        try writer.print("hipv4-amdgcn-amd-amdhsa--{s}", .{target.cpu.model.llvm_name.?});
        // TODO: Target features like xnack+, xnack-, etc?
    }

    fn entryIdSize(entry: *CompileStep) usize {
        var cw = std.io.countingWriter(std.io.null_writer);
        writeEntryId(cw.writer(), entry) catch unreachable;
        return cw.bytes_written;
    }

    fn make(step: *Step) !void {
        const self = @fieldParentPtr(OffloadBundleStep, "step", step);
        const cwd = std.fs.cwd();

        // Compute the base offset of the code objects.
        var code_objects_offset = magic.len + @sizeOf(u64);
        code_objects_offset += 3 * @sizeOf(u64) * (self.entries.items.len + 1) + host_bundle.len;
        for (self.entries.items) |entry| {
            code_objects_offset += entryIdSize(entry);
        }
        code_objects_offset = std.mem.alignForward(code_objects_offset, alignment);

        var out = std.ArrayList(u8).init(self.b.allocator);
        var cw = std.io.countingWriter(out.writer());
        var writer = cw.writer();
        try writer.writeAll(magic);
        try writer.writeIntLittle(u64, self.entries.items.len + 1);

        try writer.writeIntLittle(u64, code_objects_offset);
        try writer.writeIntLittle(u64, 0);
        try writer.writeIntLittle(u64, host_bundle.len);
        try writer.writeAll(host_bundle);

        for (self.entries.items) |entry| {
            const entry_path = entry.getOutputSource().getPath(self.b);
            const size = (try cwd.statFile(entry_path)).size;

            try writer.writeIntLittle(u64, code_objects_offset);
            try writer.writeIntLittle(u64, size);
            try writer.writeIntLittle(u64, entryIdSize(entry));
            try writeEntryId(writer, entry);

            code_objects_offset = std.mem.alignForward(code_objects_offset + size, alignment);
        }

        for (self.entries.items) |entry| {
            const padding = alignment - cw.bytes_written % alignment;
            try writer.writeByteNTimes(0, padding);

            const entry_path = entry.getOutputSource().getPath(self.b);
            const file = try cwd.openFile(entry_path, .{});
            defer file.close();
            var reader = file.reader();
            while (true) {
                var buf: [4096]u8 = undefined;
                const read = try reader.readAll(&buf);
                if (read == 0) break;
                try writer.writeAll(buf[0..read]);
            }
        }

        var man = self.b.cache.obtain();
        defer man.deinit();

        man.hash.add(@as(u32, 0x5ebcb1d9));
        man.hash.addBytes(out.items);

        const hit = try man.hit();
        const digest = man.final();
        const cache_dir_path = "bundle" ++ std.fs.path.sep_str ++ digest;
        self.bundle_generated.path = try self.b.cache_root.join(
            self.b.allocator,
            &.{ cache_dir_path, "offload_bundle.hipfb" },
        );

        self.zig_generated.path = try self.b.cache_root.join(
            self.b.allocator,
            &.{ cache_dir_path, "offload_bundle.zig" },
        );

        if (hit)
            return;

        var cache_dir = try self.b.cache_root.handle.makeOpenPath(cache_dir_path, .{});
        defer cache_dir.close();

        var co_file = try cache_dir.createFile("offload_bundle.hipfb", .{});
        defer co_file.close();
        try co_file.writer().writeAll(out.items);

        var zig_file = try cache_dir.createFile("offload_bundle.zig", .{});
        defer zig_file.close();
        try zig_file.writer().writeAll("pub const bundle = @embedFile(\"offload_bundle.hipfb\");");

        try man.writeManifest();
    }
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const device_target = std.zig.CrossTarget.parse(.{
        .arch_os_abi = "amdgcn-amdhsa-none",
        .cpu_features = "gfx908+sramecc",
    }) catch unreachable;

    const optimize = b.standardOptimizeOption(.{});

    const device_code = buildOffloadBinary(b, .{
        .name = "device-code-gfx908",
        .root_source_file = .{ .path = "src/kernel.zig" },
        .target = device_target,
        .optimize = optimize,
    });

    const bundle = OffloadBundleStep.create(b);
    bundle.addEntry(device_code);

    const exe = b.addExecutable(.{
        .name = "zig-hip-test",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.install();
    exe.linkLibC();
    exe.addIncludePath("/opt/rocm/include");
    exe.addLibraryPath("/opt/rocm/lib");
    exe.linkSystemLibrary("amdhip64");
    exe.addAnonymousModule("zig-hip-offload-bundle", .{
        .source_file = bundle.getOutputZigSource(),
    });

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
