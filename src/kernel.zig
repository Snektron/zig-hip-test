const std = @import("std");
const reduce = @import("device_reduce.zig").reduce;

pub fn panic(msg: []const u8, stack_trace: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    _ = stack_trace;
    unreachable;
}

export fn kernel(
    values: [*]addrspace(.global) f32,
    last_block: u32,
    valid_in_last_block: u32,
) callconv(.AmdgpuKernel) void {
    reduce(values, last_block, valid_in_last_block);
}
