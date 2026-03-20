const std = @import("std");
const builtin = @import("builtin");
const wayland = @import("wayland.zig");
const ui = @import("ui.zig");

pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == std.builtin.OptimizeMode.Debug) .debug else .info,
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const wayland_context = try wayland.setup(allocator, drawUi);
    defer wayland.cleanup(allocator, wayland_context);

    while (wayland.displayDispatch(wayland_context.display)) {
    }
}

const AppState = struct { int: u32 = 0 };

fn drawUi(ctx: *wayland.Context) !void {
    const buffer_context = &ctx.buffer_context.?;

    const offset = buffer_context.buffer_size * buffer_context.index;
    const ui_ctx: ui.Context = .{
        .buffer = buffer_context.file_data[offset..(buffer_context.buffer_size + offset)],
        .win_height = buffer_context.heigth,
        .win_width = buffer_context.width,
    };

    @memset(ui_ctx.buffer, 0);

    //TODO 256 should be calculated in wayland
    const pointer_pos: ui.Position = .{
        .x = @intCast(@max(0, @divTrunc(ctx.pointer_position_x, 256))),
        .y = @intCast(@max(0, @divTrunc(ctx.pointer_position_y, 256))),
    };

    const rect: *const ui.Rectangle = &.{
        .position = .{ .x = 0, .y = 0 },
        .height = 200,
        .width = 400,
    };

    if (rect.contains(pointer_pos)) {
        ui.drawRectangle(&ui_ctx, rect, .{ .r = 0x00, .g = 0xFF, .b = 0xFF });
    } else {
        ui.drawRectangle(&ui_ctx, rect, .{ .r = 0xFF, .g = 0x00, .b = 0xFF });
    }

    const rect2: *const ui.Rectangle = &.{
        .position = .{ .x = 500, .y = 500 },
        .height = 50,
        .width = 10,
    };

    ui.drawRectangle(&ui_ctx, rect2, .{ .r = 0x00, .g = 0xFF, .b = 0x00});

    try wayland.draw(ctx);
}
