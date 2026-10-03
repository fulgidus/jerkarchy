//! jerkwall — live Delaunay wallpaper for wlroots compositors (sway).
//!
//! Slowly drifting points are triangulated (Bowyer–Watson, the same mesh
//! d3-delaunay draws) and each triangle is filled with a subtle mix of the
//! background and two accent colours, driven by a slowly moving noise field
//! whose hue wanders over minutes. Drawn on the CPU into shared memory on the
//! layer-shell *background* layer, a few frames per second: no GPU, little power.
//!
//!   jerkwall [--fps N] [--points N] [--speed X] [--bg RRGGBB] [--a RRGGBB] [--b RRGGBB]
//!
//! --fps defaults to 4; with the power-saver profile (platform_profile
//! low-power / quiet / cool) it drops to at most 1.
//! Defaults match jerkarchy's palette: bg 0a0a0f, a 00f0ff (cyan), b ff2b6d (magenta).

const std = @import("std");
const c = @cImport({
    @cDefine("_GNU_SOURCE", {}); // memfd_create
    @cInclude("wayland-client.h");
    @cInclude("wlr-layer-shell-unstable-v1-client-protocol.h");
    @cInclude("sys/mman.h");
    @cInclude("poll.h");
    @cInclude("unistd.h");
    @cInclude("time.h");
    @cInclude("fcntl.h");
});

const gpa = std.heap.c_allocator;

// ---------------------------------------------------------------- options

const Rgb = struct { r: f64, g: f64, b: f64 };

var opt_fps: f64 = 4;
var opt_points: usize = 140;
var opt_speed: f64 = 1.0;
var col_bg: Rgb = hex(0x0a0a0f);
var col_a: Rgb = hex(0x00f0ff);
var col_b: Rgb = hex(0xff2b6d);

