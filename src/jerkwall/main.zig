//! jerkwall — live Delaunay wallpaper for wlroots compositors (sway).
//!
//! Slowly drifting points are triangulated (Bowyer–Watson, the same mesh
//! d3-delaunay draws) and each triangle is filled with a subtle mix of the
//! background and two accent colours, driven by a slowly moving noise field
//! whose hue wanders over minutes. Drawn on the CPU into shared memory on the
//! layer-shell *background* layer. Rendered on the GPU (EGL + GLES2, 4x MSAA)
//! at 30 fps by default; falls back to a CPU/shm renderer (max 6 fps) when
//! there's no usable EGL. --frame (lock screen PNG) always uses the CPU.
//!
//!   jerkwall [--fps N] [--points N] [--speed X] [--contrast X] [--bg RRGGBB] [--a RRGGBB] [--b RRGGBB]
//!   jerkwall [same options] [--at S] --frame W H FILE.png   render "now" (+S seconds) to a PNG and exit
//!   jerkwall [same options] [--at S] --frame W H x --frames N DIR   N eased 30 fps frames (tests)
//!
//! The scene is a pure function of the wall clock (fixed seed), so --frame
//! produces exactly what a running jerkwall shows at that moment; the lock
//! screen uses this. --fps defaults to 4; with the power-saver profile (platform_profile
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
    @cInclude("stdio.h");
    @cInclude("wayland-egl.h");
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
    @cInclude("GLES2/gl2.h");
});

const gpa = std.heap.c_allocator;

// ---------------------------------------------------------------- options

const Rgb = struct { r: f64, g: f64, b: f64 };

var opt_fps: f64 = 30; // GPU path; the CPU fallback is capped at 6 (see effectiveFps)
var opt_points: usize = 140;
var opt_speed: f64 = 1.0;
var opt_contrast: f64 = 1.6; // accent strength (user default 1.6); 0.5 ≈ the first, subtler draft
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
    std.debug.print("usage: jerkwall [--fps N] [--points N] [--speed X] [--contrast X] [--bg RRGGBB] [--a RRGGBB] [--b RRGGBB] [--at S] [--frame W H FILE.png]\n", .{});
    std.process.exit(2);
}

// ---------------------------------------------------------------- scene

const Pt = struct {
    x: f64 = 0,
    y: f64 = 0,
    home_x: f64, // moving points wander around home; fixed (border) points stay here
    home_y: f64,
    fixed: bool = false,
    leg: f64 = 1, // seconds per movement leg (waypoint to waypoint)
    leg_phase: f64 = 0,
    tone: f64 = 1, // seconds per colour-variation step
    tone_phase: f64 = 0,
    // Per-frame derived values (setTime): colour variation and field samples.
    jitter: f64 = 0,
    accent: f64 = 0,
    hue: f64 = 0,
};

var points: std.ArrayList(Pt) = .empty;
var scene_time: f64 = 0;

/// Fixed seed + wall-clock time ⇒ every jerkwall process computes the same
/// frame for the same moment. That's how the lock screen shows exactly what
/// the wallpaper shows, without talking to the running instance.
const seed: u64 = 0x6a65726b77616c6c; // "jerkwall"
const epoch: f64 = 1.7e9; // keeps time values small for the trig below
const wander = 0.11; // how far (screen fraction) a point roams from home

/// Deterministic hash → [0, 1). `a`, `b`, `c` select point, step and channel.
fn rnd01(a: u64, b: i64, c_: u64) f64 {
    var z = seed ^ (a *% 0x9e3779b97f4a7c15) ^ (@as(u64, @bitCast(b)) *% 0xbf58476d1ce4e5b9) ^ (c_ *% 0x94d049bb133111eb);
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    z ^= z >> 31;
    return @as(f64, @floatFromInt(z >> 11)) / 9007199254740992.0;
}

/// Quadratic ease-in-out: zero speed at both ends, so every leg starts and
/// ends smoothly (a soft turn-around instead of an instant reflection).
fn easeQuad(s_: f64) f64 {
    return if (s_ < 0.5) 2 * s_ * s_ else 1 - 2 * (1 - s_) * (1 - s_);
}

/// Value of a channel that eases between per-step random targets.
/// Returns the eased interpolation for point `i`, step length `period`.
fn eased(i: u64, ch: u64, t: f64, period: f64, phase: f64) f64 {
    const tau = (t + phase) / period;
    const k = @floor(tau);
    const ki: i64 = @intFromFloat(k);
    const e = easeQuad(tau - k);
    const a = rnd01(i, ki, ch);
    const b = rnd01(i, ki + 1, ch);
    return a + (b - a) * e;
}

