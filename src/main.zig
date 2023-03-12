const std = @import("std");
const assert = std.debug.assert;

const hip = @import("hip.zig");

const offload_bundle = @import("zig-hip-offload-bundle").bundle;

pub fn main() !void {
    const block_size = 16;

    std.log.info("setting up buffers", .{});
    var d_in = try hip.malloc(f32, block_size);
    defer hip.free(d_in);

    var d_out = try hip.malloc(f32, block_size);
    defer hip.free(d_out);

    hip.memcpy(f32, d_in, &(.{2} ** block_size), .host_to_device);

    std.log.info("loading module", .{});
    const module = try hip.Module.loadData(offload_bundle);
    defer module.unload();

    const kernel = try module.getFunction("kernel");

    std.log.info("launching kernel", .{});
    kernel.launch(
        .{ .block_dim = .{ .x = block_size } },
        .{ d_out.ptr, d_in.ptr },
    );

    std.log.info("collecting results", .{});

    var result: [block_size]f32 = undefined;
    hip.memcpy(f32, &result, d_out, .device_to_host);

    std.log.info("result: {d}", .{result});
}
