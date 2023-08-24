const std = @import("std");
const mem = std.mem;
const os = std.os;

const sysaudio = @import("mach-sysaudio");
const wayland = @import("wayland");
const xkb = @import("xkb");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zxdg = wayland.client.zxdg;

const debug = std.log.debug;

const Dimensions = struct {
    width: i32 = 512,
    height: i32 = 512,
    bytesPerPixel: i32 = @sizeOf(Color),
};

const DisplayState = struct {
    dimensions: Dimensions = Dimensions{},
    context: *Context,
    running: bool = true,
    resizing: bool = false,
    frameData: FrameData,
};

const KeyState = struct {
    keyboard: *wl.Keyboard,
    xkb_state: ?*xkb.State = null,
    xkb_context: *xkb.Context,
};

const Context = struct {
    shm: ?*wl.Shm,
    compositor: ?*wl.Compositor,
    wm_base: ?*xdg.WmBase,
    decoration_manager: ?*zxdg.DecorationManagerV1,
    seat: ?*wl.Seat,
};

const Color = packed struct {
    b: u8,
    g: u8,
    r: u8,
    a: u8,
};

const background = Color{
    .b = 0,
    .g = 0,
    .r = 0,
    .a = 200,
};

const Buffer = struct {
    buffer: *wl.Buffer,
    fd: os.fd_t,
    data: []u32,
};

const FrameData = struct {
    lastFrame: u32,
    offset: f32,
    surface: *wl.Surface,
};

const AudioState = struct {
    ctx: *sysaudio.Context,
    player: ?*sysaudio.Player,
};

fn fill(data: []u32, state: *DisplayState, color: Color) void {
    const width: usize = @intCast(state.dimensions.width);
    const height: usize = @intCast(state.dimensions.height);
    for (0..height) |h| {
        for (0..width) |w| {
            const i = (w + (h * width));
            data[i] = @bitCast(color);
            // data[i + 1] = color.g;
            // data[i + 2] = color.r;
            // data[i + 3] = color.a;
        }
    }
}

fn gradient(data: []u32, state: *DisplayState, color: Color) void {
    const offset: u32 = @intFromFloat(state.frameData.offset);
    _ = color;
    const width: usize = @intCast(state.dimensions.width);
    const height: usize = @intCast(state.dimensions.height);
    for (0..height) |h| {
        for (0..width) |w| {
            const i = (w + (h * width));
            const grad = Color{
                .b = @truncate(h),
                .g = @truncate(w + offset),
                .r = 0,
                .a = 255,
            };
            data[i] = @bitCast(grad);
        }
    }
}

fn genBuffer(state: *DisplayState) !Buffer {
    const width = state.dimensions.width;
    const height = state.dimensions.height;
    const stride = width * state.dimensions.bytesPerPixel;
    const size = stride * height;

    const fd = try os.memfd_create("handmade-hero-zig-0", 0);
    try os.ftruncate(fd, @intCast(size));
    const data = try os.mmap(null, @intCast(size), os.PROT.READ | os.PROT.WRITE, os.MAP.SHARED, fd, 0);
    const pixels: []u32 = std.mem.bytesAsSlice(u32, data);
    fill(pixels, state, background);

    const pool = try state.context.*.shm.?.createPool(fd, size);
    defer pool.destroy();

    return Buffer{
        .buffer = try pool.createBuffer(0, width, height, stride, wl.Shm.Format.argb8888),
        .fd = fd,
        .data = pixels,
    };
}

