const std = @import("std");
const assert = std.debug.assert;

pub const std_options = struct {
    pub const log_level = .info;
};

const hip = @import("hip.zig");

const offload_bundle = @import("zig-hip-offload-bundle").bundle;
const reduce = @import("device_reduce.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const size = reduce.items_per_block * reduce.items_per_block * reduce.items_per_block;
    std.log.info("reducing {} values", .{size});

    // Set up the input on the host.
    const values = try allocator.alloc(f32, size);
    defer allocator.free(values);
    for (values, 0..) |*x, i| x.* = @intToFloat(f32, i);

    // Set up device buffers and copy input
    std.log.info("setting up buffers", .{});

    var d_values = try hip.malloc(f32, size);
    defer hip.free(d_values);
    hip.memcpy(f32, d_values, values, .host_to_device);

    std.log.info("loading module", .{});
    const module = try hip.Module.loadData(offload_bundle);
    defer module.unload();

    const kernel = try module.getFunction("kernel");

    const start = hip.Event.create();
    defer start.destroy();

    const stop = hip.Event.create();
    defer stop.destroy();

    start.record(null);

    var remaining_size: usize = size;
    while (remaining_size != 1) {
        remaining_size = @divExact(remaining_size, reduce.items_per_block);
        std.log.info("launching kernel with {} block(s)", .{remaining_size});
        kernel.launch(
            .{
                .grid_dim = .{ .x = @intCast(u32, remaining_size) },
                .block_dim = .{ .x = reduce.block_dim },
                .shared_mem_per_block = @sizeOf(f32) * reduce.block_dim,
            },
            .{d_values.ptr},
        );
    }

    stop.record(null);
    stop.synchronize();

    const elapsed = hip.Event.elapsed(start, stop);

    std.log.info("collecting results", .{});

    var result: [1]f32 = undefined;
    hip.memcpy(f32, &result, d_values[0..1], .device_to_host);

    std.log.info("result: {d}", .{result[0]});
    std.log.info("processed {} items in {d:.2} ms ({d:.2}GB/s)", .{ size, elapsed, @sizeOf(f32) * size / elapsed / 1000_000 });
}