fn hex(v: u32) Rgb {
    return .{
        .r = @as(f64, @floatFromInt((v >> 16) & 0xff)) / 255.0,
        .g = @as(f64, @floatFromInt((v >> 8) & 0xff)) / 255.0,
        .b = @as(f64, @floatFromInt(v & 0xff)) / 255.0,
    };
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("jerkwall: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn usage() noreturn {
    std.debug.print("usage: jerkwall [--fps N] [--points N] [--speed X] [--bg RRGGBB] [--a RRGGBB] [--b RRGGBB]\n", .{});
    std.process.exit(2);
}

// ---------------------------------------------------------------- scene

const Pt = struct { x: f64, y: f64, vx: f64 = 0, vy: f64 = 0, fixed: bool = false };

var points: std.ArrayList(Pt) = .empty;
var scene_time: f64 = 0;

fn initScene() !void {
    var prng = std.Random.DefaultPrng.init(@intFromFloat(@mod(now() * 1000.0, 2147483647.0)));
    const rnd = prng.random();
    // Fixed points on the border so the mesh always covers the whole screen.
    const per_side = 7;
    for (0..per_side + 1) |i| {
        const t = @as(f64, @floatFromInt(i)) / per_side;
        try points.append(gpa, .{ .x = t, .y = 0, .fixed = true });
        try points.append(gpa, .{ .x = t, .y = 1, .fixed = true });
        if (i != 0 and i != per_side) {
            try points.append(gpa, .{ .x = 0, .y = t, .fixed = true });
            try points.append(gpa, .{ .x = 1, .y = t, .fixed = true });
        }
    }
    for (0..opt_points) |_| {
        const ang = rnd.float(f64) * std.math.tau;
        const spd = (0.004 + rnd.float(f64) * 0.008) * opt_speed; // screen widths per second
        try points.append(gpa, .{
            .x = 0.02 + rnd.float(f64) * 0.96,
            .y = 0.02 + rnd.float(f64) * 0.96,
            .vx = @cos(ang) * spd,
            .vy = @sin(ang) * spd,
        });
    }
}

fn stepScene(dt: f64) void {
    scene_time += dt;
    for (points.items) |*p| {
        if (p.fixed) continue;
        p.x += p.vx * dt;
        p.y += p.vy * dt;
        if (p.x < 0.01) { p.x = 0.01; p.vx = @abs(p.vx); }
        if (p.x > 0.99) { p.x = 0.99; p.vx = -@abs(p.vx); }
        if (p.y < 0.01) { p.y = 0.01; p.vy = @abs(p.vy); }
        if (p.y > 0.99) { p.y = 0.99; p.vy = -@abs(p.vy); }
    }
}

// ---------------------------------------------------------------- Delaunay (Bowyer–Watson)

const V = struct { x: f64, y: f64 };
const Tri = struct { a: u32, b: u32, c: u32, cx: f64, cy: f64, r2: f64 };

fn circum(vs: []const V, a: u32, b: u32, cc: u32) Tri {
    const A = vs[a];
    const B = vs[b];
    const C = vs[cc];
    const d = 2 * (A.x * (B.y - C.y) + B.x * (C.y - A.y) + C.x * (A.y - B.y));
    if (@abs(d) < 1e-12) return .{ .a = a, .b = b, .c = cc, .cx = 0, .cy = 0, .r2 = std.math.inf(f64) };
    const a2 = A.x * A.x + A.y * A.y;
    const b2 = B.x * B.x + B.y * B.y;
    const c2 = C.x * C.x + C.y * C.y;
    const ux = (a2 * (B.y - C.y) + b2 * (C.y - A.y) + c2 * (A.y - B.y)) / d;
    const uy = (a2 * (C.x - B.x) + b2 * (A.x - C.x) + c2 * (B.x - A.x)) / d;
    const dx = A.x - ux;
    const dy = A.y - uy;
    return .{ .a = a, .b = b, .c = cc, .cx = ux, .cy = uy, .r2 = dx * dx + dy * dy };
}

/// Triangulates `pts` (in pixels). Returned triangles index into `pts`.
fn triangulate(pts: []const V, out: *std.ArrayList(Tri)) !void {
    const n: u32 = @intCast(pts.len);
    var vs: std.ArrayList(V) = .empty;
    defer vs.deinit(gpa);
    try vs.appendSlice(gpa, pts);
    // Super-triangle far outside the screen.
    var minx: f64 = std.math.inf(f64);
    var miny: f64 = std.math.inf(f64);
    var maxx: f64 = -std.math.inf(f64);
    var maxy: f64 = -std.math.inf(f64);
    for (pts) |p| {
        minx = @min(minx, p.x); miny = @min(miny, p.y);
        maxx = @max(maxx, p.x); maxy = @max(maxy, p.y);
    }
    const span = @max(maxx - minx, maxy - miny) * 20;
    const mx = (minx + maxx) / 2;
    const my = (miny + maxy) / 2;
    try vs.append(gpa, .{ .x = mx - span, .y = my - span });
    try vs.append(gpa, .{ .x = mx + span, .y = my - span });
    try vs.append(gpa, .{ .x = mx, .y = my + span });

    var tris: std.ArrayList(Tri) = .empty;
    defer tris.deinit(gpa);
    try tris.append(gpa, circum(vs.items, n, n + 1, n + 2));

    const Edge = struct { a: u32, b: u32 };
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);

    for (0..n) |ii| {
        const i: u32 = @intCast(ii);
        const p = vs.items[i];
        edges.clearRetainingCapacity();
        var t: usize = 0;
        while (t < tris.items.len) {
            const tr = tris.items[t];
            const dx = p.x - tr.cx;
            const dy = p.y - tr.cy;
            if (dx * dx + dy * dy <= tr.r2) {
                try edges.append(gpa, .{ .a = tr.a, .b = tr.b });
                try edges.append(gpa, .{ .a = tr.b, .b = tr.c });
                try edges.append(gpa, .{ .a = tr.c, .b = tr.a });
                _ = tris.swapRemove(t);
            } else t += 1;
        }
        // Keep only boundary edges of the cavity (those not shared twice).
        var e: usize = 0;
        while (e < edges.items.len) : (e += 1) {
            const ea = edges.items[e];
            var dup = false;
            var f: usize = 0;
            while (f < edges.items.len) : (f += 1) {
                if (f == e) continue;
                const eb = edges.items[f];
                if ((ea.a == eb.a and ea.b == eb.b) or (ea.a == eb.b and ea.b == eb.a)) { dup = true; break; }
            }
            if (!dup) try tris.append(gpa, circum(vs.items, ea.a, ea.b, i));
        }
    }
    out.clearRetainingCapacity();
    for (tris.items) |tr| {
        if (tr.a >= n or tr.b >= n or tr.c >= n) continue;
        try out.append(gpa, tr);
    }
}