/// Soft "bounce" back inside [lo, hi]: mirror anything that crosses an edge.
fn reflectInto(v: f64, lo: f64, hi: f64) f64 {
    if (v < lo) return lo + (lo - v);
    if (v > hi) return hi - (v - hi);
    return v;
}

fn initScene() !void {
    // Fixed points on the border so the mesh always covers the whole screen.
    const per_side = 7;
    for (0..per_side + 1) |i| {
        const t = @as(f64, @floatFromInt(i)) / per_side;
        try points.append(gpa, .{ .home_x = t, .home_y = 0, .fixed = true });
        try points.append(gpa, .{ .home_x = t, .home_y = 1, .fixed = true });
        if (i != 0 and i != per_side) {
            try points.append(gpa, .{ .home_x = 0, .home_y = t, .fixed = true });
            try points.append(gpa, .{ .home_x = 1, .home_y = t, .fixed = true });
        }
    }
    // Moving points: homes on a jittered grid (even spread, no clumping).
    const n = opt_points;
    const cols: usize = @max(1, @as(usize, @intFromFloat(@round(@sqrt(@as(f64, @floatFromInt(n)) * 16.0 / 9.0)))));
    const rows: usize = (n + cols - 1) / cols;
    for (0..n) |ii| {
        const i: u64 = ii;
        const cx = (@as(f64, @floatFromInt(ii % cols)) + 0.15 + 0.7 * rnd01(i, -1, 1)) / @as(f64, @floatFromInt(cols));
        const cy = (@as(f64, @floatFromInt(ii / cols)) + 0.15 + 0.7 * rnd01(i, -1, 2)) / @as(f64, @floatFromInt(rows));
        const slow = 1.0 / @max(0.05, opt_speed);
        try points.append(gpa, .{
            .home_x = cx,
            .home_y = cy,
            .leg = (7 + 7 * rnd01(i, -1, 3)) * slow,
            .leg_phase = 100 * rnd01(i, -1, 4),
            .tone = (5 + 6 * rnd01(i, -1, 5)) * slow,
            .tone_phase = 100 * rnd01(i, -1, 6),
        });
    }
}

fn setTime(t: f64) void {
    scene_time = t;
    for (points.items, 0..) |*p, ii| {
        const i: u64 = ii;
        if (p.fixed) {
            p.x = p.home_x;
            p.y = p.home_y;
        } else {
            // Waypoints scattered around home; quadratic easing between them.
            const dx = (eased(i, 10, t, p.leg, p.leg_phase) - 0.5) * 2 * wander;
            const dy = (eased(i, 11, t, p.leg, p.leg_phase) - 0.5) * 2 * wander;
            p.x = reflectInto(p.home_x + dx, 0.01, 0.99);
            p.y = reflectInto(p.home_y + dy, 0.01, 0.99);
        }
        // Colour: per-point variation easing between targets, plus slow
        // fields sampled at the point (continuous in position and time).
        p.jitter = eased(i, 20, t, if (p.fixed) 9 else p.tone, p.tone_phase) - 0.5;
        const u = p.x;
        const v = p.y;
        const n1 = 0.5 + 0.5 * @sin(u * 3.1 + t * 0.07) * @cos(v * 2.3 - t * 0.05);
        const n2 = 0.5 + 0.5 * @sin((u + v) * 4.0 - t * 0.11);
        p.accent = 0.06 + 0.39 * n1 * n2 + 0.10 * p.jitter;
        p.hue = 0.5 + 0.5 * @sin(t * 0.013 + u * 1.7 - v * 1.1);
    }
}

fn wallTime() f64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
    return @as(f64, @floatFromInt(ts.tv_sec)) - epoch + @as(f64, @floatFromInt(ts.tv_nsec)) / 1e9;
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

