//! jerkslide — slide transition for sway workspace switches.
//!
//! sway has no animations (SwayFX only fades). jerkslide fakes a slide: it
//! shows a screenshot of the workspace being left as a click-through overlay,
//! says "ready" once that's on screen, and then — while sway switches to the
//! new workspace underneath — slides the screenshot off the output. Moving
//! the picture is one subsurface position change per frame, so it's cheap.
//!
//!   grim -o OUTPUT -t ppm - | jerkslide OUTPUT left|right [MS]
//!
//! Prints "ready" on stdout when the overlay is up; the caller then switches
//! workspace (see ws-go). Exits when the slide is done, or after a timeout.
const std = @import("std");
const c = @cImport({
    @cDefine("_GNU_SOURCE", {}); // memfd_create
    @cInclude("wayland-client.h");
    @cInclude("wlr-layer-shell-unstable-v1-client-protocol.h");
    @cInclude("viewporter-client-protocol.h");
    @cInclude("sys/mman.h");
    @cInclude("poll.h");
    @cInclude("unistd.h");
    @cInclude("time.h");
});

var compositor: ?*c.wl_compositor = null;
var subcompositor: ?*c.wl_subcompositor = null;
var shm: ?*c.wl_shm = null;
var layer_shell: ?*c.zwlr_layer_shell_v1 = null;
var viewporter: ?*c.wp_viewporter = null;

const Out = struct { wl: *c.wl_output, name: [64]u8 = undefined, name_len: usize = 0 };
var outs: [16]Out = undefined;
var n_outs: usize = 0;

var cfg_w: i32 = 0;
var cfg_h: i32 = 0;
var configured = false;
var closed = false;
var frame_done = false;

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("jerkslide: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn now() f64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(f64, @floatFromInt(ts.tv_sec)) + @as(f64, @floatFromInt(ts.tv_nsec)) / 1e9;
}

fn outGeometry(_: ?*anyopaque, _: ?*c.wl_output, _: i32, _: i32, _: i32, _: i32, _: i32, _: [*c]const u8, _: [*c]const u8, _: i32) callconv(.c) void {}
fn outMode(_: ?*anyopaque, _: ?*c.wl_output, _: u32, _: i32, _: i32, _: i32) callconv(.c) void {}
fn outDone(_: ?*anyopaque, _: ?*c.wl_output) callconv(.c) void {}
fn outScale(_: ?*anyopaque, _: ?*c.wl_output, _: i32) callconv(.c) void {}
fn outName(data: ?*anyopaque, _: ?*c.wl_output, name: [*c]const u8) callconv(.c) void {
    const o: *Out = @ptrCast(@alignCast(data));
    const s = std.mem.span(name);
    o.name_len = @min(s.len, o.name.len);
    @memcpy(o.name[0..o.name_len], s[0..o.name_len]);
}
fn outDescription(_: ?*anyopaque, _: ?*c.wl_output, _: [*c]const u8) callconv(.c) void {}
const output_listener = c.wl_output_listener{
    .geometry = outGeometry,
    .mode = outMode,
    .done = outDone,
    .scale = outScale,
    .name = outName,
    .description = outDescription,
};

fn global(_: ?*anyopaque, reg: ?*c.wl_registry, name: u32, iface: [*c]const u8, version: u32) callconv(.c) void {
    const i = std.mem.span(iface);
    if (std.mem.eql(u8, i, "wl_compositor")) {
        compositor = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_compositor_interface, @min(version, 4)));
    } else if (std.mem.eql(u8, i, "wl_subcompositor")) {
        subcompositor = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_subcompositor_interface, 1));
    } else if (std.mem.eql(u8, i, "wl_shm")) {
        shm = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_shm_interface, 1));
    } else if (std.mem.eql(u8, i, "zwlr_layer_shell_v1")) {
        layer_shell = @ptrCast(c.wl_registry_bind(reg, name, &c.zwlr_layer_shell_v1_interface, @min(version, 4)));
    } else if (std.mem.eql(u8, i, "wp_viewporter")) {
        viewporter = @ptrCast(c.wl_registry_bind(reg, name, &c.wp_viewporter_interface, 1));
    } else if (std.mem.eql(u8, i, "wl_output") and version >= 4 and n_outs < outs.len) {
        const wo: *c.wl_output = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_output_interface, 4) orelse return);
        outs[n_outs] = .{ .wl = wo };
        _ = c.wl_output_add_listener(wo, &output_listener, &outs[n_outs]);
        n_outs += 1;
    }
}
fn globalRemove(_: ?*anyopaque, _: ?*c.wl_registry, _: u32) callconv(.c) void {}
const registry_listener = c.wl_registry_listener{ .global = global, .global_remove = globalRemove };