// ---------------------------------------------------------------- colour

fn mix(x: Rgb, y: Rgb, t: f64) Rgb {
    return .{ .r = x.r + (y.r - x.r) * t, .g = x.g + (y.g - x.g) * t, .b = x.b + (y.b - x.b) * t };
}

fn pack(col: Rgb) u32 {
    const r: u32 = @intFromFloat(std.math.clamp(col.r, 0, 1) * 255.0 + 0.5);
    const g: u32 = @intFromFloat(std.math.clamp(col.g, 0, 1) * 255.0 + 0.5);
    const b: u32 = @intFromFloat(std.math.clamp(col.b, 0, 1) * 255.0 + 0.5);
    return 0xff000000 | (r << 16) | (g << 8) | b;
}

/// Colour of a triangle with centroid (u, v) in [0,1]² at time t.
fn facet(u: f64, v: f64, t: f64) u32 {
    // Slow noise field → how much accent shows (mostly dark, subtle).
    const n1 = 0.5 + 0.5 * @sin(u * 3.1 + t * 0.07) * @cos(v * 2.3 - t * 0.05);
    const n2 = 0.5 + 0.5 * @sin((u + v) * 4.0 - t * 0.11);
    const k = 0.035 + 0.17 * n1 * n2;
    // Hue wanders between the two accents over minutes, varying across the screen.
    const h = 0.5 + 0.5 * @sin(t * 0.013 + u * 1.7 - v * 1.1);
    return pack(mix(col_bg, mix(col_a, col_b, h), k));
}

// ---------------------------------------------------------------- raster

/// Flat-fill a triangle with horizontal spans: per pixel row, intersect the
/// row's centre line with the three edges and memset the covered run.
fn fillTri(px: []u32, w: usize, h: usize, a: V, b: V, cc: V, color: u32) void {
    const ys = [3]V{ a, b, cc };
    const ymin = @max(0, @floor(@min(a.y, @min(b.y, cc.y))));
    const ymax = @min(@as(f64, @floatFromInt(h)) - 1, @ceil(@max(a.y, @max(b.y, cc.y))));
    if (ymin > ymax) return;
    const fw: f64 = @floatFromInt(w);
    var y: usize = @intFromFloat(ymin);
    const y_end: usize = @intFromFloat(ymax);
    while (y <= y_end) : (y += 1) {
        const fy = @as(f64, @floatFromInt(y)) + 0.5;
        var lo: f64 = std.math.inf(f64);
        var hi: f64 = -std.math.inf(f64);
        for (0..3) |e| {
            const p = ys[e];
            const q = ys[(e + 1) % 3];
            if ((p.y <= fy and q.y > fy) or (q.y <= fy and p.y > fy)) {
                const x = p.x + (fy - p.y) * (q.x - p.x) / (q.y - p.y);
                lo = @min(lo, x);
                hi = @max(hi, x);
            }
        }
        if (lo > hi) continue;
        // Pixels whose centre lies inside [lo, hi).
        const x0f = @max(0, @ceil(lo - 0.5));
        const x1f = @min(fw, @ceil(hi - 0.5));
        if (x1f <= x0f) continue;
        const x0: usize = @intFromFloat(x0f);
        const x1: usize = @intFromFloat(x1f);
        @memset(px[y * w + x0 .. y * w + x1], color);
    }
}

// ---------------------------------------------------------------- wayland state

var compositor: ?*c.wl_compositor = null;
var shm: ?*c.wl_shm = null;
var layer_shell: ?*c.zwlr_layer_shell_v1 = null;

const Buffer = struct {
    wl: ?*c.wl_buffer = null,
    data: []u32 = &.{},
    width: usize = 0,
    height: usize = 0,
    busy: bool = false,
};

