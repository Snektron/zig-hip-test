const std = @import("std");
const assert = std.debug.assert;

const offload_bundle = @import("zig-hip-offload-bundle").bundle;
const c = @cImport({
    @cDefine("__HIP_PLATFORM_AMD__", "1");
    @cInclude("hip/hip_runtime.h");
});

const hip = struct {
    fn unexpected(err: c_uint) noreturn {
        std.log.err("unexpected hip result: {s}", .{c.hipGetErrorName(err)});
        unreachable;
    }

    fn malloc(comptime T: type, n: usize) ![]T {
        var result: [*]T = undefined;
        return switch (c.hipMalloc(
            @ptrCast(*?*anyopaque, &result),
            n * @sizeOf(T),
        )) {
            c.hipSuccess => result[0..n],
            c.hipErrorMemoryAllocation => error.OutOfMemory,
            else => |err| unexpected(err),
        };
    }

    fn free(ptr: anytype) void {
        const actual_ptr = switch (@typeInfo(@TypeOf(ptr)).Pointer.size) {
            .Slice => ptr.ptr,
            else => ptr,
        };

        assert(c.hipFree(actual_ptr) == c.hipSuccess);
    }

    const CopyDir = enum {
        host_to_device,
        device_to_host,
        host_to_host,
        device_to_device,

        fn toC(self: CopyDir) c_uint {
            return switch (self) {
                .host_to_device => c.hipMemcpyHostToDevice,
                .device_to_host => c.hipMemcpyDeviceToHost,
                .host_to_host => c.hipMemcpyHostToHost,
                .device_to_device => c.hipMemcpyDeviceToDevice,
            };
        }
    };

    fn memcpy(comptime T: type, dst: []T, src: []const T, direction: CopyDir) void {
        assert(dst.len >= src.len);
        switch (c.hipMemcpy(
            dst.ptr,
            src.ptr,
            @sizeOf(T) * src.len,
            direction.toC(),
        )) {
            c.hipSuccess => {},
            else => |err| unexpected(err),
        }
    }

    const Module = c.hipModule_t;

    fn moduleLoadData(image: *const anyopaque) !Module {
        var module: Module = undefined;
        return switch (c.hipModuleLoadData(&module, image)) {
            c.hipSuccess => module,
            c.hipErrorOutOfMemory => error.OutOfMemory,
            c.hipErrorSharedObjectInitFailed => error.SharedObjectInitFailed,
            else => |err| unexpected(err),
        };
    }

    fn moduleUnload(module: Module) void {
        assert(c.hipModuleUnload(module) == c.hipSuccess);
    }

    const Function = c.hipFunction_t;

    fn moduleGetFunction(module: Module, name: [*:0]const u8) !Function {
        var function: Function = undefined;
        return switch (c.hipModuleGetFunction(&function, module, name)) {
            c.hipSuccess => function,
            c.hipErrorNotFound => error.NotFound,
            else => |err| unexpected(err),
        };
    }
};

pub fn main() !void {
    const block_size = 16;

    std.log.info("setting up buffers", .{});
    const d_in = try hip.malloc(f32, block_size);
    defer hip.free(d_in);

    const d_out = try hip.malloc(f32, block_size);
    defer hip.free(d_out);

    hip.memcpy(f32, d_in, &(.{2} ** block_size), .host_to_device);

    std.log.info("loading module", .{});
    const module = try hip.moduleLoadData(offload_bundle);
    defer hip.moduleUnload(module);

    const kernel = try hip.moduleGetFunction(module, "kernel");

    std.log.info("launching kernel", .{});
    var args = [_]u64{ @ptrToInt(d_out.ptr), @ptrToInt(d_in.ptr) };
    var args_len = args.len;
    var config = [_]?*anyopaque{
        c.HIP_LAUNCH_PARAM_BUFFER_POINTER,
        &args,
        c.HIP_LAUNCH_PARAM_BUFFER_SIZE,
        &args_len,
        c.HIP_LAUNCH_PARAM_END
    };

    switch (c.hipModuleLaunchKernel(
        kernel,
        // grid size
        1,
        1,
        1,
        // block size
        block_size,
        1,
        1,
        0, // shared memory
        null, // stream
        null, // params (unsupported)
        &config,
    )) {
        c.hipSuccess => {},
        else => |err| hip.unexpected(err),
    }

    std.log.info("collecting results", .{});

    var result: [block_size]f32 = undefined;
    hip.memcpy(f32, &result, d_out, .device_to_host);

    std.log.info("result: {d}", .{result});
}
