const std = @import("std");
const wl = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wayland-client-protocol.h");
});

//TODO check usage of anyopaque
//TODO struct for hot_spot

const width: u32 = 400;
const height: u32 = 400;
const pixel_size: u32 = 4;
const cursor_width: u32 = 100;
const cursor_height: u32 = 60;
const cursor_hot_spot_x = 10;
const cursor_hot_spot_y = 35;
const pixel_format_id: u32 = wl.WL_SHM_FORMAT_ARGB8888;

var done: bool = false;

var compositor: *wl.wl_compositor = undefined;
var display: *wl.wl_display = undefined;
var pointer: *wl.wl_pointer = undefined;
var seat: *wl.wl_seat = undefined;
var shell: *wl.wl_shell = undefined;
var shm: *wl.wl_shm = undefined;

const WaylandError = error {
    DisplayDispatch, //TODO rename
    CouldNotConnectDisplay,
    CouldNotCreatePool,
    CouldNotCreatePoolBuffer,
    CouldNotCreateSurface,
    CouldNotCreateShell,
    CompositorCouldNotCreateSurface,
    XdgRuntimeDirNotSet 
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    const allocator = gpa.allocator();

    var buffer: *wl.wl_buffer = undefined;
    var pool: *wl.wl_shm_pool = undefined;
    var surface: *wl.wl_shell_surface = undefined;
    
    std.debug.print("shell interface name = {s}\n", .{wl.wl_shell_interface.name});
    try setupWayland();
    const size = width * height * pixel_size;
    const file = try createFile(allocator, size);

    pool = try createMemoryPool(allocator, file.handle, size);
    surface = try createSurface();
    buffer = try createBuffer(pool);
    bindBuffer(buffer, surface);
    try setCursorFromPool(allocator, pool, cursor_hot_spot_x, cursor_hot_spot_y);
    setButtonCallback(surface, onButton);

    defer freeCursor(allocator);
    defer freeBuffer(buffer);
    defer freeSurface(surface);
    defer freeMemoryPool(allocator, pool);
    defer file.close();
    defer cleanupWayland();

    while (!done) {
        if(wl.wl_display_dispatch(display) < 0) {
            return WaylandError.DisplayDispatch;
        }
    }
}

fn setupWayland() WaylandError!void {
    display = try getDisplay();

    const registry: ?*wl.wl_registry = wl.wl_display_get_registry(display);
    _ = wl.wl_registry_add_listener(registry, &registry_listener, null);
    _ = wl.wl_display_roundtrip(display);
    wl.wl_registry_destroy(registry);
}

fn cleanupWayland() void {
    wl.wl_pointer_destroy(pointer);
    wl.wl_seat_destroy(seat);
    wl.wl_shell_destroy(shell);
    wl.wl_shm_destroy(shm);
    wl.wl_compositor_destroy(compositor);
    wl.wl_display_disconnect(display);
}

fn getDisplay() WaylandError!*wl.wl_display {
    if(wl.wl_display_connect(null)) |d| {
        return d;
    }

    return WaylandError.CouldNotConnectDisplay;
}

fn onButton(button: u32) void {
    _ = button;
    done = true;
}

const PoolData = struct { //TODO memory layout
    fd: std.fs.File.Handle,
    memory: []align(std.heap.page_size_min) u8,
    capacity: usize,
    size: usize
};

fn createMemoryPool(allocator: std.mem.Allocator, file_handle: std.fs.File.Handle, file_size: usize) !*wl.wl_shm_pool {
    //TODO file_handle check validity (fstat)
    const data = try allocator.create(PoolData);
    errdefer allocator.destroy(data);

    data.*.capacity = file_size;
    data.*.size = 0;
    data.*.fd = file_handle;
    data.*.memory = try std.posix.mmap(null, data.*.capacity, std.posix.PROT.READ, std.posix.MAP{ .TYPE = .SHARED }, data.*.fd, 0);

    errdefer std.posix.munmap(data.*.memory);

    if(wl.wl_shm_create_pool(shm, data.*.fd, @as(i32, @intCast(data.*.capacity)))) |pool| {
        wl.wl_shm_pool_set_user_data(pool, data);
        return pool;
    } else {
        return WaylandError.CouldNotCreatePool;
    }
}

fn freeMemoryPool(allocator: std.mem.Allocator, pool: *wl.wl_shm_pool) void {
    const data: *PoolData = @ptrCast(@alignCast(wl.wl_shm_pool_get_user_data(pool).?));
    wl.wl_shm_pool_destroy(pool);
    std.posix.munmap(data.*.memory);
    allocator.destroy(data);
}