/// Colour of a triangle: the average of its three points' eased values, so
/// when the mesh re-forms, colours shift gently instead of jumping.
fn facetRgb(a: u32, b: u32, cc: u32) Rgb {
    const pa = points.items[a];
    const pb = points.items[b];
    const pc = points.items[cc];
    const k = std.math.clamp((pa.accent + pb.accent + pc.accent) / 3 * opt_contrast, 0, 0.9);
    const h = (pa.hue + pb.hue + pc.hue) / 3;
    return mix(col_bg, mix(col_a, col_b, h), k);
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

// ---------------------------------------------------------------- per-pixel temporal smoothing

/// What's on screen eases toward the freshly drawn mesh, per pixel and per
/// R/G/B channel, through two first-order stages (an S-shaped approach — gentle
/// start, gentle stop — like the quadratic easing used for the motion). So any
/// change, including a Delaunay re-form or a colour stepping, becomes a
/// continuous transition instead of a jump. Frame-rate independent.
const smooth_tau = 0.12; // seconds per stage (≈0.3 s to settle): keeps ~93% edge crispness, no steps >2 levels/frame

fn smoothAlpha(dt: f64) f32 {
    return @floatCast(1 - @exp(-@max(dt, 0) / smooth_tau));
}

/// CPU version (shm fallback and --frames tests): float state per channel.
const CpuSmooth = struct {
    s1: []f32 = &.{},
    s2: []f32 = &.{},
    primed: bool = false,
    last_t: f64 = 0,

    fn deinit(m: *CpuSmooth) void {
        if (m.s1.len > 0) gpa.free(m.s1);
        if (m.s2.len > 0) gpa.free(m.s2);
        m.* = .{};
    }

    /// Smooth `px` (XRGB8888) in place toward the mesh just drawn into it.
    fn apply(m: *CpuSmooth, px: []u32, t: f64) !void {
        if (m.s1.len != px.len * 3) {
            m.deinit();
            m.s1 = try gpa.alloc(f32, px.len * 3);
            m.s2 = try gpa.alloc(f32, px.len * 3);
        }
        const a: f32 = if (m.primed) smoothAlpha(t - m.last_t) else 1;
        m.primed = true;
        m.last_t = t;
        for (px, 0..) |*p, i| {
            const cur = [3]f32{
                @floatFromInt((p.* >> 16) & 0xff),
                @floatFromInt((p.* >> 8) & 0xff),
                @floatFromInt(p.* & 0xff),
            };
            var o: [3]u32 = undefined;
            for (0..3) |k| {
                const j = i * 3 + k;
                m.s1[j] += (cur[k] - m.s1[j]) * a;
                m.s2[j] += (m.s1[j] - m.s2[j]) * a;
                o[k] = @intFromFloat(std.math.clamp(m.s2[j] + 0.5, 0, 255));
            }
            p.* = 0xff000000 | (o[0] << 16) | (o[1] << 8) | o[2];
        }
    }
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
    egl_window: ?*c.wl_egl_window = null,
    egl_surface: c.EGLSurface = c.EGL_NO_SURFACE,
    gl_verts: std.ArrayList(f32) = .empty,
    smooth: CpuSmooth = .{},
    // GPU smoothing: mesh snapshot + two ping-ponged half-float stages.
    gl_w: usize = 0,
    gl_h: usize = 0,
    gl_smooth_ok: bool = false,
    mesh_tex: c.GLuint = 0,
    stage_tex: [4]c.GLuint = .{ 0, 0, 0, 0 }, // s1 a/b, s2 a/b
    stage_fbo: [4]c.GLuint = .{ 0, 0, 0, 0 },
    flip: usize = 0, // which of a/b holds the current stage values
    gl_primed: bool = false,
    gl_last_t: f64 = 0,
};

// ---------------------------------------------------------------- GPU (EGL + GLES2)

var egl_display: c.EGLDisplay = c.EGL_NO_DISPLAY;
var egl_config: c.EGLConfig = null;
var egl_context: c.EGLContext = c.EGL_NO_CONTEXT;
var gl_ready = false; // context exists; program built on first makeCurrent
var gl_prog: c.GLuint = 0;
var gl_vbo: c.GLuint = 0;
var gl_pos: c.GLint = 0;
var gl_col: c.GLint = 0;
var use_gpu = false;
var software_gl = false; // EGL works but renders on the CPU (llvmpipe)

const vs_src =
    \\attribute vec2 pos;
    \\attribute vec3 col;
    \\varying vec3 v_col;
    \\void main() { v_col = col; gl_Position = vec4(pos, 0.0, 1.0); }
;
const fs_src =
    \\precision mediump float;
    \\varying vec3 v_col;
    \\void main() { gl_FragColor = vec4(v_col, 1.0); }
;
const quad_vs =
    \\attribute vec2 qpos;
    \\varying vec2 v_uv;
    \\void main() { v_uv = qpos * 0.5 + 0.5; gl_Position = vec4(qpos, 0.0, 1.0); }
;
// One smoothing stage: move the previous value toward the new one by u_a.
const blend_fs =
    \\#ifdef GL_FRAGMENT_PRECISION_HIGH
    \\precision highp float;
    \\#else
    \\precision mediump float;
    \\#endif
    \\uniform sampler2D u_prev;
    \\uniform sampler2D u_cur;
    \\uniform float u_a;
    \\varying vec2 v_uv;
    \\void main() { gl_FragColor = vec4(mix(texture2D(u_prev, v_uv).rgb, texture2D(u_cur, v_uv).rgb, u_a), 1.0); }
;
// Present: ±0.5 LSB dither hides the 1/255 steps of slowly drifting channels.
const present_fs =
    \\#ifdef GL_FRAGMENT_PRECISION_HIGH
    \\precision highp float;
    \\#else
    \\precision mediump float;
    \\#endif
    \\uniform sampler2D u_tex;
    \\varying vec2 v_uv;
    \\void main() {
    \\    float n = fract(sin(dot(gl_FragCoord.xy, vec2(12.9898, 78.233))) * 43758.5453);
    \\    gl_FragColor = vec4(texture2D(u_tex, v_uv).rgb + (n - 0.5) / 255.0, 1.0);
    \\}
;

var gl_blend_prog: c.GLuint = 0;
var gl_present_prog: c.GLuint = 0;
var gl_quad_vbo: c.GLuint = 0;
const half_float_oes: c.GLenum = 0x8D61; // GL_HALF_FLOAT_OES (gl2ext.h)

/// Set up EGL on the Wayland display: GLES2, 4x MSAA if available. Any
/// failure leaves use_gpu = false and the shm CPU renderer takes over.
fn initGpu(display: *c.wl_display) void {
    egl_display = c.eglGetPlatformDisplay(c.EGL_PLATFORM_WAYLAND_KHR, display, null);
    if (egl_display == c.EGL_NO_DISPLAY) return;
    if (c.eglInitialize(egl_display, null, null) != c.EGL_TRUE) return;
    if (c.eglBindAPI(c.EGL_OPENGL_ES_API) != c.EGL_TRUE) return;
    const base = [_]c.EGLint{
        c.EGL_SURFACE_TYPE,    c.EGL_WINDOW_BIT,
        c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_ES2_BIT,
        c.EGL_RED_SIZE,        8,
        c.EGL_GREEN_SIZE,      8,
        c.EGL_BLUE_SIZE,       8,
        c.EGL_SAMPLE_BUFFERS,  1,
        c.EGL_SAMPLES,         4,
        c.EGL_NONE,
    };
    var n: c.EGLint = 0;
    if (c.eglChooseConfig(egl_display, &base, &egl_config, 1, &n) != c.EGL_TRUE or n < 1) {
        // No MSAA config: retry without multisampling.
        const plain = [_]c.EGLint{
            c.EGL_SURFACE_TYPE, c.EGL_WINDOW_BIT, c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_ES2_BIT,
            c.EGL_RED_SIZE,     8,                c.EGL_GREEN_SIZE,      8,
            c.EGL_BLUE_SIZE,    8,                c.EGL_NONE,
        };
        if (c.eglChooseConfig(egl_display, &plain, &egl_config, 1, &n) != c.EGL_TRUE or n < 1) return;
    }
    const ctx_attr = [_]c.EGLint{ c.EGL_CONTEXT_CLIENT_VERSION, 2, c.EGL_NONE };
    egl_context = c.eglCreateContext(egl_display, egl_config, c.EGL_NO_CONTEXT, &ctx_attr);
    if (egl_context == c.EGL_NO_CONTEXT) return;
    use_gpu = true;
}

fn compileShader(kind: c.GLenum, src: [*:0]const u8) c.GLuint {
    const sh = c.glCreateShader(kind);
    const srcs = [_][*c]const u8{src};
    c.glShaderSource(sh, 1, &srcs, null);
    c.glCompileShader(sh);
    var okv: c.GLint = 0;
    c.glGetShaderiv(sh, c.GL_COMPILE_STATUS, &okv);
    if (okv == 0) fatal("shader compile failed", .{});
    return sh;
}

fn linkProgram(vs: [*:0]const u8, fs: [*:0]const u8) c.GLuint {
    const prog = c.glCreateProgram();
    c.glAttachShader(prog, compileShader(c.GL_VERTEX_SHADER, vs));
    c.glAttachShader(prog, compileShader(c.GL_FRAGMENT_SHADER, fs));
    c.glBindAttribLocation(prog, 0, "qpos");
    c.glLinkProgram(prog);
    var okv: c.GLint = 0;
    c.glGetProgramiv(prog, c.GL_LINK_STATUS, &okv);
    if (okv == 0) fatal("shader link failed", .{});
    return prog;
}

fn buildProgram() void {
    if (gl_ready) return;
    gl_prog = linkProgram(vs_src, fs_src);
    gl_pos = c.glGetAttribLocation(gl_prog, "pos");
    gl_col = c.glGetAttribLocation(gl_prog, "col");
    c.glGenBuffers(1, &gl_vbo);
    gl_blend_prog = linkProgram(quad_vs, blend_fs);
    gl_present_prog = linkProgram(quad_vs, present_fs);
    const quad = [_]f32{ -1, -1, 1, -1, -1, 1, 1, 1 };
    c.glGenBuffers(1, &gl_quad_vbo);
    c.glBindBuffer(c.GL_ARRAY_BUFFER, gl_quad_vbo);
    c.glBufferData(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(quad)), &quad, c.GL_STATIC_DRAW);
    gl_ready = true;
    // Mesa's software rasterizers (llvmpipe/softpipe) "work" without a GPU but
    // run on the CPU: treat them like no GPU for frame pacing.
    if (c.glGetString(c.GL_RENDERER)) |r| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(r)));
        if (std.mem.indexOf(u8, name, "llvmpipe") != null or std.mem.indexOf(u8, name, "softpipe") != null) {
            software_gl = true;
            std.debug.print("jerkwall: GL renderer is {s} (software): capping at CPU-renderer frame rates\n", .{name});
        }
    }
}

