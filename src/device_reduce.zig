const std = @import("std");

extern fn workItemX() u32;
extern fn workGroupX() u32;
extern fn workDimX() u32;
extern fn syncThreads() void;

pub const items_per_thread = 24;
pub const block_dim = 256;
pub const items_per_block = block_dim * items_per_thread;

var shared: [block_dim]f32 addrspace(.shared) = undefined;

pub inline fn reduce(
    values: [*]addrspace(.global) f32,
    last_block: u32,
    valid_in_last_block: u32,
) void {
    const bid = workGroupX();
    const tid = workItemX();
    const block_offset = bid * items_per_block;

    var total: f32 = 0;
    if (bid == last_block) {
        inline for (0..items_per_thread) |i| {
            const index = block_dim * i + tid;
            if (index < valid_in_last_block)
                total += values[block_offset + block_dim * i + tid];
        }
    } else {
        inline for (0..items_per_thread) |i| {
            total += values[block_offset + block_dim * i + tid];
        }
    }

    shared[tid] = total;

    syncThreads();

    comptime var i: usize = 1;
    inline while (i < block_dim) : (i *= 2) {
        if (tid % (i * 2) == 0) {
            shared[tid] += shared[tid + i];
        }
        syncThreads();
    }

    if (tid == 0) {
        values[bid] = shared[0];
    }
}