fn createBuffer(pool: *wl.wl_shm_pool) WaylandError!*wl.wl_buffer {
    var pool_data: *PoolData = undefined;
    if(wl.wl_shm_pool_get_user_data(pool)) |pd| {
        pool_data = @ptrCast(@alignCast(pd));
    } else {
        return WaylandError.CouldNotCreatePoolBuffer; //TODO vlastni error
    }

    if(wl.wl_shm_pool_create_buffer(pool, @intCast(pool_data.*.size), width, height, width*pixel_size, pixel_format_id)) |b| {
        pool_data.*.size += width*height*pixel_size;
        return b;
    } else {
        return WaylandError.CouldNotCreatePoolBuffer;
    }
}

fn freeBuffer(buffer: *wl.wl_buffer) void {
    wl.wl_buffer_destroy(buffer);
}

fn createSurface() !*wl.wl_shell_surface {
    var surface: *wl.wl_surface = undefined;
    var shell_surface: *wl.wl_shell_surface = undefined;
    
    if(wl.wl_compositor_create_surface(compositor)) |s| {
        surface = s;
    } else {
        return WaylandError.CouldNotCreateSurface;
    }

    std.debug.print("shell {any}\n", .{shell});
    std.debug.print("surface {any}\n", .{surface});

    if(wl.wl_shell_get_shell_surface(shell, surface)) |shell_s| {
        shell_surface = shell_s;
    } else {
        return WaylandError.CouldNotCreateShell;
    }

    _ = wl.wl_shell_surface_add_listener(shell_surface, &shell_surface_listener, null);
    wl.wl_shell_surface_set_toplevel(shell_surface);
    wl.wl_shell_surface_set_user_data(shell_surface, surface);
    wl.wl_surface_set_user_data(surface, null);

    return shell_surface;
}

fn freeSurface(shell_surface: *wl.wl_shell_surface) void {
    const surface: *wl.wl_surface = @ptrCast(wl.wl_shell_surface_get_user_data(shell_surface).?);
    wl.wl_shell_surface_destroy(shell_surface);
    wl.wl_surface_destroy(surface);
}

fn bindBuffer(buffer: *wl.wl_buffer, shell_surface: *wl.wl_shell_surface) void {
    const surface: *wl.wl_surface = @ptrCast(wl.wl_shell_surface_get_user_data(shell_surface).?);
    wl.wl_surface_attach(surface, buffer, 0, 0);
    wl.wl_surface_commit(surface);
}

fn setButtonCallback(shell_surface: *wl.wl_shell_surface, callback: *const fn(button: u32) void) void {
    const surface: *wl.wl_surface = @ptrCast(wl.wl_shell_surface_get_user_data(shell_surface).?);
    wl.wl_surface_set_user_data(surface, @constCast(callback));
}

const PointerData = struct {
    surface: *wl.wl_surface,
    buffer: * wl.wl_buffer,
    hot_spot_x: i32,
    hot_spot_y: i32,
    target_surface: ?*wl.wl_surface
};

fn setCursorFromPool(allocator: std.mem.Allocator, pool: *wl.wl_shm_pool, hot_spot_x: i32, hot_spot_y: i32) !void {
    const data = try allocator.create(PointerData);
    errdefer allocator.destroy(data);
    data.*.hot_spot_x = hot_spot_x;
    data.*.hot_spot_y = hot_spot_y;

    if(wl.wl_compositor_create_surface(compositor)) |surface| {
        data.*.surface = surface;
        errdefer wl.wl_surface_destroy(data.*.surface);
    } else {
        return WaylandError.CompositorCouldNotCreateSurface;
    }
    
    data.*.buffer = try createBuffer(pool);
    wl.wl_pointer_set_user_data(pointer, data);
}

fn freeCursor(allocator: std.mem.Allocator) void {
    const data: *PointerData = @ptrCast(@alignCast(wl.wl_pointer_get_user_data(pointer).?));
    wl.wl_buffer_destroy(data.*.buffer);
    wl.wl_surface_destroy(data.*.surface);
    allocator.destroy(data);
    wl.wl_pointer_set_user_data(pointer, null);
}

fn pointerEnter(data: ?*anyopaque,
    wl_pointer: ?*wl.wl_pointer,
    serial: u32,
    surface: ?*wl.wl_surface,
    surface_x: wl.wl_fixed_t,
    surface_y: wl.wl_fixed_t) callconv(.c) void {
    _ = data;
    _ = surface_x;
    _ = surface_y;

    const pointer_data: *PointerData = @ptrCast(@alignCast(wl.wl_pointer_get_user_data(wl_pointer).?));
    pointer_data.*.target_surface = surface;

    wl.wl_surface_attach(pointer_data.*.surface, pointer_data.*.buffer, 0, 0);
    wl.wl_surface_commit(pointer_data.*.surface);
    wl.wl_pointer_set_cursor(wl_pointer,
        serial,
        pointer_data.*.surface,
        pointer_data.*.hot_spot_x,
        pointer_data.*.hot_spot_y);
}