fn renderGpu(out: *Output, w: usize, h: usize) void {
    const scale: c_int = @max(1, out.scale);
    if (out.egl_window == null) {
        out.egl_window = c.wl_egl_window_create(out.surface, @intCast(w), @intCast(h));
        out.egl_surface = c.eglCreatePlatformWindowSurface(egl_display, egl_config, out.egl_window, null);
        if (out.egl_surface == c.EGL_NO_SURFACE) fatal("eglCreatePlatformWindowSurface failed", .{});
    } else {
        c.wl_egl_window_resize(out.egl_window, @intCast(w), @intCast(h), 0, 0);
    }
    if (c.eglMakeCurrent(egl_display, out.egl_surface, out.egl_surface, egl_context) != c.EGL_TRUE) return;
    _ = c.eglSwapInterval(egl_display, 0); // we pace frames ourselves
    buildProgram();

    const fw: f64 = @floatFromInt(w);
    const fh: f64 = @floatFromInt(h);
    out.verts.clearRetainingCapacity();
    for (points.items) |p| out.verts.append(gpa, .{ .x = p.x * fw, .y = p.y * fh }) catch return;
    triangulate(out.verts.items, &out.tris) catch return;

    out.gl_verts.clearRetainingCapacity();
    for (out.tris.items) |tr| {
        const col = facetRgb(tr.a, tr.b, tr.c);
        for ([3]u32{ tr.a, tr.b, tr.c }) |vi| {
            const p = out.verts.items[vi];
            out.gl_verts.appendSlice(gpa, &.{
                @floatCast(p.x / fw * 2 - 1), @floatCast(1 - p.y / fh * 2),
                @floatCast(col.r),            @floatCast(col.g),
                @floatCast(col.b),
            }) catch return;
        }
    }

    c.wl_surface_set_buffer_scale(out.surface, scale);
    c.glViewport(0, 0, @intCast(w), @intCast(h));
    c.glDisable(c.GL_BLEND);

    // 1) The mesh, multisampled, into the window's framebuffer.
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
    c.glClearColor(@floatCast(col_bg.r), @floatCast(col_bg.g), @floatCast(col_bg.b), 1);
    c.glClear(c.GL_COLOR_BUFFER_BIT);
    c.glUseProgram(gl_prog);
    c.glBindBuffer(c.GL_ARRAY_BUFFER, gl_vbo);
    c.glBufferData(c.GL_ARRAY_BUFFER, @intCast(out.gl_verts.items.len * 4), out.gl_verts.items.ptr, c.GL_STREAM_DRAW);
    const stride: c.GLsizei = 5 * 4;
    c.glEnableVertexAttribArray(@intCast(gl_pos));
    c.glVertexAttribPointer(@intCast(gl_pos), 2, c.GL_FLOAT, c.GL_FALSE, stride, null);
    c.glEnableVertexAttribArray(@intCast(gl_col));
    c.glVertexAttribPointer(@intCast(gl_col), 3, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(2 * 4));
    c.glDrawArrays(c.GL_TRIANGLES, 0, @intCast(out.gl_verts.items.len / 5));
    c.glDisableVertexAttribArray(@intCast(gl_pos));
    c.glDisableVertexAttribArray(@intCast(gl_col));

    // 2) Temporal smoothing (needs float render targets; else show the mesh as is).
    ensureSmoothTargets(out, w, h);
    if (out.gl_smooth_ok) {
        c.glBindTexture(c.GL_TEXTURE_2D, out.mesh_tex);
        c.glCopyTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, 0, 0, @intCast(w), @intCast(h)); // resolves MSAA
        const a: f32 = if (out.gl_primed) smoothAlpha(scene_time - out.gl_last_t) else 1;
        out.gl_primed = true;
        out.gl_last_t = scene_time;
        const cur = out.flip;
        const nxt = 1 - cur;
        stagePass(out.stage_fbo[nxt], out.stage_tex[cur], out.mesh_tex, a); // s1 ← mix(s1, mesh)
        stagePass(out.stage_fbo[2 + nxt], out.stage_tex[2 + cur], out.stage_tex[nxt], a); // s2 ← mix(s2, s1)
        out.flip = nxt;
        // 3) Present s2 with dither.
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        c.glUseProgram(gl_present_prog);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, out.stage_tex[2 + nxt]);
        c.glUniform1i(c.glGetUniformLocation(gl_present_prog, "u_tex"), 0);
        drawQuad();
    }
    _ = c.eglSwapBuffers(egl_display, out.egl_surface);
}