const Output = struct {
    global_name: u32,
    wl_output: *c.wl_output,
    scale: i32 = 1,
    surface: ?*c.wl_surface = null,
    layer: ?*c.zwlr_layer_surface_v1 = null,
    width: u32 = 0, // logical
    height: u32 = 0,
    configured: bool = false,
    buffers: [2]Buffer = .{ .{}, .{} },
    tris: std.ArrayList(Tri) = .empty,
    verts: std.ArrayList(V) = .empty,
};

var outputs: std.ArrayList(*Output) = .empty;

fn bufferRelease(data: ?*anyopaque, _: ?*c.wl_buffer) callconv(.c) void {
    const b: *Buffer = @ptrCast(@alignCast(data));
    b.busy = false;
}
const buffer_listener = c.wl_buffer_listener{ .release = bufferRelease };

fn ensureBuffer(b: *Buffer, w: usize, h: usize) !void {
    if (b.wl != null and b.width == w and b.height == h) return;
    if (b.wl) |old| {
        c.wl_buffer_destroy(old);
        _ = c.munmap(b.data.ptr, b.data.len * 4);
        b.wl = null;
    }
    const size = w * h * 4;
    const fd = c.memfd_create("jerkwall", c.MFD_CLOEXEC);
    if (fd < 0) return error.MemfdFailed;
    defer _ = c.close(fd);
    if (c.ftruncate(fd, @intCast(size)) != 0) return error.TruncateFailed;
    const ptr = c.mmap(null, size, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
    if (ptr == c.MAP_FAILED) return error.MmapFailed;
    const pool = c.wl_shm_create_pool(shm, fd, @intCast(size));
    defer c.wl_shm_pool_destroy(pool);
    b.wl = c.wl_shm_pool_create_buffer(pool, 0, @intCast(w), @intCast(h), @intCast(w * 4), c.WL_SHM_FORMAT_XRGB8888);
    _ = c.wl_buffer_add_listener(b.wl, &buffer_listener, b);
    b.data = @as([*]u32, @ptrCast(@alignCast(ptr)))[0 .. w * h];
    b.width = w;
    b.height = h;
    b.busy = false;
}

fn render(out: *Output) void {
    if (!out.configured or out.width == 0 or out.height == 0) return;
    const scale: usize = @intCast(@max(1, out.scale));
    const w = out.width * scale;
    const h = out.height * scale;
    const buf = for (&out.buffers) |*b| {
        if (!b.busy) break b;
    } else return; // both in use by the compositor; skip this frame
    ensureBuffer(buf, w, h) catch |err| fatal("buffer: {s}", .{@errorName(err)});

    const fw: f64 = @floatFromInt(w);
    const fh: f64 = @floatFromInt(h);
    out.verts.clearRetainingCapacity();
    for (points.items) |p| out.verts.append(gpa, .{ .x = p.x * fw, .y = p.y * fh }) catch return;
    triangulate(out.verts.items, &out.tris) catch return;

    @memset(buf.data, pack(col_bg));
    for (out.tris.items) |tr| {
        const a = out.verts.items[tr.a];
        const b = out.verts.items[tr.b];
        const cc = out.verts.items[tr.c];
        const u = (a.x + b.x + cc.x) / (3 * fw);
        const v = (a.y + b.y + cc.y) / (3 * fh);
        fillTri(buf.data, w, h, a, b, cc, facet(u, v, scene_time));
    }

    c.wl_surface_set_buffer_scale(out.surface, @intCast(scale));
    c.wl_surface_attach(out.surface, buf.wl, 0, 0);
    c.wl_surface_damage_buffer(out.surface, 0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
    c.wl_surface_commit(out.surface);
    buf.busy = true;
}

fn layerConfigure(data: ?*anyopaque, ls: ?*c.zwlr_layer_surface_v1, serial: u32, w: u32, h: u32) callconv(.c) void {
    const out: *Output = @ptrCast(@alignCast(data));
    c.zwlr_layer_surface_v1_ack_configure(ls, serial);
    out.width = w;
    out.height = h;
    out.configured = true;
    render(out);
}
fn layerClosed(data: ?*anyopaque, _: ?*c.zwlr_layer_surface_v1) callconv(.c) void {
    const out: *Output = @ptrCast(@alignCast(data));
    out.configured = false;
}
const layer_listener = c.zwlr_layer_surface_v1_listener{ .configure = layerConfigure, .closed = layerClosed };

fn outGeometry(_: ?*anyopaque, _: ?*c.wl_output, _: i32, _: i32, _: i32, _: i32, _: i32, _: [*c]const u8, _: [*c]const u8, _: i32) callconv(.c) void {}
fn outMode(_: ?*anyopaque, _: ?*c.wl_output, _: u32, _: i32, _: i32, _: i32) callconv(.c) void {}
fn outDone(data: ?*anyopaque, _: ?*c.wl_output) callconv(.c) void {
    render(@ptrCast(@alignCast(data)));
}
fn outScale(data: ?*anyopaque, _: ?*c.wl_output, factor: i32) callconv(.c) void {
    const out: *Output = @ptrCast(@alignCast(data));
    out.scale = factor;
}
const output_listener = c.wl_output_listener{
    .geometry = outGeometry,
    .mode = outMode,
    .done = outDone,
    .scale = outScale,
    .name = null,
    .description = null,
};

fn setupOutput(out: *Output) void {
    if (out.surface != null) return;
    const comp = compositor orelse return;
    const shell = layer_shell orelse return;
    out.surface = c.wl_compositor_create_surface(comp);
    // Input-transparent: an empty input region passes clicks to the desktop.
    const region = c.wl_compositor_create_region(comp);
    c.wl_surface_set_input_region(out.surface, region);
    c.wl_region_destroy(region);
    out.layer = c.zwlr_layer_shell_v1_get_layer_surface(shell, out.surface, out.wl_output, c.ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND, "wallpaper");
    _ = c.zwlr_layer_surface_v1_add_listener(out.layer, &layer_listener, out);
    c.zwlr_layer_surface_v1_set_anchor(out.layer, c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
        c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
    c.zwlr_layer_surface_v1_set_size(out.layer, 0, 0);
    c.zwlr_layer_surface_v1_set_exclusive_zone(out.layer, -1);
    c.wl_surface_commit(out.surface);
}

fn registryGlobal(_: ?*anyopaque, reg: ?*c.wl_registry, name: u32, iface: [*c]const u8, version: u32) callconv(.c) void {
    const i = std.mem.span(iface);
    if (std.mem.eql(u8, i, "wl_compositor")) {
        compositor = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_compositor_interface, @min(version, 4)));
    } else if (std.mem.eql(u8, i, "wl_shm")) {
        shm = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_shm_interface, 1));
    } else if (std.mem.eql(u8, i, "zwlr_layer_shell_v1")) {
        layer_shell = @ptrCast(c.wl_registry_bind(reg, name, &c.zwlr_layer_shell_v1_interface, @min(version, 4)));
    } else if (std.mem.eql(u8, i, "wl_output")) {
        const wo: *c.wl_output = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_output_interface, @min(version, 3)) orelse return);
        const out = gpa.create(Output) catch fatal("out of memory", .{});
        out.* = .{ .global_name = name, .wl_output = wo };
        _ = c.wl_output_add_listener(wo, &output_listener, out);
        outputs.append(gpa, out) catch fatal("out of memory", .{});
        setupOutput(out);
    }
}

