const std = @import("std");
const mem = std.mem;
const os = std.os;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zxdg = wayland.client.zxdg;

const Dimensions = struct {
    width: i32 = 512,
    height: i32 = 512,
};

const DisplayState = struct {
    running: bool = true,
    dimensions: Dimensions = Dimensions{},
};

const Context = struct {
    shm: ?*wl.Shm,
    compositor: ?*wl.Compositor,
    wm_base: ?*xdg.WmBase,
    decoration_manager: ?*zxdg.DecorationManagerV1,
};

const Color = packed struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

pub fn main() !void {
    std.debug.print("Starting main\n", .{});
    const display = try wl.Display.connect(null);
    std.debug.print("Connected the display: {?}\n", .{ .display = display });
    const registry = try display.getRegistry();
    std.debug.print("Connected the registry\n", .{});

    var context = Context{
        .shm = null,
        .compositor = null,
        .wm_base = null,
        .decoration_manager = null,
    };

    std.debug.print("Setting the context listener\n", .{});
    registry.setListener(*Context, registryListener, &context);

    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    const shm = context.shm orelse return error.NoWlShm;
    const compositor = context.compositor orelse return error.NoWlCompositor;
    std.debug.print("Compositor: {s}\n", .{
        .name = wl.Compositor.getInterface().name,
    });
    const wm_base = context.wm_base orelse return error.NoXdgWmBase;
    const decoration_manager = context.decoration_manager orelse return error.NoXdgDecorationManager;

    std.debug.print(" Got all the context objects", .{});
    var display_state = DisplayState{};

    const buffer = blk: {
        const width = display_state.dimensions.width;
        const height = display_state.dimensions.height;
        const stride = width * 4;
        const size = stride * height;

        const fd = try os.memfd_create("handmade-hero-zig", 0);
        try os.ftruncate(fd, @intCast(size));
        const data = try os.mmap(null, @intCast(size), os.PROT.READ | os.PROT.WRITE, os.MAP.SHARED, fd, 0);
        const background = Color{
            .r = 0,
            .g = 0,
            .b = 0,
            .a = 255,
        };

        var offset: usize = 0;
        while (offset < @divExact(size, 4)) : (offset += 1) {
            const i = offset * 4;
            data[i] = background.r;
            data[i + 1] = background.g;
            data[i + 2] = background.b;
            data[i + 3] = background.a;
        }
        // @memset(data, background);

        const pool = try shm.createPool(fd, size);
        defer pool.destroy();

        break :blk try pool.createBuffer(0, width, height, stride, wl.Shm.Format.argb8888);
    };
    defer buffer.destroy();

    const surface = try compositor.createSurface();
    defer surface.destroy();
    const xdg_surface = try wm_base.getXdgSurface(surface);
    defer xdg_surface.destroy();
    const xdg_toplevel = try xdg_surface.getToplevel();
    defer xdg_toplevel.destroy();

    const decoration = try decoration_manager.getToplevelDecoration(xdg_toplevel);
    decoration.setListener(*zxdg.ToplevelDecorationV1, zxdgToplevelDecorationListener, decoration);
    defer decoration.destroy();

    wm_base.setListener(*xdg.WmBase, xdgWmBaseListener, wm_base);
    xdg_surface.setListener(*wl.Surface, xdgSurfaceListener, surface);
    xdg_toplevel.setListener(*DisplayState, xdgToplevelListener, &display_state);

    xdg_toplevel.setTitle("Handmade Hero");
    xdg_toplevel.setMaximized();

    surface.commit();
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    surface.attach(buffer, 0, 0);
    surface.commit();

    while (display_state.running) {
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
    }
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, context: *Context) void {
    switch (event) {
        .global => |global| {
            if (mem.orderZ(u8, global.interface, wl.Compositor.getInterface().name) == .eq) {
                context.compositor = registry.bind(global.name, wl.Compositor, 1) catch return;
            } else if (mem.orderZ(u8, global.interface, wl.Shm.getInterface().name) == .eq) {
                context.shm = registry.bind(global.name, wl.Shm, 1) catch return;
            } else if (mem.orderZ(u8, global.interface, xdg.WmBase.getInterface().name) == .eq) {
                context.wm_base = registry.bind(global.name, xdg.WmBase, 1) catch return;
            } else if (mem.orderZ(u8, global.interface, zxdg.DecorationManagerV1.getInterface().name) == .eq) {
                context.decoration_manager = registry.bind(global.name, zxdg.DecorationManagerV1, 1) catch return;
            }
        },
        .global_remove => {},
    }
}

fn xdgWmBaseListener(wm_base: *xdg.WmBase, event: xdg.WmBase.Event, _: *xdg.WmBase) void {
    switch (event) {
        .ping => |ping| {
            wm_base.pong(ping.serial);
        },
    }
}

fn xdgSurfaceListener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, surface: *wl.Surface) void {
    switch (event) {
        .configure => |configure| {
            xdg_surface.ackConfigure(configure.serial);
            surface.commit();
        },
    }
}

fn xdgToplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, state: *DisplayState) void {
    switch (event) {
        .configure => |config| {
            std.debug.print("Configuring toplevel: {any}\n", .{ .config = config });

            for (config.states.slice(xdg.Toplevel.State)) |s| {
                std.debug.print("One of the states {d}\n", .{ .s = s });
            }
            // @breakpoint();
            state.dimensions.width = config.width;
            state.dimensions.height = config.height;
        },
        .close => state.running = false,
        .configure_bounds => |bounds| {
            std.debug.print("Getting bounds: {any}\n", .{ .bounds = bounds });
        },
        // .wm_capabilities => {},
    }
}

fn zxdgToplevelDecorationListener(_: *zxdg.ToplevelDecorationV1, event: zxdg.ToplevelDecorationV1.Event, _: *zxdg.ToplevelDecorationV1) void {
    switch (event) {
        .configure => |configure| {
            std.debug.print("Configuring toplevel decoration: {any}\n", configure);
            switch (configure.mode) {
                .server_side => {
                    std.debug.print("Decoration is serverside. Nothing to do here...\n", .{});
                },
                .client_side => {
                    std.debug.print("Decoration needs to be client side!\n", .{});
                },
                _ => {
                    std.debug.print("Unknown decoration configure mode\n", .{});
                },
            }
        },
    }
}