fn drawQuad() void {
    c.glBindBuffer(c.GL_ARRAY_BUFFER, gl_quad_vbo);
    c.glEnableVertexAttribArray(0);
    c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, 0, null);
    c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
    c.glDisableVertexAttribArray(0);
}

fn stagePass(fbo: c.GLuint, prev: c.GLuint, cur: c.GLuint, a: f32) void {
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
    c.glUseProgram(gl_blend_prog);
    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D, prev);
    c.glActiveTexture(c.GL_TEXTURE1);
    c.glBindTexture(c.GL_TEXTURE_2D, cur);
    c.glUniform1i(c.glGetUniformLocation(gl_blend_prog, "u_prev"), 0);
    c.glUniform1i(c.glGetUniformLocation(gl_blend_prog, "u_cur"), 1);
    c.glUniform1f(c.glGetUniformLocation(gl_blend_prog, "u_a"), a);
    drawQuad();
    c.glActiveTexture(c.GL_TEXTURE0);
}

fn newTex(w: usize, h: usize, format: c.GLenum, kind: c.GLenum) c.GLuint {
    var t: c.GLuint = 0;
    c.glGenTextures(1, &t);
    c.glBindTexture(c.GL_TEXTURE_2D, t);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, @intCast(format), @intCast(w), @intCast(h), 0, format, kind, null);
    return t;
}