fn registryRemove(_: ?*anyopaque, _: ?*c.wl_registry, name: u32) callconv(.c) void {
    for (outputs.items, 0..) |out, idx| {
        if (out.global_name != name) continue;
        if (out.layer) |l| c.zwlr_layer_surface_v1_destroy(l);
        if (out.surface) |s| c.wl_surface_destroy(s);
        for (&out.buffers) |*b| if (b.wl) |wb| {
            c.wl_buffer_destroy(wb);
            _ = c.munmap(b.data.ptr, b.data.len * 4);
        };
        out.tris.deinit(gpa);
        out.verts.deinit(gpa);
        c.wl_output_destroy(out.wl_output);
        gpa.destroy(out);
        _ = outputs.swapRemove(idx);
        return;
    }
}
const registry_listener = c.wl_registry_listener{ .global = registryGlobal, .global_remove = registryRemove };

/// True when the firmware power profile is a power-saving one
/// (power-profiles-daemon's "power-saver"). Cheap sysfs read; absent → false.
fn lowPower() bool {
    const fd = c.open("/sys/firmware/acpi/platform_profile", c.O_RDONLY);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    var buf: [32]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return false;
    // power-profiles-daemon maps power-saver to "low-power" where the
    // firmware has it, otherwise to "quiet" (e.g. Dell Latitude) or "cool".
    const v = buf[0..@intCast(n)];
    return std.mem.startsWith(u8, v, "low-power") or std.mem.startsWith(u8, v, "quiet") or
        std.mem.startsWith(u8, v, "cool");
}