fn pointerLeave(data: ?*anyopaque, wl_pointer: ?*wl.wl_pointer, serial: u32, wl_surface: ?*wl.wl_surface) callconv(.c) void {
    _ = data;
    _ = wl_pointer;
    _ = serial;
    _ = wl_surface;
}

fn pointerMotion(data: ?*anyopaque, wl_pointer: ?*wl.wl_pointer, time: u32, surface_x: wl.wl_fixed_t, surface_y: wl.wl_fixed_t) callconv(.c) void {
    _ = data;
    _ = wl_pointer;
    _ = time;
    _ = surface_x;
    _ = surface_y;
}

fn pointerButton(data: ?*anyopaque, wl_pointer: ?*wl.wl_pointer, serial: u32, time: u32, button: u32, state: u32) callconv(.c) void {
    _ = data;
    _ = serial;
    _ = time;
    _ = state;

    const pointer_data: *PointerData = @ptrCast(@alignCast(wl.wl_pointer_get_user_data(wl_pointer).?));
    if(wl.wl_surface_get_user_data(pointer_data.*.surface)) |callback| {
        @as(*const fn (button: u32) void, @ptrCast(callback))(button);
    }
}

fn pointerAxis(data: ?*anyopaque, wl_pointer: ?*wl.wl_pointer, time: u32, axis: u32, value: wl.wl_fixed_t) callconv(.c) void {
    _ = data;
    _ = wl_pointer;
    _ = time;
    _ = axis;
    _ = value;
}

const pointer_listener = wl.wl_pointer_listener{
    .enter = pointerEnter,
    .leave = pointerLeave,
    .motion = pointerMotion,
    .button = pointerButton,
    .axis = pointerAxis
};

fn registryGlobal(data: ?*anyopaque, registry: ?*wl.wl_registry, name: u32, c_interface: [*c]const u8, version: u32) callconv(.c) void {
    _ = data;

    std.debug.print("called registry global - {s}\n", .{c_interface});
    const interface = std.mem.span(c_interface);
    
    if (std.mem.eql(u8, interface, std.mem.span(wl.wl_compositor_interface.name))) {
        compositor = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_compositor_interface, @min(version, 4)).?);
    } else if (std.mem.eql(u8, interface, std.mem.span(wl.wl_shm_interface.name))) {
        shm = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_shm_interface, @min(version, 1)).?);
    } else if (std.mem.eql(u8, interface, std.mem.span(wl.wl_shell_interface.name))) { //TODO replace with xdg_vm_base
        shell = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_shell_interface, @min(version, 1)).?);
        std.debug.print("registry global - shell - {any}", .{shell});
    } else if (std.mem.eql(u8, interface, std.mem.span(wl.wl_seat_interface.name))) {
        seat = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_seat_interface, @min(version, 2)).?);
        pointer = wl.wl_seat_get_pointer(seat).?;
        _ = wl.wl_pointer_add_listener(pointer, &pointer_listener, null);
    }
}

fn registryGlobalRemove(a: ?*anyopaque, b: ?*wl.wl_registry, c: u32) callconv(.c) void {
    _ = a;
    _ = b;
    _ = c;
}

const registry_listener = wl.wl_registry_listener{
    .global = registryGlobal,
    .global_remove = registryGlobalRemove,
};

fn createFile(allocator: std.mem.Allocator, size: usize) !std.fs.File {
    const template = "/simple-shm-1";
    const dir = std.posix.getenv("XDG_RUNTIME_DIR");
    if(dir == null) {
        return WaylandError.XdgRuntimeDirNotSet;
    }

    const paths = [_][]const u8 {dir.?, template};
    const file_path = try std.fs.path.join(allocator, &paths);
    defer allocator.free(file_path);

    const file = try std.fs.createFileAbsolute(file_path, std.fs.File.CreateFlags{ .read = true, .truncate = false, .exclusive = true });
    
    try std.fs.deleteFileAbsolute(file_path); //deletes after file closes
    try file.setEndPos(size);
    
    return file;
}

fn shellSurfacePing(data: ?*anyopaque, shell_surface: ?*wl.wl_shell_surface, serial: u32) callconv(.c) void {
    _ = data;
    wl.wl_shell_surface_pong(shell_surface, serial);
}

fn shellSurfaceConfigure(data: ?*anyopaque, shell_surface: ?*wl.wl_shell_surface, edges: u32, w: i32, h: i32) callconv(.c) void {
    _ = data;
    _ = shell_surface;
    _ = edges;
    _ = w;
    _ = h;
}

const shell_surface_listener = wl.wl_shell_surface_listener {
    .ping = shellSurfacePing,
    .configure = shellSurfaceConfigure,
};

fn paint(pixels: []u8) void {
    const casted_pixels: []u32 = @alignCast(@ptrCast(pixels));
    for (0..(width * height)) |i| {
        casted_pixels[i] = 0xff0000ff;
    }
}