pub fn main() !void {
    const display = try wl.Display.connect(null);
    const registry = try display.getRegistry();

    var context = Context{
        .shm = null,
        .compositor = null,
        .wm_base = null,
        .decoration_manager = null,
        .seat = null,
    };

    registry.setListener(*Context, registryListener, &context);

    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    const shm = context.shm orelse return error.NoWlShm;
    _ = shm;
    const compositor = context.compositor orelse return error.NoWlCompositor;
    const wm_base = context.wm_base orelse return error.NoXdgWmBase;
    const decoration_manager = context.decoration_manager orelse return error.NoXdgDecorationManager;
    const seat = context.seat orelse return error.NoWlSeat;
    seat.setListener(*wl.Seat, wlSeatListener, seat);

    const surface = try compositor.createSurface();
    defer surface.destroy();

    var display_state = DisplayState{
        .context = &context,
        .frameData = FrameData{
            .surface = surface,
            .offset = 0,
            .lastFrame = 0,
        },
    };

    var buffer = try genBuffer(&display_state);
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

    surface.commit();
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    var keyboard = try seat.getKeyboard();
    var xkb_context = xkb.Context.new(.no_flags) orelse return error.NoXkbContext;
    var keyHandler = KeyState{
        .keyboard = keyboard,
        .xkb_context = xkb_context,
    };
    keyboard.setListener(*KeyState, keyboardHandler, &keyHandler);
    defer keyboard.release();
    surface.attach(buffer.buffer, 0, 0);
    surface.commit();

    const done = try surface.frame();
    done.setListener(*DisplayState, frameHandler, &display_state);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.testing.expect(false) catch @panic("MEM TEST FAIL");
    }
    var audio_ctx = try sysaudio.Context.init(.pipewire, allocator, .{ .deviceChangeFn = deviceChange });
    defer audio_ctx.deinit();
    try audio_ctx.refresh();
    const device = audio_ctx.defaultDevice(.playback) orelse return error.NoAudioDevice;
    var audio_state = AudioState{
        .ctx = &audio_ctx,
        .player = null,
    };
    var player = try audio_ctx.createPlayer(device, writeCallback, .{
        .media_role = .game,
        .user_data = &audio_state,
    });
    defer player.deinit();
    audio_state.player = &player;
    try player.start();
    try player.setVolume(0.65);
    try player.play();

    while (display_state.running) {
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
        // try flush_and_prepare_read(display);

        // _ = os.poll(&pollfds, 1) catch |err| {
        //     fatal("poll failed: {any}\n", .{ .err = err });
        // };

        // if (pollfds[poll_wayland].revents & os.POLL.IN != 0) {
        //     const errno = display.readEvents();
        //     if (errno != .SUCCESS) {
        //         fatal("error reading wayland events: {any}\n", .{ .err = errno });
        //     }
        // } else {
        //     display.cancelRead();
        // }
    }
}

fn flush_and_prepare_read(display: *wl.Display) !void {
    while (!display.prepareRead()) {
        if (display.dispatchPending() != .SUCCESS) return error.DispatchPendingFailed;
    }

    while (true) {
        const errno = display.flush();
        switch (errno) {
            .SUCCESS => return,
            .PIPE => {
                _ = display.readEvents();
                fatal("Pipe error after flush\n", .{});
            },
            .AGAIN => {
                var wayland_out = [_]os.pollfd{.{ .fd = display.getFd(), .events = os.POLL.OUT, .revents = 0 }};
                _ = os.poll(&wayland_out, -1) catch |err| {
                    fatal("poll failed after AGAIN: {any}\n", .{ .err = err });
                };
            },
            else => fatal("Failed to flush requests: {any}", .{ .err = errno }),
        }
    }
}

fn fatal(comptime msg: []const u8, args: anytype) noreturn {
    std.log.err(msg, args);
    os.exit(11);
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    std.debug.print("[{s}](s) ", .{ message_level.asText(), @tagName(scope) });
    std.debug.print(format, args);
    std.debug.print("\n");
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
            } else if (mem.orderZ(u8, global.interface, wl.Seat.getInterface().name) == .eq) {
                context.seat = registry.bind(global.name, wl.Seat, 1) catch return;
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
            // std.debug.print("Configuring toplevel: {any}\n", .{ .config = config });
            var resizing = false;

            for (config.states.slice(xdg.Toplevel.State)) |s| {
                // std.debug.print("Handling toplevel state: {any}\n", .{ .s = s });
                switch (s) {
                    .resizing => resizing = true,
                    .fullscreen => resizing = true,
                    .maximized => resizing = true,
                    else => {},
                }
            }
            state.dimensions.width = config.width;
            state.dimensions.height = config.height;
            state.resizing = resizing;
        },
        .close => state.running = false,
        .configure_bounds => |bounds| {
            debug("Getting bounds: {any}\n", .{ .bounds = bounds });
        },
        // .wm_capabilities => {},
    }
}

fn zxdgToplevelDecorationListener(_: *zxdg.ToplevelDecorationV1, event: zxdg.ToplevelDecorationV1.Event, _: *zxdg.ToplevelDecorationV1) void {
    switch (event) {
        .configure => |configure| {
            debug("Configuring toplevel decoration: {any}", configure);
            switch (configure.mode) {
                .server_side => {
                    debug("Decoration is serverside. Nothing to do here...", .{});
                },
                .client_side => {
                    debug("Decoration needs to be client side!", .{});
                },
                _ => {
                    debug("Unknown decoration configure mode\n", .{});
                },
            }
        },
    }
}