/// (Re)create the mesh snapshot and the four half-float stage targets.
fn ensureSmoothTargets(out: *Output, w: usize, h: usize) void {
    if (out.gl_w == w and out.gl_h == h) return;
    if (out.mesh_tex != 0) {
        c.glDeleteTextures(1, &out.mesh_tex);
        c.glDeleteTextures(4, &out.stage_tex);
        c.glDeleteFramebuffers(4, &out.stage_fbo);
    }
    out.gl_w = w;
    out.gl_h = h;
    out.gl_primed = false;
    out.mesh_tex = newTex(w, h, c.GL_RGB, c.GL_UNSIGNED_BYTE);
    c.glGenFramebuffers(4, &out.stage_fbo);
    out.gl_smooth_ok = true;
    for (0..4) |k| {
        out.stage_tex[k] = newTex(w, h, c.GL_RGBA, half_float_oes);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, out.stage_fbo[k]);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, out.stage_tex[k], 0);
        if (c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE) out.gl_smooth_ok = false;
    }
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
    if (!out.gl_smooth_ok) std.debug.print("jerkwall: no half-float render targets; temporal smoothing off\n", .{});
}

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

/// Draw the current scene into an XRGB8888 pixel buffer; with `smooth`,
/// ease what's shown toward it (live CPU renderer, --frames tests).
fn drawFrame(px: []u32, w: usize, h: usize, verts: *std.ArrayList(V), tris: *std.ArrayList(Tri), smooth: ?*CpuSmooth) !void {
    const fw: f64 = @floatFromInt(w);
    const fh: f64 = @floatFromInt(h);
    verts.clearRetainingCapacity();
    for (points.items) |p| try verts.append(gpa, .{ .x = p.x * fw, .y = p.y * fh });
    try triangulate(verts.items, tris);
    @memset(px, pack(col_bg));
    for (tris.items) |tr| {
        fillTri(px, w, h, verts.items[tr.a], verts.items[tr.b], verts.items[tr.c], pack(facetRgb(tr.a, tr.b, tr.c)));
    }
    if (smooth) |sm| try sm.apply(px, scene_time);
}

