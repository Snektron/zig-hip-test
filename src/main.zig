const std = @import("std");
const assert = std.debug.assert;

pub const std_options = struct {
    pub const log_level = .info;
};

const hip = @import("hip.zig");

const zig_offload_bundle = @import("zig-offload-bundle").bundle;
const hip_offload_bundle = @import("hip-offload-bundle").bundle;

const reduce = @import("device_reduce.zig");

fn test_reduce(name: []const u8, values: []const f32, module_data: *const anyopaque) !void {
    std.log.info("testing {s}", .{name});
    std.log.info("  reducing {} values", .{values.len});
    std.log.info("  setting up buffers", .{});

    var d_values = try hip.malloc(f32, values.len);
    defer hip.free(d_values);
    hip.memcpy(f32, d_values, values, .host_to_device);

    std.log.info("  loading module", .{});
    const module = try hip.Module.loadData(module_data);
    defer module.unload();

    const kernel = try module.getFunction("kernel");

    const start = hip.Event.create();
    defer start.destroy();

    const stop = hip.Event.create();
    defer stop.destroy();

    start.record(null);

    var remaining_size: usize = values.len;
    while (remaining_size != 1) {
        const blocks = std.math.divCeil(usize, remaining_size, reduce.items_per_block) catch unreachable;
        const valid_in_last_block = remaining_size % reduce.items_per_block;

        std.log.info("  launching kernel with {} block(s)", .{blocks});
        kernel.launch(
            .{
                .grid_dim = .{ .x = @intCast(u32, blocks) },
                .block_dim = .{ .x = reduce.block_dim },
                .shared_mem_per_block = @sizeOf(f32) * reduce.block_dim,
            },
            .{ d_values.ptr, @intCast(u32, blocks - 1), @intCast(u32, valid_in_last_block) },
        );

        remaining_size = blocks;
    }

    stop.record(null);
    stop.synchronize();

    const elapsed = hip.Event.elapsed(start, stop);

    var result: [1]f32 = undefined;
    hip.memcpy(f32, &result, d_values[0..1], .device_to_host);

    std.log.info("  result: {d}", .{result[0]});
    std.log.info("  processed {} items in {d:.2} ms ({d:.2} GItem/s, {d:.2} GB/s)", .{
        values.len,
        elapsed,
        @intToFloat(f32, values.len) / elapsed / 1000_000,
        @sizeOf(f32) * @intToFloat(f32, values.len) / elapsed / 1000_000,
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const size = 1024 * 1024 * 1024;

    std.log.info("generating inputs", .{});
    const values = try allocator.alloc(f32, size);
    defer allocator.free(values);
    for (values, 0..) |*x, i| x.* = @intToFloat(f32, i);

    try test_reduce("hip", values, hip_offload_bundle);
    try test_reduce("zig", values, zig_offload_bundle);
}
