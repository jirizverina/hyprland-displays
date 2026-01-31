//TODO error handling when creating listeners

const std = @import("std");
const PROT = std.posix.PROT;
const c = @import("c.zig").c;

const xdg_wm_base_version = 7;
const compositor_version = 6;
const shm_version = 1;
const seat_version = 9;

//TODO: remove unused fields
pub const Context = struct {
    listeners: Listeners,
    buffer_context: ?BufferContext,
    allocator: std.mem.Allocator,
    display: *c.wl_display,
    registry: *c.wl_registry,
    shm: *c.wl_shm,
    compositor: *c.wl_compositor,
    xdg_wm_base: *c.xdg_wm_base,
    surface: *c.wl_surface,
    seat: *c.wl_seat,
    pointer: *c.wl_pointer,
    keyboard: *c.wl_keyboard,
    xdg_surface: *c.xdg_surface,
    xdg_toplevel: *c.xdg_toplevel,
    win_width: u32,
    win_height: u32,
};

const Listeners = struct {
    pointer_listener: c.wl_pointer_listener,
    keyboard_listener: c.wl_keyboard_listener,
    registry_listener: c.wl_registry_listener,
    xdg_wm_base_listener: c.xdg_wm_base_listener,
    xdg_surface_listener: c.xdg_surface_listener,
    xdg_toplevel_listener: c.xdg_toplevel_listener,
};

const BufferContext = struct {
    buffer: []align(std.heap.page_size_min) u8,
    shm_pool: *c.wl_shm_pool,
    file_descriptor: std.fs.File.Handle,
    size: u32,
};

const SetupError = error{
    CouldNotConnectDisplay,
    CouldNotGetDisplayRegistry,
    CouldNotCreateSurface,
    CouldNotGetXdgSurface,
    CouldNotGetXdgTopLevel,
};

pub fn setup(allocator: std.mem.Allocator) (SetupError || std.mem.Allocator.Error)!*Context {
    var context = try allocator.create(Context);
    context.buffer_context = null;
    context.allocator = allocator;
    context.display = c.wl_display_connect(null) orelse return SetupError.CouldNotConnectDisplay;
    context.registry = c.wl_display_get_registry(context.display) orelse return SetupError.CouldNotGetDisplayRegistry;

    context.listeners = .{
        .registry_listener = c.wl_registry_listener{
            .global = registryHandler,
            .global_remove = registryRemover,
        },
        .xdg_surface_listener = c.xdg_surface_listener{
            .configure = xdgSurfaceConfigure,
        },
        .xdg_toplevel_listener = c.xdg_toplevel_listener{
            .configure = xdgTopLevelConfigure,
            .close = xdgTopLevelClose,
            .configure_bounds = xdgTopLevelConfigureBounds,
            .wm_capabilities = xdgTopLevelCapabilities,
        },
        .xdg_wm_base_listener = c.xdg_wm_base_listener{
            .ping = xdgWmBasePing,
        },
        .pointer_listener = c.wl_pointer_listener{
            .enter = pointerEnter,
            .leave = pointerLeave,
            .motion = pointerMotion,
            .button = pointerButton,
            .axis = pointerAxis,
            .frame = pointerFrame,
            .axis_source = pointerAxisSource,
            .axis_stop = pointerAxisStop,
            .axis_discrete = null, //obsolete since version 8
            .axis_value120 = pointerAxisValue120,
            .axis_relative_direction = pointerAxisRelativeDirection,
        },
        .keyboard_listener = c.wl_keyboard_listener{
            .keymap = keyboardKeymap,
            .enter = keyboardEnter,
            .leave = keyboardLeave,
            .key = keyboardKey,
            .modifiers = keyboardModifiers,
            .repeat_info = keyboardRepeatInfo,
        },
    };

    _ = c.wl_registry_add_listener(context.registry, &context.listeners.registry_listener, context);
    _ = c.wl_display_roundtrip(context.display);

    //TODO check compositor and xdg_wm_base

    context.surface = c.wl_compositor_create_surface(context.compositor) orelse return SetupError.CouldNotCreateSurface;
    context.xdg_surface = c.xdg_wm_base_get_xdg_surface(context.xdg_wm_base, context.surface) orelse return SetupError.CouldNotGetXdgSurface;
    context.xdg_toplevel = c.xdg_surface_get_toplevel(context.xdg_surface) orelse return SetupError.CouldNotGetXdgTopLevel;

    _ = c.xdg_surface_add_listener(context.xdg_surface, &context.listeners.xdg_surface_listener, context);
    _ = c.xdg_toplevel_add_listener(context.xdg_toplevel, &context.listeners.xdg_toplevel_listener, context);

    c.wl_surface_commit(context.surface);

    //TODO create wayland log scope
    std.log.debug("Wayland context created\n", .{});
    return context;
}