/// Write XRGB8888 pixels as an 8-bit RGB PNG (zlib "stored" blocks: no
/// compression, but tiny code and valid for every decoder).
fn writePng(path: [*:0]const u8, px: []const u32, w: usize, h: usize) !void {
    const f = c.fopen(path, "wb") orelse return error.OpenFailed;
    defer _ = c.fclose(f);
    const W = struct {
        f: *c.FILE,
        fn raw(self: @This(), bytes: []const u8) !void {
            if (c.fwrite(bytes.ptr, 1, bytes.len, self.f) != bytes.len) return error.WriteFailed;
        }
        fn be32(self: @This(), v: u32) !void {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, v, .big);
            try self.raw(&b);
        }
        fn chunk(self: @This(), kind: *const [4]u8, data: []const u8) !void {
            try self.be32(@intCast(data.len));
            try self.raw(kind);
            try self.raw(data);
            var crc = std.hash.Crc32.init();
            crc.update(kind);
            crc.update(data);
            try self.be32(crc.final());
        }
    };
    const out = W{ .f = f };
    try out.raw("\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(w), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(h), .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 2; // colour type RGB
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try out.chunk("IHDR", &ihdr);

    // Raw scanlines: filter byte 0 + RGB.
    const row_len = 1 + w * 3;
    const raw = try gpa.alloc(u8, row_len * h);
    defer gpa.free(raw);
    for (0..h) |y| {
        const row = raw[y * row_len ..][0..row_len];
        row[0] = 0;
        for (0..w) |x| {
            const p = px[y * w + x];
            row[1 + x * 3] = @truncate(p >> 16);
            row[2 + x * 3] = @truncate(p >> 8);
            row[3 + x * 3] = @truncate(p);
        }
    }
    // zlib stream: header, stored deflate blocks (≤ 65535 bytes each), Adler-32.
    const blocks = (raw.len + 65534) / 65535;
    var z = try gpa.alloc(u8, 2 + raw.len + blocks * 5 + 4);
    defer gpa.free(z);
    z[0] = 0x78;
    z[1] = 0x01;
    var zi: usize = 2;
    var off: usize = 0;
    while (off < raw.len) {
        const n = @min(65535, raw.len - off);
        z[zi] = if (off + n == raw.len) 1 else 0; // BFINAL, BTYPE=00
        std.mem.writeInt(u16, z[zi + 1 ..][0..2], @intCast(n), .little);
        std.mem.writeInt(u16, z[zi + 3 ..][0..2], @intCast(~@as(u16, @intCast(n))), .little);
        zi += 5;
        @memcpy(z[zi .. zi + n], raw[off .. off + n]);
        zi += n;
        off += n;
    }
    std.mem.writeInt(u32, z[zi..][0..4], std.hash.Adler32.hash(raw), .big);
    zi += 4;
    try out.chunk("IDAT", z[0..zi]);
    try out.chunk("IEND", "");
}

