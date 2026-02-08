const std = @import("std");
const builtin = @import("builtin");
const wayland = @import("wayland.zig");
const ui = @import("ui.zig");

pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == std.builtin.OptimizeMode.Debug) .debug else .info,
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const wayland_context = try wayland.setup(allocator);
    defer wayland.cleanup(allocator, wayland_context);

    var rec_children: [2]ui.Element = undefined;
    const rect = ui.Element{
        .children = &rec_children,
        .parent = null,
        .x = 100,
        .y = 200,
        .width = 500,
        .height = 500,
        .color = .{
            .a = 255,
            .r = 0,
            .g = 255,
            .b = 0,
        },
    };

    rec_children[0] = ui.Element{
        .parent = &rect,
        .x = 0,
        .y = 0,
        .width = 100,
        .height = 50,
        .color = .{
            .a = 255,
            .r = 255,
            .g = 0,
            .b = 127,
        },
    };

    rec_children[1] = ui.Element{
        .parent = &rect,
        .x = 100,
        .y = 0,
        .width = 500,
        .height = 200,
        .color = .{
            .a = 255,
            .r = 0,
            .g = 255,
            .b = 255,
        },
    };

    while (wayland.displayDispatch(wayland_context.display)) {
        const buffer_context = wayland_context.buffer_context.?;
        clear(buffer_context.data);
        drawElement(&buffer_context, &rect);
    }
}

fn drawElement(buffer_context: *const wayland.BufferContext, element: *const ui.Element) void {
    const color: u32 = @bitCast(element.*.color);

    var x = element.x;
    var y = element.y;
    //TODO has to be recursive
    if(element.parent) |parent| {
        x += parent.x;
        y += parent.y;
    }

    drawRect(buffer_context.data, buffer_context.window_width, buffer_context.window_height, x, y, element.width, element.height, color);

    if (element.children) |children| {
        for (children) |*child| {
            drawElement(buffer_context, child);
        }
    }
}

fn drawRect(buffer: []u8, win_width: u32, win_height: u32, pos_x: u32, pos_y: u32, width: u32, height: u32, color: u32) void {
    const pixels: []u32 = @ptrCast(@alignCast(buffer));

    const start_y = clamp(u32, pos_y, 0, win_height);
    const end_y = clamp(u32, start_y + height, start_y, win_height);
    const start_x = clamp(u32, pos_x, 0, win_width);
    const end_x = clamp(u32, start_x + width, start_y, win_width);

    for (start_y..end_y) |y| {
        for (start_x..end_x) |x| {
            pixels[x + y * win_width] = color;
        }
    }
}

fn clear(buffer: []u8) void {
    for (buffer) |*val| {
        val.* = 0;
    }
}

fn clamp(T: type, value: T, min: T, max: T) T {
    return @max(min, @min(value, max));
}
