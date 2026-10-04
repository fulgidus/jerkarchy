//! jerkslide — slide transition for sway workspace switches.
//!
//! sway has no animations (SwayFX only fades). jerkslide fakes a slide: it
//! covers the workspace area (below the bar) with two pictures side by side —
//! the workspace being left and the one being entered — says "ready", and
//! while sway switches underneath, moves both across until the new one sits
//! where the real one is; then it gets out of the way. Moving the pictures is
//! two subsurface position changes per frame, so it's cheap.
//!
//!   grim -g GEOMETRY -t ppm - | jerkslide OUTPUT left|right MS
//!       [--in FILE.ppm [--in-crop Y H]] [--save FILE.ppm] [--bg RRGGBB]
//!
//! stdin: the workspace being left. --in: a picture of the one being entered
//! (ws-go keeps one per workspace, saved here with --save when it's left;
//! --in-crop takes rows Y..Y+H, for a full-output wallpaper frame); without
//! it, a solid --bg. Prints "ready" when the overlay is up; the caller then
//! switches workspace (see ws-go). Exits when the slide is done.
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
    if (data.len < 2 or data[0] != 'P' or data[1] != '6') fatal("not a binary PPM (P6)", .{});
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

const Image = struct { w: usize, h: usize, px: []u32 };

/// PPM → XRGB pixels, keeping rows y0..y0+rows (all when rows == 0).
fn toImage(data: []const u8, y0: usize, rows: usize) Image {
    const p = parsePpm(data);
    const top = @min(y0, p.h - 1);
    const h = if (rows == 0) p.h - top else @min(rows, p.h - top);
    const px = std.heap.c_allocator.alloc(u32, p.w * h) catch fatal("out of memory", .{});
    for (0..h) |y| for (0..p.w) |x| {
        const k = ((top + y) * p.w + x) * 3;
        px[y * p.w + x] = 0xff000000 | (@as(u32, p.rgb[k]) << 16) | (@as(u32, p.rgb[k + 1]) << 8) | p.rgb[k + 2];
    };
    return .{ .w = p.w, .h = h, .px = px };
}

fn readFile(path: [*:0]const u8) ?[]u8 {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var list: std.ArrayList(u8) = .empty;
    var chunk: [1 << 16]u8 = undefined;
    while (true) {
        const n = c.read(fd, &chunk, chunk.len);
        if (n <= 0) break;
        list.appendSlice(std.heap.c_allocator, chunk[0..@intCast(n)]) catch return null;
    }
    return list.items;
}

/// Save a half-resolution PPM (it only has to survive a 200 ms slide, and
/// nine workspaces' worth stays small in RAM). Written to FILE.tmp, renamed.
fn saveHalf(img: Image, path: [*:0]const u8) void {
    const w = @max(1, img.w / 2);
    const h = @max(1, img.h / 2);
    var tmp_buf: [4096]u8 = undefined;
    const tmp = std.fmt.bufPrintZ(&tmp_buf, "{s}.tmp", .{std.mem.span(path)}) catch return;
    const fd = std.c.open(tmp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o600));
    if (fd < 0) return;
    var hdr: [64]u8 = undefined;
    const head = std.fmt.bufPrint(&hdr, "P6\n{d} {d}\n255\n", .{ w, h }) catch return;
    _ = c.write(fd, head.ptr, head.len);
    const row = std.heap.c_allocator.alloc(u8, w * 3) catch return;
    for (0..h) |y| {
        for (0..w) |x| {
            const p = img.px[(y * 2) * img.w + x * 2];
            row[x * 3] = @truncate(p >> 16);
            row[x * 3 + 1] = @truncate(p >> 8);
            row[x * 3 + 2] = @truncate(p);
        }
        _ = c.write(fd, row.ptr, row.len);
    }
    _ = c.close(fd);
    _ = std.c.rename(tmp.ptr, path);
}

fn easeInOutCubic(t: f64) f64 {
    return if (t < 0.5) 4 * t * t * t else 1 - std.math.pow(f64, -2 * t + 2, 3) / 2;
}