pub fn cleanup(allocator: std.mem.Allocator, context: *const Context) void {
    c.xdg_toplevel_destroy(context.xdg_toplevel);
    c.xdg_surface_destroy(context.xdg_surface);
    c.wl_pointer_destroy(context.pointer);
    c.wl_keyboard_destroy(context.keyboard);
    c.wl_seat_destroy(context.seat);
    c.wl_compositor_destroy(context.compositor);
    c.wl_registry_destroy(context.registry);
    c.wl_surface_destroy(context.surface);
    c.xdg_wm_base_destroy(context.xdg_wm_base);
    c.wl_display_disconnect(context.display);

    allocator.destroy(context);

    //TODO create wayland log scope
    std.log.debug("Wayland context destroyed\n", .{});
}

pub fn displayDispatch(display: *c.wl_display) bool {
    return c.wl_display_dispatch(display) >= 0;
}

fn registryHandler(data: ?*anyopaque, registry: ?*c.wl_registry, id: u32, c_interface: [*c]const u8, version: u32) callconv(.c) void {
    _ = version;

    const context: *Context = @ptrCast(@alignCast(data.?));
    const interface = std.mem.span(c_interface);


    //TODO null handling
    if (std.mem.eql(u8, interface, std.mem.span(c.wl_compositor_interface.name))) {
        context.compositor = @ptrCast(c.wl_registry_bind(registry, id, &c.wl_compositor_interface, compositor_version).?);
    } else if (std.mem.eql(u8, interface, std.mem.span(c.xdg_wm_base_interface.name))) {
        context.xdg_wm_base = @ptrCast(c.wl_registry_bind(registry, id, &c.xdg_wm_base_interface, xdg_wm_base_version).?);
        _ = c.xdg_wm_base_add_listener(context.xdg_wm_base, &context.listeners.xdg_wm_base_listener, null);
    } else if (std.mem.eql(u8, interface, std.mem.span(c.wl_shm_interface.name))) {
        context.shm = @ptrCast(c.wl_registry_bind(registry, id, &c.wl_shm_interface, shm_version).?);
    } else if (std.mem.eql(u8, interface, std.mem.span(c.wl_seat_interface.name))) {
        context.seat = @ptrCast(c.wl_registry_bind(registry, id, &c.wl_seat_interface, seat_version).?);

        context.pointer = c.wl_seat_get_pointer(context.seat).?;
        _ = c.wl_pointer_add_listener(context.pointer, &context.listeners.pointer_listener, null);

        context.keyboard = c.wl_seat_get_keyboard(context.seat).?;
        _ = c.wl_keyboard_add_listener(context.keyboard, &context.listeners.keyboard_listener, null);
    }
}

fn registryRemover(data: ?*anyopaque, registry: ?*c.wl_registry, id: u32) callconv(.c) void {
    _ = data;
    _ = registry;
    _ = id;
}

fn xdgWmBasePing(data: ?*anyopaque, wm_base: ?*c.xdg_wm_base, serial: u32) callconv(.c) void {
    _ = data;
    c.xdg_wm_base_pong(wm_base, serial);
}