fn render(out: *Output) void {
    if (!out.configured or out.width == 0 or out.height == 0) return;
    const scale: usize = @intCast(@max(1, out.scale));
    const w = out.width * scale;
    const h = out.height * scale;
    if (use_gpu) return renderGpu(out, w, h);
    const buf = for (&out.buffers) |*b| {
        if (!b.busy) break b;
    } else return; // both in use by the compositor; skip this frame
    ensureBuffer(buf, w, h) catch |err| fatal("buffer: {s}", .{@errorName(err)});

    drawFrame(buf.data, w, h, &out.verts, &out.tris, &out.smooth) catch return;

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
        if (out.egl_surface != c.EGL_NO_SURFACE) _ = c.eglDestroySurface(egl_display, out.egl_surface);
        if (out.egl_window) |ew| c.wl_egl_window_destroy(ew);
        out.gl_verts.deinit(gpa);
        out.smooth.deinit();
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

/// Frame rate actually used: --fps, capped at 6 on the CPU renderer (~9 ms a
/// frame at 1080p) and at 10 / 2 (GPU / CPU) under the power-saver profile.
fn effectiveFps() f64 {
    const hw = use_gpu and !software_gl;
    var f = opt_fps;
    if (!hw) f = @min(f, 6);
    if (lowPower()) f = @min(f, @as(f64, if (hw) 10.0 else 2.0));
    return f;
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
    var frame_w: usize = 0;
    var frame_h: usize = 0;
    var frame_file: ?[*:0]const u8 = null;
    var frame_offset: f64 = 0;
    var seq_n: usize = 0;
    var seq_dir: ?[*:0]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 2) {
        if (i + 1 >= argv.len) usage();
        const k = std.mem.span(argv[i]);
        const v = std.mem.span(argv[i + 1]);
        if (std.mem.eql(u8, k, "--at")) {
            // --at SECONDS: with --frame, render the moment SECONDS from now
            // (negative = past). For previews and tests.
            frame_offset = std.fmt.parseFloat(f64, v) catch usage();
        } else if (std.mem.eql(u8, k, "--frame")) {
            // --frame W H FILE: render the frame for "now" to a PNG and exit.
            if (i + 3 >= argv.len) usage();
            frame_w = std.fmt.parseInt(usize, v, 10) catch usage();
            frame_h = std.fmt.parseInt(usize, std.mem.span(argv[i + 2]), 10) catch usage();
            frame_file = argv[i + 3];
            if (frame_w == 0 or frame_h == 0 or frame_w > 16384 or frame_h > 16384) usage();
            i += 2;
        } else if (std.mem.eql(u8, k, "--frames")) {
            // --frames N DIR (after --frame W H X): N consecutive 30 fps frames
            // with colour easing, as DIR/f000.png… For smoothness tests.
            if (i + 2 >= argv.len) usage();
            seq_n = std.math.clamp(std.fmt.parseInt(usize, v, 10) catch usage(), 1, 10000);
            seq_dir = argv[i + 2];
            i += 1;
        } else if (std.mem.eql(u8, k, "--fps")) {
            opt_fps = std.math.clamp(std.fmt.parseFloat(f64, v) catch usage(), 0.1, 30);
        } else if (std.mem.eql(u8, k, "--points")) {
            opt_points = std.math.clamp(std.fmt.parseInt(usize, v, 10) catch usage(), 3, 2000);
        } else if (std.mem.eql(u8, k, "--contrast")) {
            opt_contrast = std.math.clamp(std.fmt.parseFloat(f64, v) catch usage(), 0, 3);
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
    setTime(wallTime() + frame_offset);

    if (frame_file) |path| {
        const px = try gpa.alloc(u32, frame_w * frame_h);
        defer gpa.free(px);
        var verts: std.ArrayList(V) = .empty;
        var tris: std.ArrayList(Tri) = .empty;

        if (seq_dir) |dir| {
            var sm = CpuSmooth{};
            const t0 = scene_time;
            for (0..seq_n) |fi| {
                setTime(t0 + @as(f64, @floatFromInt(fi)) / 30.0);
                try drawFrame(px, frame_w, frame_h, &verts, &tris, &sm);
                var name: [4096]u8 = undefined;
                const fp = std.fmt.bufPrintZ(&name, "{s}/f{d:0>3}.png", .{ std.mem.span(dir), fi }) catch usage();
                writePng(fp.ptr, px, frame_w, frame_h) catch |err| fatal("writing {s}: {s}", .{ fp, @errorName(err) });
            }
            return;
        }
        try drawFrame(px, frame_w, frame_h, &verts, &tris, null);
        writePng(path, px, frame_w, frame_h) catch |err| fatal("writing {s}: {s}", .{ path, @errorName(err) });
        return;
    }

    const display = c.wl_display_connect(null) orelse fatal("cannot connect to Wayland display", .{});
    const registry = c.wl_display_get_registry(display);
    _ = c.wl_registry_add_listener(registry, &registry_listener, null);
    if (c.wl_display_roundtrip(display) < 0) fatal("roundtrip failed", .{});
    if (compositor == null or shm == null) fatal("compositor lacks wl_compositor/wl_shm", .{});
    if (layer_shell == null) fatal("compositor lacks zwlr_layer_shell_v1 (not wlroots?)", .{});
    if (std.c.getenv("JERKWALL_NO_GPU") == null) initGpu(display);
    if (!use_gpu) std.debug.print("jerkwall: no usable EGL/GLES2, using the CPU renderer (max 6 fps)\n", .{});
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
            frame = 1.0 / effectiveFps();
            next_profile_check = t + 5;
        }
        if (t >= next) {
            setTime(wallTime());
            last = t;
            next = t + frame;
            for (outputs.items) |out| render(out);
        }
    }
}
