const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").c;
const wayland = @import("wayland.zig");

pub const std_options: std.Options = .{
    .log_level = if(builtin.mode == std.builtin.OptimizeMode.Debug) .debug else .info,
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const components = try wayland.setupWayland(allocator);
    defer wayland.cleanupWayland(allocator, components);

    while (wayland.displayDispatch(components.display)) { }
}