/// A subsurface of `parent` showing `img`, scaled to the area (cfg_w × cfg_h).
fn picture(parent: *c.wl_surface, empty: ?*c.wl_region, img: Image) *c.wl_subsurface {
    const b = shmBuffer(img.w, img.h, c.WL_SHM_FORMAT_XRGB8888);
    @memcpy(b.px, img.px);
    const surf = c.wl_compositor_create_surface(compositor) orelse fatal("create_surface", .{});
    c.wl_surface_set_input_region(surf, empty);
    const sub = c.wl_subcompositor_get_subsurface(subcompositor, surf, parent) orelse fatal("get_subsurface", .{});
    const vp = c.wp_viewporter_get_viewport(viewporter, surf);
    c.wp_viewport_set_destination(vp, cfg_w, cfg_h);
    c.wl_surface_attach(surf, b.buf, 0, 0);
    c.wl_surface_damage_buffer(surf, 0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
    c.wl_surface_commit(surf);
    return sub;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const args = init.args.vector;
    const usage = "usage: grim -g GEOMETRY -t ppm - | jerkslide OUTPUT left|right MS [--in FILE [--in-crop Y H]] [--save FILE] [--bg RRGGBB]";
    if (args.len < 4) fatal("{s}", .{usage});
    const out_name = std.mem.span(args[1]);
    const dir_arg = std.mem.span(args[2]);
    const dir: f64 = if (std.mem.eql(u8, dir_arg, "left")) -1 else if (std.mem.eql(u8, dir_arg, "right")) 1 else fatal("direction: left or right", .{});
    const ms = std.fmt.parseFloat(f64, std.mem.span(args[3])) catch fatal("bad MS", .{});
    const dur = std.math.clamp(ms, 50, 2000) / 1000;
    var in_path: ?[*:0]const u8 = null;
    var save_path: ?[*:0]const u8 = null;
    var crop_y: usize = 0;
    var crop_h: usize = 0;
    var bg: u32 = 0xff000000;
    var a: usize = 4;
    while (a < args.len) : (a += 1) {
        const k = std.mem.span(args[a]);
        if (a + 1 >= args.len) fatal("{s}", .{usage});
        if (std.mem.eql(u8, k, "--in")) {
            a += 1;
            in_path = args[a];
        } else if (std.mem.eql(u8, k, "--save")) {
            a += 1;
            save_path = args[a];
        } else if (std.mem.eql(u8, k, "--bg")) {
            a += 1;
            const v = std.mem.trimStart(u8, std.mem.span(args[a]), "#");
            bg = 0xff000000 | (std.fmt.parseInt(u32, v, 16) catch fatal("bad --bg", .{}));
        } else if (std.mem.eql(u8, k, "--in-crop") and a + 2 < args.len) {
            crop_y = std.fmt.parseInt(usize, std.mem.span(args[a + 1]), 10) catch fatal("bad --in-crop", .{});
            crop_h = std.fmt.parseInt(usize, std.mem.span(args[a + 2]), 10) catch fatal("bad --in-crop", .{});
            a += 2;
        } else fatal("{s}", .{usage});
    }

    const old = toImage(readStdin(), 0, 0);
    if (save_path) |sp| saveHalf(old, sp);
    const incoming: ?Image = if (in_path) |ip| (if (readFile(ip)) |d| toImage(d, crop_y, crop_h) else null) else null;

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

    // Parent: a click-through surface over the workspace area. Top layer with
    // exclusive zone 0, so it's laid out below the bar (which stays put) and
    // above windows. Holds one transparent pixel scaled up (layer surfaces
    // need a buffer to be mapped).
    const parent = c.wl_compositor_create_surface(compositor) orelse fatal("create_surface", .{});
    const empty = c.wl_compositor_create_region(compositor);
    c.wl_surface_set_input_region(parent, empty);
    const layer = c.zwlr_layer_shell_v1_get_layer_surface(layer_shell, parent, output, c.ZWLR_LAYER_SHELL_V1_LAYER_TOP, "jerkslide");
    _ = c.zwlr_layer_surface_v1_add_listener(layer, &layer_listener, null);
    c.zwlr_layer_surface_v1_set_anchor(layer, c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
        c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
    c.zwlr_layer_surface_v1_set_exclusive_zone(layer, 0);
    c.wl_surface_commit(parent);
    while (!configured and !closed) if (c.wl_display_dispatch(display) < 0) fatal("lost the compositor", .{});
    if (closed or cfg_w <= 0 or cfg_h <= 0) fatal("overlay was refused", .{});

    const clear = shmBuffer(1, 1, c.WL_SHM_FORMAT_ARGB8888);
    clear.px[0] = 0;
    const pvp = c.wp_viewporter_get_viewport(viewporter, parent);
    c.wp_viewport_set_destination(pvp, cfg_w, cfg_h);
    c.wl_surface_attach(parent, clear.buf, 0, 0);

    // Children: the two pictures, any resolution, shown at the area's size.
    const sub_old = picture(parent, empty, old);
    const sub_new = if (incoming) |im| picture(parent, empty, im) else picture(parent, empty, .{ .w = 1, .h = 1, .px = @constCast(&[_]u32{bg}) });
    c.wl_region_destroy(empty);
    const w_f: f64 = @floatFromInt(cfg_w);
    c.wl_subsurface_set_position(sub_old, 0, 0);
    c.wl_subsurface_set_position(sub_new, @intFromFloat(-dir * w_f), 0);
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
        const dx = dir * easeInOutCubic(t) * w_f;
        c.wl_subsurface_set_position(sub_old, @intFromFloat(dx), 0);
        c.wl_subsurface_set_position(sub_new, @intFromFloat(dx - dir * w_f), 0);
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
