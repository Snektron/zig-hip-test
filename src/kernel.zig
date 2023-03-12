const std = @import("std");

extern fn workitem_x() u32;
extern fn workitem_y() u32;
extern fn workitem_z() u32;

extern fn workgroup_x() u32;
extern fn workgroup_y() u32;
extern fn workgroup_z() u32;

pub fn panic(msg: []const u8, stack_trace: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    _ = stack_trace;
    unreachable;
}

export fn kernel(out: [*]addrspace(.global) f32, in: [*]addrspace(.global) const f32) callconv(.AmdgpuKernel) void {
    const index = workitem_x();
    out[index] = in[index] * @intToFloat(f32, index);
}
