const std = @import("std");
const PROT = std.posix.PROT;
const c = @import("c.zig").c;

//TODO: remove unused fields
pub const Components = struct {
    //NOTE: it should be solved differently, but I need to pass the allocator to create file path for buffer file
    allocator: std.mem.Allocator,
    display: *c.wl_display,
    registry: *c.wl_registry,
    compositor: *c.wl_compositor = undefined,
    xdg_wm_base: *c.xdg_wm_base = undefined,
    surface: *c.wl_surface = undefined,
    xdg_surface: *c.xdg_surface = undefined,
    xdg_toplevel: *c.xdg_toplevel = undefined,
};

//TODO decide if it should be in components struct
var shm: *c.wl_shm = undefined;

//TODO put into struct
var win_width: u32 = undefined;
var win_height: u32 = undefined;

pub const SetupError = error{
    CouldNotConnectDisplay,
    CouldNotGetDisplayRegistry,
    CouldNotCreateSurface,
    CouldNotGetXdgSurface,
    CouldNotGetXdgTopLevel,
};

pub fn setupWayland(allocator: std.mem.Allocator) (SetupError || std.mem.Allocator.Error)!*Components {
    const display = c.wl_display_connect(null) orelse return SetupError.CouldNotConnectDisplay;

    const registry = c.wl_display_get_registry(display) orelse return SetupError.CouldNotGetDisplayRegistry;

    const components = try allocator.create(Components);
    components.display = display;
    components.registry = registry;
    components.allocator = allocator;

    _ = c.wl_registry_add_listener(registry, &registry_listener, components);
    _ = c.wl_display_roundtrip(display);

    //TODO check compositor and xdg_wm_base

    components.surface = c.wl_compositor_create_surface(components.compositor) orelse return SetupError.CouldNotCreateSurface;
    components.xdg_surface = c.xdg_wm_base_get_xdg_surface(components.xdg_wm_base, components.surface) orelse return SetupError.CouldNotGetXdgSurface;
    components.xdg_toplevel = c.xdg_surface_get_toplevel(components.xdg_surface) orelse return SetupError.CouldNotGetXdgTopLevel;

    _ = c.xdg_surface_add_listener(components.xdg_surface, &xdg_surface_listener, components);
    _ = c.xdg_toplevel_add_listener(components.xdg_toplevel, &xdg_toplevel_listener, null);

    c.wl_surface_commit(components.surface);

    return components;
}

pub fn cleanupWayland(components: *const Components) void {
    c.xdg_toplevel_destroy(components.xdg_toplevel);
    c.xdg_surface_destroy(components.xdg_surface);
    c.wl_surface_destroy(components.surface);
    c.wl_display_disconnect(components.display);
}

const registry_listener = c.wl_registry_listener{
    .global = registryHandler,
    .global_remove = registryRemover,
};

fn registryHandler(data: ?*anyopaque, registry: ?*c.wl_registry, id: u32, c_interface: [*c]const u8, version: u32) callconv(.c) void {
    _ = version;

    const components: *Components = @ptrCast(@alignCast(data.?));
    const interface = std.mem.span(c_interface);

    if (std.mem.eql(u8, interface, std.mem.span(c.wl_compositor_interface.name))) {
        components.compositor = @ptrCast(c.wl_registry_bind(registry, id, &c.wl_compositor_interface, 4).?);
    } else if (std.mem.eql(u8, interface, std.mem.span(c.xdg_wm_base_interface.name))) {
        components.xdg_wm_base = @ptrCast(c.wl_registry_bind(registry, id, &c.xdg_wm_base_interface, 1).?);
        _ = c.xdg_wm_base_add_listener(components.xdg_wm_base, &xdg_wm_base_listener, null);
    } else if (std.mem.eql(u8, interface, std.mem.span(c.wl_shm_interface.name))) {
        shm = @ptrCast(c.wl_registry_bind(registry, id, &c.wl_shm_interface, 1).?);
    }
}

fn registryRemover(data: ?*anyopaque, registry: ?*c.wl_registry, id: u32) callconv(.c) void {
    _ = data;
    _ = registry;
    _ = id;
}

const xdg_wm_base_listener = c.xdg_wm_base_listener{
    .ping = xdgWmBasePing,
};

fn xdgWmBasePing(data: ?*anyopaque, wm_base: ?*c.xdg_wm_base, serial: u32) callconv(.c) void {
    _ = data;
    c.xdg_wm_base_pong(wm_base, serial);
}

const xdg_surface_listener = c.xdg_surface_listener{
    .configure = xdgSurfaceConfigure,
};

fn xdgSurfaceConfigure(data: ?*anyopaque, xdg_surface: ?*c.xdg_surface, serial: u32) callconv(.c) void {
    c.xdg_surface_ack_configure(xdg_surface, serial);

    const components: *Components = @ptrCast(@alignCast(data.?));

    const buffer = drawBuffer(components.allocator, win_width, win_height) catch @panic("buffer wasn't created");
    c.wl_surface_attach(components.surface, buffer, 0, 0);
    c.wl_surface_commit(components.surface);
}

const xdg_toplevel_listener = c.xdg_toplevel_listener{
    .configure = xdgTopLevelConfigure,
    .close = xdgTopLevelClose,
};

fn xdgTopLevelConfigure(data: ?*anyopaque, xdg_toplevel: ?*c.xdg_toplevel, width: i32, height: i32, states: [*c]c.wl_array) callconv(.c) void {
    _ = data;
    _ = xdg_toplevel;
    _ = states;

    if (width > 0 and height > 0) {
        win_width = @intCast(width);
        win_height = @intCast(height);
    }
}

fn xdgTopLevelClose(data: ?*anyopaque, xdg_toplevel: ?*c.xdg_toplevel) callconv(.c) void {
    _ = data;
    _ = xdg_toplevel;

    std.c.exit(0); //TODO better exit handling
}

//TODO better error handling
fn drawBuffer(allocator: std.mem.Allocator, width: u32, height: u32) !*c.wl_buffer {
    const stride = width * 4;
    const size = stride * height;

    const file = try createShmFile(allocator, size);
    defer file.close();
    const fd = file.handle;

    //TODO on error close fd
    const data = try std.posix.mmap(null, size, PROT.READ | PROT.WRITE, std.posix.MAP{ .TYPE = .SHARED }, fd, 0);
    defer std.posix.munmap(data);

    const pixels: []u32 = @ptrCast(@alignCast(data));
    for (pixels) |*pixel| {
        pixel.* = 0x00ff0000;
    }

    //TODO null handling
    const pool = c.wl_shm_create_pool(shm, fd, @intCast(size)).?;
    const buffer = c.wl_shm_pool_create_buffer(pool, 0, @intCast(width), @intCast(height), @intCast(stride), c.WL_SHM_FORMAT_ARGB8888).?;
    c.wl_shm_pool_destroy(pool);

    return buffer;
}

fn createShmFile(allocator: std.mem.Allocator, size: u32) !std.fs.File {
    const template = "/wl_shm-XXXXXX";
    const dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse "/tmp";
    const paths = [_][]const u8{ dir, template };

    const file_path = try std.fs.path.join(allocator, &paths);
    defer allocator.free(file_path);

    const file = try std.fs.createFileAbsolute(file_path, std.fs.File.CreateFlags{ .read = true, .truncate = false, .exclusive = true });

    try std.fs.deleteFileAbsolute(file_path); //deletes after file closes
    try file.setEndPos(size);

    return file;
}
