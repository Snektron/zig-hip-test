const std = @import("std");

pub const items_per_thread = 24;
pub const block_dim = 256;
pub const items_per_block = block_dim * items_per_thread;

var shared: [block_dim]f32 addrspace(.shared) = undefined;

fn syncThreads() void {
    asm volatile ("s_barrier");
}

pub inline fn reduce(
    in: [*]addrspace(.global) f32,
    out: [*]addrspace(.global) f32,
    last_block: u32,
    valid_in_last_block: u32,
) void {
    const bid = @workGroupId(0);
    const tid = @workItemId(0);
    const block_offset = bid * items_per_block;

    var total: f32 = 0;
    if (bid == last_block) {
        inline for (0..items_per_thread) |i| {
            const index = block_dim * i + tid;
            if (index < valid_in_last_block)
                total += in[block_offset + block_dim * i + tid];
        }
    } else {
        inline for (0..items_per_thread) |i| {
            total += in[block_offset + block_dim * i + tid];
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
        out[bid] = shared[0];
    }
}
