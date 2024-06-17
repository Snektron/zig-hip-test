const std = @import("std");
const assert = std.debug.assert;

pub const std_options = .{
    .log_level = .info,
};

const hip = @import("hip.zig");

const zig_offload_bundle = @embedFile("hip-offload-bundle");
const hip_offload_bundle = @embedFile("hip-offload-bundle");

const reduce = @import("device_reduce.zig");

fn test_reduce(name: []const u8, values: []const f32, module_data: *const anyopaque, warmup: bool) !void {
    std.log.debug("{s}: reducing {} values", .{ name, values.len });
    var d_values_a = try hip.malloc(f32, values.len);
    defer hip.free(d_values_a);
    var d_values_b = try hip.malloc(f32, values.len);
    defer hip.free(d_values_b);
    hip.memcpy(f32, d_values_a, values, .host_to_device);

    std.log.debug("  loading module", .{});
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
        if (!warmup) {
            std.log.debug("  launching {} block(s)", .{blocks});
        }

        kernel.launch(
            .{
                .grid_dim = .{ .x = @intCast(blocks) },
                .block_dim = .{ .x = reduce.block_dim },
                .shared_mem_per_block = @sizeOf(f32) * reduce.block_dim,
            },
            .{ d_values_a.ptr, d_values_b.ptr, @as(u32, @intCast(blocks - 1)), @as(u32, @intCast(valid_in_last_block)) },
        );

        std.mem.swap([]f32, &d_values_a, &d_values_b);

        remaining_size = blocks;
    }

    stop.record(null);
    stop.synchronize();

    const elapsed = hip.Event.elapsed(start, stop);

    if (warmup) {
        return;
    }

    std.log.debug("  fetching result", .{});
    var result: [1]f32 = undefined;
    hip.memcpy(f32, &result, d_values_a[0..1], .device_to_host);

    std.log.info("{s}: result = {d}, processed {} items in {d:.2} ms ({d:.2} GItem/s, {d:.2} GB/s)", .{
        name,
        result[0],
        values.len,
        elapsed,
        @as(f32, @floatFromInt(values.len)) / elapsed / 1000_000,
        @sizeOf(f32) * @as(f32, @floatFromInt(values.len)) / elapsed / 1000_000,
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const size = 128 * 1024 * 1024;

    std.log.info("generating inputs", .{});
    const values = try allocator.alloc(f32, size);
    defer allocator.free(values);
    for (values, 0..) |*x, i| x.* = @floatFromInt(i);

    try test_reduce("zig", values, zig_offload_bundle, true);
    try test_reduce("hip", values, hip_offload_bundle, true);
    try test_reduce("zig", values, zig_offload_bundle, false);
    try test_reduce("hip", values, hip_offload_bundle, false);
}