fn xdgSurfaceConfigure(data: ?*anyopaque, xdg_surface: ?*c.xdg_surface, serial: u32) callconv(.c) void {
    c.xdg_surface_ack_configure(xdg_surface, serial);

    const context: *Context = @ptrCast(@alignCast(data.?));

    //NOTE might be better to call from xdgTopLevelConfigure
    const buffer = createBuffer(context.allocator, &context.buffer_context, context.shm, context.win_width, context.win_height) catch @panic("buffer wasn't created");
    c.wl_surface_attach(context.surface, buffer, 0, 0);

    c.wl_surface_set_input_region(context.surface, null);
    c.wl_surface_commit(context.surface);
}

fn xdgTopLevelConfigure(data: ?*anyopaque, xdg_toplevel: ?*c.xdg_toplevel, width: i32, height: i32, wl_states: [*c]c.wl_array) callconv(.c) void {
    _ = xdg_toplevel;

    const compontents: *Context = @ptrCast(@alignCast(data.?));
    const states: []c_uint = std.mem.span(@as([*c]c_uint, @alignCast(@ptrCast(wl_states.*.data))));
    //TODO handle states
    _ = states;
    
    std.debug.assert(height > 0);
    std.debug.assert(width > 0);

    compontents.win_width = @intCast(width);
    compontents.win_height = @intCast(height);
}

fn xdgTopLevelClose(data: ?*anyopaque, xdg_toplevel: ?*c.xdg_toplevel) callconv(.c) void {
    _ = data;
    _ = xdg_toplevel;

    std.c.exit(0); //TODO better exit handling
}

fn xdgTopLevelConfigureBounds(data: ?*anyopaque, xdg_toplevel: ?*c.xdg_toplevel, width: i32, height: i32) callconv(.c) void {
    _ = data; // autofix
    _ = xdg_toplevel; // autofix
    _ = width; // autofix
    _ = height; // autofix
}

fn xdgTopLevelCapabilities(data: ?*anyopaque, xdg_toplevel: ?*c.xdg_toplevel, capabilities: [*c]c.wl_array) callconv(.c) void {
    _ = data; // autofix
    _ = xdg_toplevel; // autofix
    _ = capabilities; // autofix
}

fn createBuffer(allocator: std.mem.Allocator, buffer_context: *?BufferContext, shm: *c.wl_shm, width: u32, height: u32) !*c.wl_buffer {
    std.log.debug("called createBuffer\n", .{});
    const stride = width * 4;
    const size = stride * height;

    if (buffer_context.*) |*bc| {
        if (size < bc.buffer.len) {
            std.log.debug("shrinking buffer\n", .{});
            bc.buffer = try std.posix.mremap(@alignCast(bc.buffer.ptr), bc.buffer.len, size, std.posix.MREMAP{}, null);
            std.log.debug("shrinked buffer\n", .{});
        } else if (size > bc.buffer.len) {
            std.log.debug("growing buffer\n", .{});
            if(size > bc.size) {
                try std.posix.ftruncate(bc.file_descriptor, size);
                c.wl_shm_pool_resize(bc.shm_pool, @intCast(size));
                bc.size = size;
            }

            bc.buffer = try std.posix.mremap(@alignCast(bc.buffer.ptr), bc.buffer.len, size, std.posix.MREMAP{ .MAYMOVE = true }, null);

            std.log.debug("grown buffer\n", .{});
        }
    } else {
        buffer_context.* = try setupBufferContext(allocator, shm, size);
    }

    const pixels: []u32 = @ptrCast(@alignCast(buffer_context.*.?.buffer));

    for (pixels) |*pixel| {
        pixel.* = 0xffff0000;
    }
    //x + y * width = i
    const rc_x = 500;
    const rc_y = 500;
    const rc_w = 500;
    const rc_h = 50;

    const clamped_y = clamp(usize, rc_y, 0, height);
    const clamped_x = clamp(usize, rc_x, 0, width);
    for (clamped_y..clamp(usize, rc_y + rc_h, clamped_y, height)) |y| {
        for (clamped_x..clamp(usize, rc_x + rc_w, clamped_x, width)) |x| {
            pixels[x + y * width] = 0xff0000ff;
        }
    }

    const buffer = c.wl_shm_pool_create_buffer(buffer_context.*.?.shm_pool, 0, @intCast(width), @intCast(height), @intCast(stride), c.WL_SHM_FORMAT_ARGB8888).?; //TODO null handling
    return buffer;
}

