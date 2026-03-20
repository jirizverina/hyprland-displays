pub const Context = struct {
    buffer: []u8,
    win_height: u32,
    win_width: u32,
};

pub const Rectangle = struct {
    width: u32,
    height: u32,
    position: Position,

    const Self = @This();

    pub fn contains(self: *const Self, position: Position) bool {
        return (position.x >= self.position.x and position.x < self.position.x + self.width)
            and (position.y >= self.position.y and position.y < self.position.y + self.height);
    }
};

pub const Color = packed struct {
    b: u8,
    g: u8,
    r: u8,
    a: u8 = 0xFF,
};

pub const Position = struct {
    //TODO change to signed
    x: u32,
    y: u32,
};

pub fn drawRectangle(ctx: *const Context, rect: *const Rectangle, color: Color) void {
    const pixels: []u32 = @ptrCast(@alignCast(ctx.buffer));

    const start_x = @min(rect.position.x, ctx.win_width);
    const end_x = @min(start_x + rect.width, ctx.win_width);
    const start_y = @min(rect.position.y, ctx.win_height);
    const end_y = @min(start_y + rect.height, ctx.win_height);

    for (start_y..end_y) |y| {
        for (start_x..end_x) |x| {
            pixels[x + y * ctx.win_width] = @as(u32, @bitCast(color));
        }
    }
}

fn clamp(T: type, value: T, min: T, max: T) T {
    return @max(min, @min(value, max));
}