fn wlSeatListener(_: *wl.Seat, event: wl.Seat.Event, _: *wl.Seat) void {
    switch (event) {
        .capabilities => |cap| {
            debug("Configuration for seat capability: {any}\n", .{cap});
            if (!cap.capabilities.keyboard) {
                os.exit(122);
            }
        },
        .name => |evt| {
            debug("Found seat name: {s}\n", .{evt.name});
        },
    }
}

const WL_XKB_KEYCODE_OFFSET = 8;

fn keyboardHandler(_: *wl.Keyboard, event: wl.Keyboard.Event, state: *KeyState) void {
    switch (event) {
        .enter => {},
        .leave => {},
        .repeat_info => {},
        .keymap => |kev| {
            defer os.close(kev.fd);
            const keymap_str = os.mmap(null, kev.size, os.PROT.READ, os.MAP.PRIVATE, kev.fd, 0) catch |err| {
                debug("Unable to mmap keymap fd: {s}\n", .{@errorName(err)});
                return;
            };
            defer os.munmap(keymap_str);

            const keymap = xkb.Keymap.newFromBuffer(
                state.xkb_context,
                keymap_str.ptr,
                keymap_str.len - 1,
                .text_v1,
                .no_flags,
            ) orelse {
                debug("Unable to get keymap\n", .{});
                return;
            };

            defer keymap.unref();
            const xkb_state = xkb.State.new(keymap) orelse {
                debug("Failed to create kb state\n", .{});
                return;
            };
            defer xkb_state.unref();
            if (state.xkb_state) |s| s.unref();
            state.xkb_state = xkb_state.ref();
        },
        .modifiers => |kev| {
            if (state.xkb_state) |kb_state| {
                _ = kb_state.updateMask(
                    kev.mods_depressed,
                    kev.mods_latched,
                    kev.mods_locked,
                    0,
                    0,
                    kev.group,
                );
            }
        },
        .key => |kev| {
            if (kev.state != .pressed) return;
            const kb_state = state.xkb_state orelse return;
            const keycode = kev.key + WL_XKB_KEYCODE_OFFSET;
            // const sym = kb_state.keyGetOneSym(keycode);
            // if (keysym == .NoSymbol) return;
            const keymap = kb_state.getKeymap();
            const name = keymap.keyGetName(keycode);
            debug("Got key: {?s}\n", .{name});
        },
    }
}

fn frameHandler(cb: *wl.Callback, event: wl.Callback.Event, data: *DisplayState) void {
    defer cb.destroy();
    switch (event) {
        .done => |evt| {
            const frameCb = data.frameData.surface.frame() catch |err| {
                fatal("Error getting callback: {any}\n", .{err});
            };
            frameCb.setListener(*DisplayState, frameHandler, data);

            if (data.frameData.lastFrame != 0) {
                const elapsed = evt.callback_data - data.frameData.lastFrame;
                const delta = @as(f32, @floatFromInt(elapsed)) / 1000.0 * 48.0;

                data.frameData.offset += delta;
            }

            const buffer = genBuffer(data) catch |err| {
                fatal("Could not generate a buffer in frame callback: {any}\n", .{err});
            };
            defer os.close(buffer.fd);
            fill(buffer.data, data, background);
            var surface = data.frameData.surface;
            surface.attach(buffer.buffer, 0, 0);
            surface.damage(0, 0, data.dimensions.width, data.dimensions.height);
            surface.commit();

            gradient(buffer.data, data, background);
            surface.attach(buffer.buffer, 0, 0);
            surface.damage(64, 64, data.dimensions.width - 128, data.dimensions.height - 128);
            surface.commit();

            data.frameData.lastFrame = evt.callback_data;
        },
    }
}

fn deviceChange(device: ?*anyopaque) void {
    std.log.info("A device change event happend: {?any}", .{device});
}

const pitch = 440.0;
const radians_per_second = pitch * 2.0 * std.math.pi;
var seconds_offset: f32 = 0.0;
fn writeCallback(user_data: ?*anyopaque, frames: usize) void {
    std.log.info("{d} audio frames: {?any}", .{ frames, user_data });
    if (user_data) |data| {
        const state: *AudioState = @alignCast(@ptrCast(data));
        if (state.player) |player| {
            const seconds_per_frame = 1.0 / @as(f32, @floatFromInt(player.sampleRate()));
            for (0..frames) |f| {
                const sample = std.math.sin((seconds_offset + @as(f32, @floatFromInt(f)) * seconds_per_frame) * radians_per_second);

                player.writeAll(f, sample);
            }
            seconds_offset = @mod(seconds_offset + seconds_per_frame * @as(f32, @floatFromInt(frames)), 1.0);
        }
    }
}
