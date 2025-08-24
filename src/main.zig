const std = @import("std");
const c = @import("c.zig").c;
const wayland = @import("wayland.zig");

var done: bool = false;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const components = try wayland.setupWayland(allocator);
    defer wayland.cleanupWayland(components);

    while (c.wl_display_dispatch(components.display) >= 0) {}
}