fn clamp(T: type, value: T, min: T, max: T) T {
    return @max(min, @min(value, max));
}

fn setupBufferContext(allocator: std.mem.Allocator, shm: *c.wl_shm, size: u32) !BufferContext {
    std.log.debug("setupBufferContext\n", .{});

    const file = try createShmFile(allocator, size); //TODO inline
    const fd = file.handle;

    return .{
        .file_descriptor = fd,
        .buffer = try std.posix.mmap(null, size, PROT.READ | PROT.WRITE, std.posix.MAP{ .TYPE = .SHARED, }, fd, 0), //TODO compare with std.os.linux.mmap
        .shm_pool = c.wl_shm_create_pool(shm, fd, @intCast(size)).?, //TODO null handling
        .size = size,
    };
}

fn createShmFile(allocator: std.mem.Allocator, size: u32) !std.fs.File {
    const template = "/wl_shm-XXXXXX";
    const dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse "/tmp";
    const paths = [_][]const u8{ dir, template };

    const file_path = try std.fs.path.join(allocator, &paths);
    defer allocator.free(file_path);

    const file = try std.fs.createFileAbsolute(file_path, std.fs.File.CreateFlags{ .read = true, .truncate = true, .exclusive = true, });

    try std.fs.deleteFileAbsolute(file_path); //deletes after file closes
    try file.setEndPos(size);

    return file;
}

fn pointerEnter(data: ?*anyopaque, pointer: ?*c.wl_pointer, serial: u32, surface: ?*c.wl_surface, surface_x: c.wl_fixed_t, surface_y: c.wl_fixed_t) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = serial;
    _ = surface;
    _ = surface_x;
    _ = surface_y;

    //TODO handle
}

fn pointerLeave(data: ?*anyopaque, pointer: ?*c.wl_pointer, serial: u32, surface: ?*c.wl_surface) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = serial;
    _ = surface;

    //TODO handle
}

fn pointerMotion(data: ?*anyopaque, pointer: ?*c.wl_pointer, time: u32, surface_x: c.wl_fixed_t, surface_y: c.wl_fixed_t) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = time;
    _ = surface_x;
    _ = surface_y;

    //TODO handle
}

//TODO check std for values
const LinuxInputEvent = enum(u32) {
    btn_left = 0x110,
    btn_right = 0x111,
    btn_middle = 0x112,
};

//TODO replace by values from C
const WlPointerButtonState = enum(u32) {
    released = 0,
    pressed = 1,
};

fn pointerButton(data: ?*anyopaque, pointer: ?*c.wl_pointer, serial: u32, time: u32, pointer_button: u32, pointer_state: u32) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = serial;
    _ = time;

    const button: LinuxInputEvent = @enumFromInt(pointer_button);
    const state: WlPointerButtonState = @enumFromInt(pointer_state);

    //TODO handle
    switch (state) {
        .pressed => {
            switch (button) {
                .btn_left => {
                    std.log.debug("Left mouse button pressed\n", .{});
                },
                .btn_right => {
                    std.log.debug("Right mouse button pressed\n", .{});
                },
                .btn_middle => {
                    std.log.debug("Middle mouse button pressed\n", .{});
                },
            }
        },
        .released => {
            switch (button) {
                .btn_left => {
                    std.log.debug("Left mouse button released\n", .{});
                },
                .btn_right => {
                    std.log.debug("Right mouse button released\n", .{});
                },
                .btn_middle => {
                    std.log.debug("Middle mouse button released\n", .{});
                },
            }
        },
    }
}

//TODO replace by values from C
const PointerAxis = enum(u32) {
    vertical_scroll = 0,
    horizontal_scroll = 1,
};

fn pointerAxis(data: ?*anyopaque, pointer: ?*c.wl_pointer, time: u32, pointer_axis: u32, value: c.wl_fixed_t) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = time;
    _ = value;

    const axis: PointerAxis = @enumFromInt(pointer_axis);
    _ = axis;
    //TODO handle
}

fn pointerFrame(data: ?*anyopaque, pointer: ?*c.wl_pointer) callconv(.c) void {
    _ = data;
    _ = pointer;

    std.log.debug("End of pointer frame\n", .{});
    //TODO handle
}