fn layerConfigure(_: ?*anyopaque, ls: ?*c.zwlr_layer_surface_v1, serial: u32, w: u32, h: u32) callconv(.c) void {
    c.zwlr_layer_surface_v1_ack_configure(ls, serial);
    cfg_w = @intCast(w);
    cfg_h = @intCast(h);
    configured = true;
}
fn layerClosed(_: ?*anyopaque, _: ?*c.zwlr_layer_surface_v1) callconv(.c) void {
    closed = true;
}
const layer_listener = c.zwlr_layer_surface_v1_listener{ .configure = layerConfigure, .closed = layerClosed };

fn frameDone(_: ?*anyopaque, cb: ?*c.wl_callback, _: u32) callconv(.c) void {
    c.wl_callback_destroy(cb);
    frame_done = true;
}
const frame_listener = c.wl_callback_listener{ .done = frameDone };

/// A wl_shm buffer of w×h pixels; returns the buffer and its pixels.
fn shmBuffer(w: usize, h: usize, format: u32) struct { buf: *c.wl_buffer, px: []u32 } {
    const size = w * h * 4;
    const fd = c.memfd_create("jerkslide", c.MFD_CLOEXEC);
    if (fd < 0) fatal("memfd_create failed", .{});
    defer _ = c.close(fd);
    if (c.ftruncate(fd, @intCast(size)) != 0) fatal("ftruncate failed", .{});
    const ptr = c.mmap(null, size, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
    if (ptr == c.MAP_FAILED) fatal("mmap failed", .{});
    const pool = c.wl_shm_create_pool(shm, fd, @intCast(size));
    defer c.wl_shm_pool_destroy(pool);
    const buf = c.wl_shm_pool_create_buffer(pool, 0, @intCast(w), @intCast(h), @intCast(w * 4), format) orelse fatal("create_buffer failed", .{});
    return .{ .buf = buf, .px = @as([*]u32, @ptrCast(@alignCast(ptr)))[0 .. w * h] };
}

/// Read all of stdin (grim's PPM can be ~6 MB at 1080p, ~25 MB at 4K).
fn readStdin() []u8 {
    var list: std.ArrayList(u8) = .empty;
    var chunk: [1 << 16]u8 = undefined;
    while (true) {
        const n = c.read(0, &chunk, chunk.len);
        if (n < 0) fatal("reading stdin failed", .{});
        if (n == 0) break;
        list.appendSlice(std.heap.c_allocator, chunk[0..@intCast(n)]) catch fatal("out of memory", .{});
    }
    return list.items;
}

/// Parse a binary PPM (P6, maxval 255): returns width, height and the RGB data.
fn parsePpm(data: []const u8) struct { w: usize, h: usize, rgb: []const u8 } {
    var pos: usize = 0;
    var fields: [4]usize = undefined;
    var nf: usize = 0;
    if (data.len < 2 or data[0] != 'P' or data[1] != '6') fatal("stdin isn't a binary PPM (grim -t ppm)", .{});
    pos = 2;
    while (nf < 3) {
        while (pos < data.len and std.ascii.isWhitespace(data[pos])) pos += 1;
        if (pos < data.len and data[pos] == '#') {
            while (pos < data.len and data[pos] != '\n') pos += 1;
            continue;
        }
        const start = pos;
        while (pos < data.len and std.ascii.isDigit(data[pos])) pos += 1;
        if (start == pos) fatal("bad PPM header", .{});
        fields[nf] = std.fmt.parseInt(usize, data[start..pos], 10) catch fatal("bad PPM header", .{});
        nf += 1;
    }
    pos += 1; // the single whitespace after maxval
    const w = fields[0];
    const h = fields[1];
    if (fields[2] != 255 or w == 0 or h == 0 or data.len < pos + w * h * 3) fatal("unsupported PPM", .{});
    return .{ .w = w, .h = h, .rgb = data[pos .. pos + w * h * 3] };
}

fn easeInOutCubic(t: f64) f64 {
    return if (t < 0.5) 4 * t * t * t else 1 - std.math.pow(f64, -2 * t + 2, 3) / 2;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const args = init.args.vector;
    if (args.len < 3) fatal("usage: grim -o OUTPUT -t ppm - | jerkslide OUTPUT left|right [MS]", .{});
    const out_name = std.mem.span(args[1]);
    const dir_arg = std.mem.span(args[2]);
    const dir: f64 = if (std.mem.eql(u8, dir_arg, "left")) -1 else if (std.mem.eql(u8, dir_arg, "right")) 1 else fatal("direction: left or right", .{});
    const ms: f64 = if (args.len > 3) std.fmt.parseFloat(f64, std.mem.span(args[3])) catch fatal("bad MS", .{}) else 220;
    const dur = std.math.clamp(ms, 50, 2000) / 1000;

    const img = parsePpm(readStdin());

    const display = c.wl_display_connect(null) orelse fatal("cannot connect to Wayland display", .{});
    const reg = c.wl_display_get_registry(display);
    _ = c.wl_registry_add_listener(reg, &registry_listener, null);
    _ = c.wl_display_roundtrip(display);
    _ = c.wl_display_roundtrip(display); // output names
    if (compositor == null or subcompositor == null or shm == null or layer_shell == null or viewporter == null)
        fatal("compositor lacks a needed global (wl_subcompositor, wp_viewporter, layer shell)", .{});
    var output: ?*c.wl_output = null;
    for (outs[0..n_outs]) |*o| {
        if (std.mem.eql(u8, o.name[0..o.name_len], out_name)) output = o.wl;
    }
    if (output == null) fatal("no output named {s}", .{out_name});

    // Parent: a full-output, click-through overlay holding one transparent
    // pixel scaled up (layer surfaces need a buffer to be mapped).
    const parent = c.wl_compositor_create_surface(compositor) orelse fatal("create_surface", .{});
    const empty = c.wl_compositor_create_region(compositor);
    c.wl_surface_set_input_region(parent, empty);
    const layer = c.zwlr_layer_shell_v1_get_layer_surface(layer_shell, parent, output, c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "jerkslide");
    _ = c.zwlr_layer_surface_v1_add_listener(layer, &layer_listener, null);
    c.zwlr_layer_surface_v1_set_anchor(layer, c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
        c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
    c.zwlr_layer_surface_v1_set_exclusive_zone(layer, -1);
    c.wl_surface_commit(parent);
    while (!configured and !closed) if (c.wl_display_dispatch(display) < 0) fatal("lost the compositor", .{});
    if (closed or cfg_w <= 0 or cfg_h <= 0) fatal("overlay was refused", .{});

    const clear = shmBuffer(1, 1, c.WL_SHM_FORMAT_ARGB8888);
    clear.px[0] = 0;
    const pvp = c.wp_viewporter_get_viewport(viewporter, parent);
    c.wp_viewport_set_destination(pvp, cfg_w, cfg_h);
    c.wl_surface_attach(parent, clear.buf, 0, 0);

    // Child: the screenshot, physical pixels shown at the output's logical size.
    const shot = shmBuffer(img.w, img.h, c.WL_SHM_FORMAT_XRGB8888);
    for (shot.px, 0..) |*p, k| {
        const r: u32 = img.rgb[k * 3];
        const g: u32 = img.rgb[k * 3 + 1];
        const b: u32 = img.rgb[k * 3 + 2];
        p.* = 0xff000000 | (r << 16) | (g << 8) | b;
    }
    const child = c.wl_compositor_create_surface(compositor) orelse fatal("create_surface", .{});
    c.wl_surface_set_input_region(child, empty);
    c.wl_region_destroy(empty);
    const sub = c.wl_subcompositor_get_subsurface(subcompositor, child, parent);
    const cvp = c.wp_viewporter_get_viewport(viewporter, child);
    c.wp_viewport_set_destination(cvp, cfg_w, cfg_h);
    c.wl_surface_attach(child, shot.buf, 0, 0);
    c.wl_surface_damage_buffer(child, 0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
    c.wl_surface_commit(child);
    c.wl_subsurface_set_position(sub, 0, 0);
    _ = c.wl_callback_add_listener(c.wl_surface_frame(parent), &frame_listener, null);
    c.wl_surface_damage_buffer(parent, 0, 0, 1, 1);
    c.wl_surface_commit(parent);

    // Wait until the overlay has been shown, then let the caller switch. The
    // roundtrip guarantees the compositor has the commit; a frame callback
    // (when the output repaints promptly) confirms it was drawn.
    _ = c.wl_display_roundtrip(display);
    const deadline = now() + 0.04;
    while (!frame_done and now() < deadline) {
        _ = c.wl_display_flush(display);
        var pfd = c.struct_pollfd{ .fd = c.wl_display_get_fd(display), .events = c.POLLIN, .revents = 0 };
        if (c.poll(&pfd, 1, 20) > 0) {
            if (c.wl_display_dispatch(display) < 0) fatal("lost the compositor", .{});
        } else _ = c.wl_display_dispatch_pending(display);
    }
    _ = c.write(1, "ready\n", 6);
    _ = c.usleep(25_000); // the switch lands underneath

    // Slide: one subsurface move per frame (frame callbacks, 16 ms fallback).
    const t0 = now();
    while (true) {
        const t = std.math.clamp((now() - t0) / dur, 0, 1);
        const dx: i32 = @intFromFloat(dir * easeInOutCubic(t) * @as(f64, @floatFromInt(cfg_w)));
        c.wl_subsurface_set_position(sub, dx, 0);
        frame_done = false;
        _ = c.wl_callback_add_listener(c.wl_surface_frame(parent), &frame_listener, null);
        c.wl_surface_commit(parent);
        _ = c.wl_display_flush(display);
        if (t >= 1) break;
        const until = now() + 0.016;
        while (!frame_done and now() < until) {
            var pfd = c.struct_pollfd{ .fd = c.wl_display_get_fd(display), .events = c.POLLIN, .revents = 0 };
            if (c.poll(&pfd, 1, 4) > 0) {
                if (c.wl_display_dispatch(display) < 0) fatal("lost the compositor", .{});
            }
        }
    }
    _ = c.wl_display_roundtrip(display);
}
