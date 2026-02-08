pub const Element = struct {
    children: ?[]Element = null,
    parent: ?*const Element,

    width: u32,
    height: u32,
    x: u32,
    y: u32,
    color: Color,
};

pub const Color = packed struct {
    b: u8,
    g: u8,
    r: u8,
    a: u8,
};
