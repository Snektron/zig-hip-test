const std = @import("std");
const reduce = @import("device_reduce.zig").reduce;

pub fn panic(msg: []const u8, stack_trace: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    _ = stack_trace;
    unreachable;
}

export fn kernel(
    in: [*]addrspace(.global) f32,
    out: [*]addrspace(.global) f32,
    last_block: u32,
    valid_in_last_block: u32,
) callconv(.Kernel) void {
    reduce(in, out, last_block, valid_in_last_block);
}