//TODO replace by values from C
const PointerAxisSource = enum(u32) {
    wheel = 0, //a physical wheel rotation
    finger = 1, //finger on a touch surface
    continuous = 2, //continuous coordinate space
    wheel_tilt = 3, //a physical wheel tilt
};

fn pointerAxisSource(data: ?*anyopaque, pointer: ?*c.wl_pointer, pointer_axis_source: u32) callconv(.c) void {
    _ = data;
    _ = pointer;

    const axis_source: PointerAxisSource = @enumFromInt(pointer_axis_source);
    _ = axis_source;
    //TODO handle
}

fn pointerAxisStop(data: ?*anyopaque, pointer: ?*c.wl_pointer, time: u32, pointer_axis: u32) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = time;

    const axis: PointerAxis = @enumFromInt(pointer_axis);
    _ = axis;
    //TODO handle
}

fn pointerAxisValue120(data: ?*anyopaque, pointer: ?*c.wl_pointer, pointer_axis: u32, value: i32) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = value;

    const axis: PointerAxis = @enumFromInt(pointer_axis);
    _ = axis;

    //TODO handle
}

//TODO replace by values from C
const PointerDirection = enum(u32) {
    identical = 0,
    inverted = 1,
};

fn pointerAxisRelativeDirection(data: ?*anyopaque, pointer: ?*c.wl_pointer, pointer_axis: u32, pointer_direction: u32) callconv(.c) void {
    _ = data;
    _ = pointer;

    const axis: PointerAxis = @enumFromInt(pointer_axis);
    _ = axis;

    const direction: PointerDirection = @enumFromInt(pointer_direction);
    _ = direction;
    //TODO handle
}

//TODO replace by values from C
const KeyboardKeymapFormat = enum(u32) {
    no_keymap = 0,
    xkb_v1 = 1,
};

fn keyboardKeymap(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, keyboard_keymap_format: c.enum_wl_keyboard_keymap_format, fd: std.fs.File.Handle, size: u32) callconv(.c) void {
    _ = data;
    _ = keyboard;
    _ = fd;
    _ = size;

    const keymap_format: KeyboardKeyState = @enumFromInt(keyboard_keymap_format);
    _ = keymap_format;

    //TODO handle
}

fn keyboardEnter(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, serial: u32, surface: ?*c.wl_surface, keys: [*c]c.wl_array) callconv(.c) void {
    _ = data;
    _ = keyboard;
    _ = serial;
    _ = surface;
    _ = keys;

    //TODO handle
}

fn keyboardLeave(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, serial: u32, surface: ?*c.wl_surface) callconv(.c) void {
    _ = data;
    _ = keyboard;
    _ = serial;
    _ = surface;

    //TODO handle
}

//TODO replace by values from C
const KeyboardKeyState = enum(u32) {
    released = 0,
    pressed = 1,
    repeated = 2,
};

fn keyboardKey(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, serial: u32, time: u32, key: u32, keyboard_key_state: c.enum_wl_keyboard_key_state) callconv(.c) void {
    _ = data;
    _ = keyboard;
    _ = serial;
    _ = time;

    const key_state: KeyboardKeyState = @enumFromInt(keyboard_key_state);

    switch (key_state) {
        .released => std.log.debug("Released key: {d}\n", .{key}),
        .pressed => std.log.debug("Pressed key: {d}\n", .{key}),
        .repeated => std.log.debug("Repeated key: {d}\n", .{key}),
    }
    //TODO handle
}

fn keyboardModifiers(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, serial: u32, mods_depressed: u32, mods_latched: u32, mods_locked: u32, group: u32) callconv(.c) void {
    _ = data;
    _ = keyboard;
    _ = serial;
    _ = mods_depressed;
    _ = mods_latched;
    _ = mods_locked;
    _ = group;

    //TODO handle
}

fn keyboardRepeatInfo(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, rate: i32, delay: i32) callconv(.c) void {
    _ = data;
    _ = keyboard;
    _ = rate;
    _ = delay;

    //TODO handle
}
