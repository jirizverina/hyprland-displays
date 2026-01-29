//TODO error handling when creating listeners

const std = @import("std");
const PROT = std.posix.PROT;
const c = @import("c.zig").c;

//TODO: remove unused fields
pub const Components = struct {
    listeners: Listeners = undefined,
    buffer_context: ?BufferContext,
    //NOTE: it should be solved differently, but I need to pass the allocator to create file path for buffer file
    allocator: std.mem.Allocator,
    display: *c.wl_display,
    registry: *c.wl_registry,
    shm: *c.wl_shm = undefined,
    compositor: *c.wl_compositor = undefined,
    xdg_wm_base: *c.xdg_wm_base = undefined,
    surface: *c.wl_surface = undefined,
    seat: *c.wl_seat = undefined,
    pointer: *c.wl_pointer = undefined,
    keyboard: *c.wl_keyboard = undefined,
    xdg_surface: *c.xdg_surface = undefined,
    xdg_toplevel: *c.xdg_toplevel = undefined,
    win_width: u32 = undefined,
    win_height: u32 = undefined,
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

pub fn setupWayland(allocator: std.mem.Allocator) (SetupError || std.mem.Allocator.Error)!*Components {
    const display = c.wl_display_connect(null) orelse return SetupError.CouldNotConnectDisplay;

    const registry = c.wl_display_get_registry(display) orelse return SetupError.CouldNotGetDisplayRegistry;

    var components = try allocator.create(Components);
    components.buffer_context = null;
    components.allocator = allocator;
    components.display = display;
    components.registry = registry;

    components.listeners = .{
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

    _ = c.wl_registry_add_listener(registry, &components.listeners.registry_listener, components);
    _ = c.wl_display_roundtrip(display);

    //TODO check compositor and xdg_wm_base

    components.surface = c.wl_compositor_create_surface(components.compositor) orelse return SetupError.CouldNotCreateSurface;
    components.xdg_surface = c.xdg_wm_base_get_xdg_surface(components.xdg_wm_base, components.surface) orelse return SetupError.CouldNotGetXdgSurface;
    components.xdg_toplevel = c.xdg_surface_get_toplevel(components.xdg_surface) orelse return SetupError.CouldNotGetXdgTopLevel;

    _ = c.xdg_surface_add_listener(components.xdg_surface, &components.listeners.xdg_surface_listener, components);
    _ = c.xdg_toplevel_add_listener(components.xdg_toplevel, &components.listeners.xdg_toplevel_listener, components);

    c.wl_surface_commit(components.surface);

    //TODO create wayland log scope
    std.log.debug("Wayland components created", .{});
    return components;
}

pub fn cleanupWayland(allocator: std.mem.Allocator, components: *const Components) void {
    c.xdg_toplevel_destroy(components.xdg_toplevel);
    c.xdg_surface_destroy(components.xdg_surface);
    c.wl_pointer_destroy(components.pointer);
    c.wl_keyboard_destroy(components.keyboard);
    c.wl_seat_destroy(components.seat);
    c.wl_compositor_destroy(components.compositor);
    c.wl_registry_destroy(components.registry);
    c.wl_surface_destroy(components.surface);
    c.xdg_wm_base_destroy(components.xdg_wm_base);
    c.wl_display_disconnect(components.display);

    allocator.destroy(components);

    //TODO create wayland log scope
    std.log.debug("Wayland components destroyed", .{});
}

pub fn displayDispatch(display: *c.wl_display) bool {
    return c.wl_display_dispatch(display) >= 0;
}

fn registryHandler(data: ?*anyopaque, registry: ?*c.wl_registry, id: u32, c_interface: [*c]const u8, version: u32) callconv(.c) void {
    _ = version;

    const components: *Components = @ptrCast(@alignCast(data.?));
    const interface = std.mem.span(c_interface);

    //TODO null handling
    if (std.mem.eql(u8, interface, std.mem.span(c.wl_compositor_interface.name))) {
        components.compositor = @ptrCast(c.wl_registry_bind(registry, id, &c.wl_compositor_interface, 4).?);
    } else if (std.mem.eql(u8, interface, std.mem.span(c.xdg_wm_base_interface.name))) {
        components.xdg_wm_base = @ptrCast(c.wl_registry_bind(registry, id, &c.xdg_wm_base_interface, 1).?);
        _ = c.xdg_wm_base_add_listener(components.xdg_wm_base, &components.listeners.xdg_wm_base_listener, null);
    } else if (std.mem.eql(u8, interface, std.mem.span(c.wl_shm_interface.name))) {
        components.shm = @ptrCast(c.wl_registry_bind(registry, id, &c.wl_shm_interface, 1).?);
    } else if (std.mem.eql(u8, interface, std.mem.span(c.wl_seat_interface.name))) {
        components.seat = @ptrCast(c.wl_registry_bind(registry, id, &c.wl_seat_interface, 9).?);

        components.pointer = c.wl_seat_get_pointer(components.seat).?;
        _ = c.wl_pointer_add_listener(components.pointer, &components.listeners.pointer_listener, null);

        components.keyboard = c.wl_seat_get_keyboard(components.seat).?;
        _ = c.wl_keyboard_add_listener(components.keyboard, &components.listeners.keyboard_listener, null);
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

    const components: *Components = @ptrCast(@alignCast(data.?));

    const buffer = createBuffer(components.allocator, &components.buffer_context, components.shm, components.win_width, components.win_height) catch @panic("buffer wasn't created");
    c.wl_surface_attach(components.surface, buffer, 0, 0);

    c.wl_surface_set_input_region(components.surface, null);
    c.wl_surface_commit(components.surface);
}

fn xdgTopLevelConfigure(data: ?*anyopaque, xdg_toplevel: ?*c.xdg_toplevel, width: i32, height: i32, states: [*c]c.wl_array) callconv(.c) void {
    _ = xdg_toplevel;
    _ = states;

    const compontents: *Components = @ptrCast(@alignCast(data.?));
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
                    std.log.debug("Left mouse button pressed", .{});
                },
                .btn_right => {
                    std.log.debug("Right mouse button pressed", .{});
                },
                .btn_middle => {
                    std.log.debug("Middle mouse button pressed", .{});
                },
            }
        },
        .released => {
            switch (button) {
                .btn_left => {
                    std.log.debug("Left mouse button released", .{});
                },
                .btn_right => {
                    std.log.debug("Right mouse button released", .{});
                },
                .btn_middle => {
                    std.log.debug("Middle mouse button released", .{});
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

    std.log.debug("End of pointer frame", .{});
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
