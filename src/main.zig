const std = @import("std");
const builtin = @import("builtin");
const wayland = @import("wayland.zig");

pub const std_options: std.Options = .{
    .log_level = if(builtin.mode == std.builtin.OptimizeMode.Debug) .info else .info,
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const wayland_context = try wayland.setup(allocator);
    defer wayland.cleanup(allocator, wayland_context);

    while (wayland.displayDispatch(wayland_context.display)) { }
}