fn now() f64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(f64, @floatFromInt(ts.tv_sec)) + @as(f64, @floatFromInt(ts.tv_nsec)) / 1e9;
}

// ---------------------------------------------------------------- main

fn parseHex(s: []const u8) Rgb {
    const t = if (s.len > 0 and s[0] == '#') s[1..] else s;
    if (t.len != 6) usage();
    return hex(std.fmt.parseInt(u32, t, 16) catch usage());
}

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    var i: usize = 1;
    while (i < argv.len) : (i += 2) {
        if (i + 1 >= argv.len) usage();
        const k = std.mem.span(argv[i]);
        const v = std.mem.span(argv[i + 1]);
        if (std.mem.eql(u8, k, "--fps")) {
            opt_fps = std.math.clamp(std.fmt.parseFloat(f64, v) catch usage(), 0.1, 30);
        } else if (std.mem.eql(u8, k, "--points")) {
            opt_points = std.math.clamp(std.fmt.parseInt(usize, v, 10) catch usage(), 3, 2000);
        } else if (std.mem.eql(u8, k, "--speed")) {
            opt_speed = std.math.clamp(std.fmt.parseFloat(f64, v) catch usage(), 0, 50);
        } else if (std.mem.eql(u8, k, "--bg")) {
            col_bg = parseHex(v);
        } else if (std.mem.eql(u8, k, "--a")) {
            col_a = parseHex(v);
        } else if (std.mem.eql(u8, k, "--b")) {
            col_b = parseHex(v);
        } else usage();
    }

    try initScene();

    const display = c.wl_display_connect(null) orelse fatal("cannot connect to Wayland display", .{});
    const registry = c.wl_display_get_registry(display);
    _ = c.wl_registry_add_listener(registry, &registry_listener, null);
    if (c.wl_display_roundtrip(display) < 0) fatal("roundtrip failed", .{});
    if (compositor == null or shm == null) fatal("compositor lacks wl_compositor/wl_shm", .{});
    if (layer_shell == null) fatal("compositor lacks zwlr_layer_shell_v1 (not wlroots?)", .{});
    for (outputs.items) |out| setupOutput(out);
    _ = c.wl_display_roundtrip(display);

    // Power-saver profile: drop to at most 1 fps (checked every ~5 s).
    var frame = 1.0 / opt_fps;
    var last = now();
    var next = last + frame;
    var next_profile_check = last;
    const fd = c.wl_display_get_fd(display);
    while (true) {
        while (c.wl_display_prepare_read(display) != 0) _ = c.wl_display_dispatch_pending(display);
        _ = c.wl_display_flush(display);
        const wait_ms: c_int = @intFromFloat(@max(0, (next - now()) * 1000));
        var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
        const r = c.poll(&pfd, 1, wait_ms);
        if (r > 0 and (pfd.revents & c.POLLIN) != 0) {
            if (c.wl_display_read_events(display) < 0) fatal("lost connection to the compositor", .{});
        } else {
            c.wl_display_cancel_read(display);
        }
        if (c.wl_display_dispatch_pending(display) < 0) fatal("lost connection to the compositor", .{});

        const t = now();
        if (t >= next_profile_check) {
            frame = 1.0 / (if (lowPower()) @min(opt_fps, 1.0) else opt_fps);
            next_profile_check = t + 5;
        }
        if (t >= next) {
            stepScene(t - last);
            last = t;
            next = t + frame;
            for (outputs.items) |out| render(out);
        }
    }
}
