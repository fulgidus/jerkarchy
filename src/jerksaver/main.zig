//! jerksaver — terminal screensavers for jerkarchy, with a big title.
//!
//!   jerksaver MODE [--title TEXT] [--bg RRGGBB --fg … --dim … --accent …
//!                   --accent2 … --ok … --warn …] [--fps N]
//!
//! MODE: matrix, bonsai, city, galaxy, planets, threebody, random.
//! Runs full screen in a terminal (the `screensaver` script opens one);
//! any key, click or real mouse move quits. Colours come from the theme.
//! Everything is procedural and drawn here: no cmatrix/cbonsai needed.
//!
//! threebody: periodic three-body orbits, integrated live (G = m = 1):
//! the figure-eight (Moore 1993; Chenciner & Montgomery 2000) and orbits
//! from Šuvakov & Dmitrašinović, Phys. Rev. Lett. 110, 114301 (2013), as
//! catalogued at threebodyorbits.com.
const std = @import("std");
const font = @import("font");
const c = @cImport({
    @cInclude("termios.h");
    @cInclude("sys/ioctl.h");
    @cInclude("unistd.h");
    @cInclude("poll.h");
    @cInclude("time.h");
});

// ------------------------------------------------------------ basics

const Rgb = struct { r: f32, g: f32, b: f32 };
fn hex(v: u32) Rgb {
    return .{ .r = @floatFromInt((v >> 16) & 255), .g = @floatFromInt((v >> 8) & 255), .b = @floatFromInt(v & 255) };
}
fn mix(a: Rgb, b: Rgb, t: f32) Rgb {
    const k = std.math.clamp(t, 0, 1);
    return .{ .r = a.r + (b.r - a.r) * k, .g = a.g + (b.g - a.g) * k, .b = a.b + (b.b - a.b) * k };
}

var col_bg = hex(0x0a0a0f);
var col_fg = hex(0xc8c8d0);
var col_dim = hex(0x55556a);
var col_accent = hex(0x00f0ff);
var col_accent2 = hex(0xff2b6d);
var col_ok = hex(0x00ff9f);
var col_warn = hex(0xffcc00);

fn now() f64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(f64, @floatFromInt(ts.tv_sec)) + @as(f64, @floatFromInt(ts.tv_nsec)) / 1e9;
}

var rng_state: u64 = 0x9e3779b97f4a7c15;
fn rnd() f32 {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    return @as(f32, @floatFromInt(rng_state >> 40)) / 16777216.0;
}
fn rndInt(n: usize) usize {
    return @min(n - 1, @as(usize, @intFromFloat(rnd() * @as(f32, @floatFromInt(n)))));
}

const alloc = std.heap.c_allocator;

// ------------------------------------------------------------ canvas
// A cell grid, plus a braille layer (2×4 dots per cell) with per-dot
// intensity that modes can let fade into trails.

const Cell = struct { ch: u21 = ' ', fg: Rgb = .{ .r = 0, .g = 0, .b = 0 } };
var W: usize = 0;
var H: usize = 0;
var cells: []Cell = &.{};
var dot_i: []f32 = &.{}; // intensity 0..1 per dot
var dot_c: []Rgb = &.{}; // colour per dot

fn resize(w: usize, h: usize) void {
    W = w;
    H = h;
    if (cells.len > 0) alloc.free(cells);
    if (dot_i.len > 0) alloc.free(dot_i);
    if (dot_c.len > 0) alloc.free(dot_c);
    cells = alloc.alloc(Cell, w * h) catch unreachable;
    dot_i = alloc.alloc(f32, w * h * 8) catch unreachable;
    dot_c = alloc.alloc(Rgb, w * h * 8) catch unreachable;
    @memset(dot_i, 0);
    @memset(dot_c, col_bg);
    clearCells();
}
fn clearCells() void {
    @memset(cells, .{ .ch = ' ', .fg = col_bg });
}
fn put(x: isize, y: isize, ch: u21, fg: Rgb) void {
    if (x < 0 or y < 0 or x >= W or y >= H) return;
    cells[@as(usize, @intCast(y)) * W + @as(usize, @intCast(x))] = .{ .ch = ch, .fg = fg };
}
fn text(x: isize, y: isize, s: []const u8, fg: Rgb) void {
    var i: isize = 0;
    var it = (std.unicode.Utf8View.init(s) catch return).iterator();
    while (it.nextCodepoint()) |cp| : (i += 1) put(x + i, y, cp, fg);
}
fn dotW() f32 {
    return @floatFromInt(W * 2);
}
fn dotH() f32 {
    return @floatFromInt(H * 4);
}
/// Light dot (px, py) in dot space; keeps the brighter of old and new.
fn dot(px: f32, py: f32, col: Rgb, intensity: f32) void {
    if (px < 0 or py < 0 or px >= dotW() or py >= dotH()) return;
    const k = @as(usize, @intFromFloat(py)) * W * 2 + @as(usize, @intFromFloat(px));
    if (intensity >= dot_i[k]) {
        dot_i[k] = intensity;
        dot_c[k] = col;
    }
}
fn disc(cx: f32, cy: f32, r: f32, col: Rgb, intensity: f32) void {
    var y = -r;
    while (y <= r) : (y += 1) {
        var x = -r;
        while (x <= r) : (x += 1) if (x * x + y * y <= r * r + 0.5) dot(cx + x, cy + y, col, intensity);
    }
}
fn fadeDots(k: f32) void {
    for (dot_i) |*v| v.* *= k;
}
/// Composite the braille layer into cells (only where dots are lit).
fn brailleToCells() void {
    const bits = [4][2]u8{ .{ 0x01, 0x08 }, .{ 0x02, 0x10 }, .{ 0x04, 0x20 }, .{ 0x40, 0x80 } };
    for (0..H) |cy| for (0..W) |cx| {
        var mask: u8 = 0;
        var best: f32 = 0;
        var col = col_bg;
        for (0..4) |dy| for (0..2) |dx| {
            const k = (cy * 4 + dy) * W * 2 + cx * 2 + dx;
            if (dot_i[k] > 0.08) {
                mask |= bits[dy][dx];
                if (dot_i[k] > best) {
                    best = dot_i[k];
                    col = dot_c[k];
                }
            }
        };
        if (mask != 0) cells[cy * W + cx] = .{ .ch = 0x2800 + @as(u21, mask), .fg = mix(col_bg, col, 0.25 + 0.75 * best) };
    };
}

var out: std.ArrayList(u8) = .empty;
fn emit(s: []const u8) void {
    out.appendSlice(alloc, s) catch {};
}
fn flush() void {
    out.clearRetainingCapacity();
    emit("\x1b[H");
    var last: ?[3]u8 = null;
    var buf: [64]u8 = undefined;
    for (0..H) |y| {
        if (y > 0) emit("\r\n");
        for (0..W) |x| {
            const cl = cells[y * W + x];
            const rgb = [3]u8{ @intFromFloat(std.math.clamp(cl.fg.r, 0, 255)), @intFromFloat(std.math.clamp(cl.fg.g, 0, 255)), @intFromFloat(std.math.clamp(cl.fg.b, 0, 255)) };
            if (last == null or !std.mem.eql(u8, &last.?, &rgb)) {
                emit(std.fmt.bufPrint(&buf, "\x1b[38;2;{d};{d};{d}m", .{ rgb[0], rgb[1], rgb[2] }) catch "");
                last = rgb;
            }
            var u: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cl.ch, &u) catch 1;
            emit(u[0..n]);
        }
    }
    var off: usize = 0;
    while (off < out.items.len) {
        const n = c.write(1, out.items.ptr + off, out.items.len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
}

// ------------------------------------------------------------ title

var title: []const u8 = "jerkarchy";

/// Big block title (5×7 font) with the time underneath. A font pixel is k
/// cells wide and k half-cells tall (half blocks ▀▄█), so pixels stay square
/// and the size steps finely; the largest k that fits ~half the width.
fn drawTitle() void {
    if (title.len == 0 or W < 20 or H < 10) return;
    const tw = font.textWidth(title);
    var k: usize = 4;
    while (k > 1 and (tw * k > W / 2 or font.h * k > H / 2)) k -= 1;
    if (tw * k > W) return;
    const cw = tw * k; // cells across
    const hh = font.h * k; // half-rows down
    const rows = (hh + 1) / 2;
    const x0: isize = @intCast((W - cw) / 2);
    // Where the scene leaves room: above the tree and the skyline, centre
    // otherwise. Only matrix (busy everywhere) gets a solid backdrop.
    const centre: isize = switch (mode) {
        .bonsai, .city => @intCast(H / 6 + rows / 2),
        else => @intCast(H / 2),
    };
    const y0: isize = centre - @as(isize, @intCast(rows / 2)) - 1;
    if (mode == .matrix) {
        var y: isize = y0 - 1;
        while (y < y0 + @as(isize, @intCast(rows)) + 3) : (y += 1) {
            var x: isize = x0 - 3;
            while (x < x0 + @as(isize, @intCast(cw)) + 3) : (x += 1) put(x, y, ' ', col_bg);
        }
    }
    for (0..rows) |r| for (0..cw) |cx| {
        const on = struct {
            fn at(hx: usize, hy: usize, kk: usize) bool {
                const fy = hy / kk;
                if (fy >= font.h) return false;
                const col = hx / kk;
                const ci = col / (font.w + 1);
                const fx = col % (font.w + 1);
                if (ci >= title.len or fx >= font.w) return false;
                return font.pixel(title[ci], fx, fy);
            }
        };
        const top = on.at(cx, r * 2, k);
        const bot = on.at(cx, r * 2 + 1, k);
        if (!top and !bot) continue;
        const chr: u21 = if (top and bot) 0x2588 else if (top) 0x2580 else 0x2584;
        const col = mix(col_accent, col_accent2, @as(f32, @floatFromInt(r)) / @as(f32, @floatFromInt(rows + 4)));
        put(x0 + @as(isize, @intCast(cx)), y0 + @as(isize, @intCast(r)), chr, col);
    };
    var tbuf: [64]u8 = undefined;
    var tt: c.time_t = c.time(null);
    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&tt, &tm);
    const n = c.strftime(&tbuf, tbuf.len, "%H:%M  ·  %A %d %B", &tm);
    const line = tbuf[0..n];
    const lw: isize = @intCast((std.unicode.utf8CountCodepoints(line) catch line.len));
    const lx = @divTrunc(@as(isize, @intCast(W)) - lw, 2);
    const ly = y0 + @as(isize, @intCast(rows)) + 1;
    var x: isize = lx - 1;
    while (x < lx + lw + 1) : (x += 1) put(x, ly, ' ', col_bg);
    text(lx, ly, line, col_dim);
}

// ------------------------------------------------------------ modes

const Mode = enum { matrix, bonsai, city, galaxy, planets, threebody };
var mode: Mode = .matrix;
var t_mode: f64 = 0; // seconds since the mode (re)started

// matrix ----------------------------------------------------
const Drop = struct { y: f32, speed: f32, len: f32 };
var drops: []Drop = &.{};
var glyph_tab: []u21 = &.{};
fn matrixGlyph() u21 {
    // half-width katakana and digits, as on the films' screens
    return if (rnd() < 0.8) @as(u21, 0xff66) + @as(u21, @intCast(rndInt(56))) else '0' + @as(u21, @intCast(rndInt(10)));
}
fn matrixInit() void {
    if (drops.len > 0) alloc.free(drops);
    if (glyph_tab.len > 0) alloc.free(glyph_tab);
    drops = alloc.alloc(Drop, W) catch unreachable;
    glyph_tab = alloc.alloc(u21, W * H) catch unreachable;
    for (drops) |*d| d.* = .{ .y = -rnd() * @as(f32, @floatFromInt(H)) * 2, .speed = 6 + rnd() * 18, .len = 6 + rnd() * @as(f32, @floatFromInt(H)) * 0.6 };
    for (glyph_tab) |*g| g.* = matrixGlyph();
}
fn matrixStep(dt: f32) void {
    clearCells();
    for (glyph_tab) |*g| if (rnd() < 0.01) {
        g.* = matrixGlyph();
    };
    for (drops, 0..) |*d, x| {
        d.y += d.speed * dt;
        if (d.y - d.len > @as(f32, @floatFromInt(H))) d.* = .{ .y = -rnd() * 10, .speed = 6 + rnd() * 18, .len = 6 + rnd() * @as(f32, @floatFromInt(H)) * 0.6 };
        if (x % 2 == 1) continue; // wide glyphs: every other column
        var k: f32 = 0;
        while (k < d.len) : (k += 1) {
            const y = @floor(d.y) - k;
            if (y < 0 or y >= @as(f32, @floatFromInt(H))) continue;
            const yi: usize = @intFromFloat(y);
            const col = if (k == 0) col_fg else mix(col_accent, col_bg, k / d.len);
            put(@intCast(x), @intCast(yi), glyph_tab[yi * W + x], col);
        }
    }
}

// bonsai ----------------------------------------------------
// Branch walkers grow upward from a pot, splitting and thinning, ending in
// leaves; the tree stays a while, then a new seed grows.
const Walker = struct { x: f32, y: f32, dx: f32, life: f32, kind: u8 }; // kind 0 trunk, 1 branch, 2 shoot
var walkers: std.ArrayList(Walker) = .empty;
var tree: []Cell = &.{};
var bonsai_done_at: f64 = -1;
fn bonsaiInit() void {
    if (tree.len > 0) alloc.free(tree);
    tree = alloc.alloc(Cell, W * H) catch unreachable;
    @memset(tree, .{ .ch = ' ', .fg = col_bg });
    walkers.clearRetainingCapacity();
    const base_y: f32 = @floatFromInt(H -| 4);
    walkers.append(alloc, .{ .x = @floatFromInt(W / 2), .y = base_y, .dx = 0, .life = @as(f32, @floatFromInt(H)) * 0.5, .kind = 0 }) catch {};
    bonsai_done_at = -1;
}
fn treePut(x: f32, y: f32, ch: u21, col: Rgb) void {
    if (x < 0 or y < 0 or x >= @as(f32, @floatFromInt(W)) or y >= @as(f32, @floatFromInt(H))) return;
    tree[@as(usize, @intFromFloat(y)) * W + @as(usize, @intFromFloat(x))] = .{ .ch = ch, .fg = col };
}
fn bonsaiStep(dt: f32) void {
    _ = dt;
    const wood = mix(col_warn, col_accent2, 0.5);
    const leaf_a = col_ok;
    const leaf_b = mix(col_ok, col_accent, 0.5);
    var steps: usize = 3;
    while (steps > 0 and walkers.items.len > 0) : (steps -= 1) {
        var i: usize = 0;
        while (i < walkers.items.len) {
            var wk = &walkers.items[i];
            if (wk.life <= 0) {
                // leaves where a shoot ends
                if (wk.kind != 0) for (0..6) |_| {
                    treePut(wk.x + (rnd() - 0.5) * 6, wk.y + (rnd() - 0.5) * 3, if (rnd() < 0.5) '&' else '*', if (rnd() < 0.5) leaf_a else leaf_b);
                };
                _ = walkers.swapRemove(i);
                continue;
            }
            const dy: f32 = if (wk.kind == 0) (if (rnd() < 0.8) -1 else 0) else if (rnd() < 0.35) -1 else 0;
            if (wk.kind == 0) wk.dx = std.math.clamp(wk.dx + (rnd() - 0.5) * 0.6, -1, 1) else wk.dx = std.math.clamp(wk.dx + (rnd() - 0.5) * 0.8, -2, 2);
            const dx = @round(wk.dx);
            wk.x += dx;
            wk.y += dy;
            wk.life -= 1;
            const chr: u21 = if (dy == 0) (if (dx == 0) '_' else '~') else if (dx < 0) '\\' else if (dx > 0) '/' else '|';
            treePut(wk.x, wk.y, chr, if (wk.kind == 2) leaf_b else wood);
            if (wk.kind == 0 and wk.life < @as(f32, @floatFromInt(H)) * 0.38 and rnd() < 0.22 and walkers.items.len < 60) {
                const side: f32 = if (rnd() < 0.5) -1.5 else 1.5;
                walkers.append(alloc, .{ .x = wk.x, .y = wk.y, .dx = side, .life = 8 + rnd() * @as(f32, @floatFromInt(W)) * 0.18, .kind = 1 }) catch {};
            } else if (wk.kind == 1 and rnd() < 0.12 and walkers.items.len < 80) {
                walkers.append(alloc, .{ .x = wk.x, .y = wk.y, .dx = -wk.dx, .life = 3 + rnd() * 6, .kind = 2 }) catch {};
            }
            i += 1;
        }
    }
    if (walkers.items.len == 0 and bonsai_done_at < 0) bonsai_done_at = t_mode;
    if (bonsai_done_at >= 0 and t_mode - bonsai_done_at > 12) bonsaiInit();
    @memcpy(cells, tree);
    // the pot
    const pw: usize = @min(W, 30);
    const px: isize = @intCast((W - pw) / 2);
    const py: isize = @as(isize, @intCast(H)) - 3;
    const pot = col_dim;
    var x: isize = 0;
    while (x < pw) : (x += 1) {
        put(px + x, py, if (x == 0) '\\' else if (x == @as(isize, @intCast(pw)) - 1) '/' else '_', pot);
        if (x > 1 and x < @as(isize, @intCast(pw)) - 2) put(px + x, py + 1, '_', pot);
    }
    put(px + 1, py + 1, '(', pot);
    put(px + @as(isize, @intCast(pw)) - 2, py + 1, ')', pot);
}

// city ------------------------------------------------------
// Two layers of procedural buildings scroll past at different speeds under a
// twinkling sky; windows switch on and off.
const Building = struct { x: f32, w: f32, h: f32, seed: u32 };
var layers: [2]std.ArrayList(Building) = .{ .empty, .empty };
var layer_len: [2]f32 = .{ 0, 0 };
var stars: []struct { x: u16, y: u16, p: f32 } = &.{};
fn hash32(v: u32) u32 {
    var z = v *% 0x9e3779b1;
    z ^= z >> 15;
    z *%= 0x85ebca6b;
    z ^= z >> 13;
    return z;
}
fn cityInit() void {
    for (0..2) |l| {
        layers[l].clearRetainingCapacity();
        var x: f32 = 0;
        const maxh: f32 = @as(f32, @floatFromInt(H)) * (if (l == 0) @as(f32, 0.5) else 0.48);
        while (x < @as(f32, @floatFromInt(W)) * 2) {
            const bw = 5 + rnd() * 9;
            layers[l].append(alloc, .{ .x = x, .w = bw, .h = 4 + rnd() * maxh, .seed = @intFromFloat(rnd() * 1e9) }) catch {};
            x += bw + (if (rnd() < 0.3) 1 + rnd() * 3 else 0);
        }
        layer_len[l] = x;
    }
    if (stars.len > 0) alloc.free(stars);
    stars = alloc.alloc(@TypeOf(stars[0]), W * H / 40 + 1) catch unreachable;
    for (stars) |*s| s.* = .{ .x = @intCast(rndInt(W)), .y = @intCast(rndInt(H * 2 / 3 + 1)), .p = rnd() * 6.28 };
}
fn cityStep(dt: f32) void {
    _ = dt;
    clearCells();
    const t: f32 = @floatCast(t_mode);
    for (stars) |s| {
        const tw = 0.5 + 0.5 * @sin(t * 1.3 + s.p);
        if (tw > 0.25) put(s.x, s.y, if (tw > 0.85) '+' else '.', mix(col_bg, col_fg, tw * 0.7));
    }
    // moon
    const mx: isize = @intCast(W * 4 / 5);
    text(mx, 2, "(", mix(col_bg, col_fg, 0.9));
    text(mx + 1, 2, ")", mix(col_bg, col_fg, 0.5));
    const speeds = [2]f32{ 1.5, 4 };
    const bodies = [2]Rgb{ mix(col_bg, col_dim, 0.45), mix(col_bg, col_dim, 0.9) };
    for (0..2) |l| {
        const off = @mod(t * speeds[l], layer_len[l]);
        for (layers[l].items) |b| {
            var sx = b.x - off;
            if (sx + b.w < 0) sx += layer_len[l];
            if (sx > @as(f32, @floatFromInt(W))) continue;
            const top = @as(f32, @floatFromInt(H)) - b.h;
            var y = top;
            while (y < @as(f32, @floatFromInt(H))) : (y += 1) {
                var x: f32 = 0;
                while (x < b.w) : (x += 1) {
                    const cx = sx + x;
                    if (cx < 0 or cx >= @as(f32, @floatFromInt(W))) continue;
                    const wx: u32 = @intFromFloat(x);
                    const wy: u32 = @intFromFloat(y - top);
                    const window = l == 1 and wx % 2 == 1 and wy % 2 == 1 and x < b.w - 1 and y > top;
                    if (window) {
                        const slot = hash32(b.seed +% wx *% 131 +% wy *% 7919 +% @as(u32, @intFromFloat(t / 7)));
                        const lit = slot % 5 < 2;
                        put(@intFromFloat(cx), @intFromFloat(y), if (lit) 0x25aa else ' ', if (lit) col_warn else bodies[l]);
                    } else {
                        put(@intFromFloat(cx), @intFromFloat(y), 0x2588, bodies[l]);
                    }
                }
            }
            if (l == 1 and hash32(b.seed) % 4 == 0) put(@intFromFloat(sx + @floor(b.w / 2)), @intFromFloat(top - 1), '|', col_accent2);
        }
    }
}

// galaxy ----------------------------------------------------
const Star = struct { r: f32, a: f32, arm: f32, bright: f32 };
var gal: []Star = &.{};
fn galaxyInit() void {
    if (gal.len > 0) alloc.free(gal);
    const n = @min(9000, W * H * 2);
    gal = alloc.alloc(Star, n) catch unreachable;
    for (gal) |*s| {
        const u = rnd();
        s.r = -@log(1 - u * 0.985) * 0.2; // exponential disc: dense core
        s.arm = if (rnd() < 0.5) 0 else std.math.pi;
        // scatter around the arm: tight in the disc, a round bulge at the core
        s.a = (rnd() - 0.5) * (if (s.r < 0.12) @as(f32, 6.28) else 0.5 / (0.4 + s.r));
        s.bright = 0.4 + rnd() * 0.6;
    }
}
fn galaxyStep(dt: f32) void {
    _ = dt;
    @memset(dot_i, 0);
    const t: f32 = @floatCast(t_mode);
    const cx = dotW() / 2;
    const cy = dotH() / 2;
    const scale = @min(dotW(), dotH() * 1.8) * 0.48;
    const tilt: f32 = 0.55;
    const rot = t * 0.03;
    for (gal) |s| {
        // logarithmic arms; inner stars orbit faster (flat-ish rotation curve)
        const theta = s.arm + 2.6 * @log(s.r + 0.05) + s.a - t * (0.12 / (0.15 + s.r)) + rot;
        const x = s.r * @cos(theta);
        const y = s.r * @sin(theta) * tilt;
        const col = mix(col_fg, mix(col_accent2, col_accent, std.math.clamp(s.r * 1.6, 0, 1)), std.math.clamp(s.r * 4, 0, 1));
        dot(cx + x * scale, cy + y * scale, col, s.bright * (1 - std.math.clamp(s.r - 1, 0, 1)));
    }
    disc(cx, cy, 2, col_fg, 1);
    clearCells();
    brailleToCells();
}

// planets ---------------------------------------------------
const Planet = struct { a: f32, e: f32, phase: f32, size: f32, col: Rgb, moon: bool };
var planets: [7]Planet = undefined;
var n_planets: usize = 0;
fn planetsInit() void {
    n_planets = 5 + rndInt(3);
    const cols = [_]Rgb{ col_accent, col_accent2, col_ok, col_warn, col_fg, mix(col_accent, col_ok, 0.5), mix(col_accent2, col_warn, 0.5) };
    for (0..n_planets) |i| {
        const k: f32 = @floatFromInt(i);
        planets[i] = .{ .a = 0.16 + k * 0.13 + rnd() * 0.04, .e = rnd() * 0.12, .phase = rnd() * 6.28, .size = 1 + rnd() * 2.2, .col = cols[i % cols.len], .moon = rnd() < 0.4 };
    }
    @memset(dot_i, 0);
}
fn planetsStep(dt: f32) void {
    _ = dt;
    fadeDots(0.985);
    const t: f32 = @floatCast(t_mode);
    const cx = dotW() / 2;
    const cy = dotH() / 2;
    const scale = @min(dotW(), dotH() * 1.6) * 0.5;
    const tilt: f32 = 0.6;
    for (planets[0..n_planets]) |p| {
        // Kepler: period ∝ a^1.5; eccentric anomaly approximated (small e)
        const m = p.phase + t * 0.9 / std.math.pow(f32, p.a / 0.16, 1.5);
        const r = p.a * (1 - p.e * @cos(m));
        const x = cx + r * @cos(m) * scale;
        const y = cy + r * @sin(m) * scale * tilt;
        dot(x, y, p.col, 0.55); // trail
        disc(x, y, p.size, p.col, 1);
        if (p.moon) {
            const mm = t * 4 + p.phase;
            disc(x + @cos(mm) * (p.size + 4), y + @sin(mm) * (p.size + 4) * tilt, 0.6, col_fg, 1);
        }
    }
    disc(cx, cy, 4, col_warn, 1);
    disc(cx, cy, 2.5, mix(col_warn, col_fg, 0.6), 1);
    clearCells();
    brailleToCells();
}

// threebody -------------------------------------------------
const Orbit = struct { name: []const u8, r: [3][2]f64, v: [3][2]f64, period: f64 };
fn sd(name: []const u8, p1: f64, p2: f64, period: f64) Orbit {
    // Šuvakov–Dmitrašinović family: bodies at (-1,0), (1,0), (0,0),
    // velocities (p1,p2), (p1,p2), (-2p1,-2p2).
    return .{ .name = name, .r = .{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, 0 } }, .v = .{ .{ p1, p2 }, .{ p1, p2 }, .{ -2 * p1, -2 * p2 } }, .period = period };
}
const orbits = [_]Orbit{
    .{ .name = "figure-eight", .r = .{ .{ -0.97000436, 0.24308753 }, .{ 0.97000436, -0.24308753 }, .{ 0, 0 } }, .v = .{ .{ 0.466203685, 0.43236573 }, .{ 0.466203685, 0.43236573 }, .{ -0.93240737, -0.86473146 } }, .period = 6.3259 },
    sd("butterfly I", 0.306893, 0.125507, 6.2356),
    sd("moth I", 0.464445, 0.396060, 14.8939),
    sd("yin-yang Ia", 0.513938, 0.304736, 17.3284),
    sd("goggles", 0.083300, 0.127889, 10.4668),
};
var orbit_i: usize = 0;
var pos: [3][2]f64 = undefined;
var vel: [3][2]f64 = undefined;
var bounds: [4]f64 = .{ -1, 1, -1, 1 };
fn accel(p: [3][2]f64) [3][2]f64 {
    var a: [3][2]f64 = .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } };
    for (0..3) |i| for (0..3) |j| {
        if (i == j) continue;
        const dx = p[j][0] - p[i][0];
        const dy = p[j][1] - p[i][1];
        const d2 = dx * dx + dy * dy + 1e-6;
        const inv = 1 / (d2 * @sqrt(d2));
        a[i][0] += dx * inv;
        a[i][1] += dy * inv;
    };
    return a;
}
fn integrate(simt: f64) void {
    const h = 0.0004;
    var t: f64 = 0;
    while (t < simt) : (t += h) {
        // velocity Verlet
        var a = accel(pos);
        for (0..3) |i| for (0..2) |k| {
            vel[i][k] += 0.5 * h * a[i][k];
            pos[i][k] += h * vel[i][k];
        };
        a = accel(pos);
        for (0..3) |i| for (0..2) |k| {
            vel[i][k] += 0.5 * h * a[i][k];
        };
    }
}
fn threebodyInit() void {
    const o = orbits[orbit_i];
    pos = o.r;
    vel = o.v;
    // bounds from one period, then start over
    bounds = .{ 1e9, -1e9, 1e9, -1e9 };
    var t: f64 = 0;
    while (t < o.period) : (t += o.period / 400) {
        integrate(o.period / 400);
        for (pos) |p| {
            bounds[0] = @min(bounds[0], p[0]);
            bounds[1] = @max(bounds[1], p[0]);
            bounds[2] = @min(bounds[2], p[1]);
            bounds[3] = @max(bounds[3], p[1]);
        }
    }
    pos = o.r;
    vel = o.v;
    @memset(dot_i, 0);
}
fn threebodyStep(dt: f32) void {
    const o = orbits[orbit_i];
    if (t_mode > 75) {
        orbit_i = (orbit_i + 1) % orbits.len;
        t_mode = 0;
        threebodyInit();
    }
    fadeDots(0.992);
    // one period every ~9 s, whatever the orbit
    integrate(@as(f64, dt) * o.period / 9);
    const bw = bounds[1] - bounds[0];
    const bh = bounds[3] - bounds[2];
    const scale = @min(dotW() * 0.8 / bw, dotH() * 0.8 / bh);
    const cx = dotW() / 2 - @as(f32, @floatCast((bounds[0] + bw / 2) * scale));
    const cy = dotH() / 2 - @as(f32, @floatCast((bounds[2] + bh / 2) * scale));
    const cols = [3]Rgb{ col_accent, col_accent2, col_ok };
    for (pos, 0..) |p, i| {
        const x = cx + @as(f32, @floatCast(p[0] * scale));
        const y = cy + @as(f32, @floatCast(p[1] * scale));
        dot(x, y, cols[i], 0.7);
    }
    clearCells();
    brailleToCells();
    for (pos, 0..) |p, i| {
        const x = cx + @as(f32, @floatCast(p[0] * scale));
        const y = cy + @as(f32, @floatCast(p[1] * scale));
        put(@intFromFloat(x / 2), @intFromFloat(y / 4), 0x25cf, cols[i]);
    }
    var buf: [128]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "three-body: {s}  ·  threebodyorbits.com", .{o.name}) catch "";
    text(2, @as(isize, @intCast(H)) - 2, label, col_dim);
}

fn initMode() void {
    t_mode = 0;
    switch (mode) {
        .matrix => matrixInit(),
        .bonsai => bonsaiInit(),
        .city => cityInit(),
        .galaxy => galaxyInit(),
        .planets => planetsInit(),
        .threebody => threebodyInit(),
    }
}
fn stepMode(dt: f32) void {
    switch (mode) {
        .matrix => matrixStep(dt),
        .bonsai => bonsaiStep(dt),
        .city => cityStep(dt),
        .galaxy => galaxyStep(dt),
        .planets => planetsStep(dt),
        .threebody => threebodyStep(dt),
    }
}

// ------------------------------------------------------------ terminal

var saved: c.struct_termios = undefined;
fn restore() void {
    const bye = "\x1b[?1003l\x1b[?1006l\x1b[0m\x1b[?25h\x1b[?1049l";
    _ = c.write(1, bye, bye.len);
    _ = c.tcsetattr(0, c.TCSANOW, &saved);
}
fn termSize() [2]usize {
    var ws: c.struct_winsize = undefined;
    if (c.ioctl(1, c.TIOCGWINSZ, &ws) != 0 or ws.ws_col == 0) return .{ 80, 24 };
    return .{ ws.ws_col, ws.ws_row };
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("jerksaver: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}
fn parseHex(s: []const u8) Rgb {
    const t = std.mem.trimStart(u8, s, "#");
    return hex(std.fmt.parseInt(u32, t, 16) catch fail("bad colour {s}", .{s}));
}

pub fn main(init: std.process.Init.Minimal) !void {
    const args = init.args.vector;
    if (args.len < 2) fail("usage: jerksaver matrix|bonsai|city|galaxy|planets|threebody|random [--title T] [--fps N] [colours]", .{});
    rng_state ^= @as(u64, @intFromFloat(now() * 1e6));
    const m = std.mem.span(args[1]);
    if (std.mem.eql(u8, m, "random")) {
        mode = @enumFromInt(rndInt(@typeInfo(Mode).@"enum".fields.len));
    } else {
        mode = std.meta.stringToEnum(Mode, m) orelse fail("unknown mode {s}", .{m});
    }
    var fps: f64 = 30;
    var i: usize = 2;
    while (i + 1 < args.len) : (i += 2) {
        const k = std.mem.span(args[i]);
        const v = std.mem.span(args[i + 1]);
        if (std.mem.eql(u8, k, "--title")) {
            if (!font.supported(v)) fail("title: letters, digits, space and - _ . : ! ? ' / only", .{});
            title = v;
        } else if (std.mem.eql(u8, k, "--fps")) {
            fps = std.math.clamp(std.fmt.parseFloat(f64, v) catch fail("bad --fps", .{}), 5, 60);
        } else if (std.mem.eql(u8, k, "--bg")) col_bg = parseHex(v)
        else if (std.mem.eql(u8, k, "--fg")) col_fg = parseHex(v)
        else if (std.mem.eql(u8, k, "--dim")) col_dim = parseHex(v)
        else if (std.mem.eql(u8, k, "--accent")) col_accent = parseHex(v)
        else if (std.mem.eql(u8, k, "--accent2")) col_accent2 = parseHex(v)
        else if (std.mem.eql(u8, k, "--ok")) col_ok = parseHex(v)
        else if (std.mem.eql(u8, k, "--warn")) col_warn = parseHex(v)
        else fail("unknown option {s}", .{k});
    }
    if (i < args.len) fail("option {s} needs a value", .{std.mem.span(args[i])});

    // raw input, alternate screen, no cursor, report all mouse motion (SGR)
    _ = c.tcgetattr(0, &saved);
    var raw = saved;
    raw.c_lflag &= ~@as(c.tcflag_t, c.ICANON | c.ECHO);
    raw.c_cc[c.VMIN] = 0;
    raw.c_cc[c.VTIME] = 0;
    _ = c.tcsetattr(0, c.TCSANOW, &raw);
    var hello_buf: [96]u8 = undefined;
    const bgi = [3]u8{ @intFromFloat(col_bg.r), @intFromFloat(col_bg.g), @intFromFloat(col_bg.b) };
    const hello = std.fmt.bufPrint(&hello_buf, "\x1b[?1049h\x1b[?25l\x1b[?1003h\x1b[?1006h\x1b[48;2;{d};{d};{d}m\x1b[2J", .{ bgi[0], bgi[1], bgi[2] }) catch "";
    _ = c.write(1, hello.ptr, hello.len);
    defer restore();

    var sz = termSize();
    resize(sz[0], sz[1]);
    initMode();
    const start = now();
    var last = start;
    var mouse0: ?[2]i32 = null;
    while (true) {
        // input: anything but small mouse jitter ends it (after a grace period)
        var pfd = c.struct_pollfd{ .fd = 0, .events = c.POLLIN, .revents = 0 };
        const frame_ms: c_int = @intFromFloat(1000 / fps);
        if (c.poll(&pfd, 1, frame_ms) > 0) {
            var ib: [256]u8 = undefined;
            const n = c.read(0, &ib, ib.len);
            if (n > 0 and now() - start > 1.0) {
                const in = ib[0..@intCast(n)];
                // SGR mouse: ESC [ < b ; x ; y (M|m); motion has bit 32 in b
                if (std.mem.startsWith(u8, in, "\x1b[<")) {
                    var it = std.mem.tokenizeAny(u8, in[3..], ";Mm");
                    const b = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0;
                    const mx = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0;
                    const my = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0;
                    if (b & 32 == 0) return; // a click or scroll
                    if (mouse0) |m0| {
                        if (@abs(mx - m0[0]) + @abs(my - m0[1]) > 3) return;
                    } else mouse0 = .{ mx, my };
                } else return; // a key
            }
        }
        const t = now();
        const dt: f32 = @floatCast(@min(0.1, t - last));
        last = t;
        t_mode += dt;
        const nsz = termSize();
        if (nsz[0] != sz[0] or nsz[1] != sz[1]) {
            sz = nsz;
            resize(sz[0], sz[1]);
            initMode();
        }
        stepMode(dt);
        drawTitle();
        flush();
    }
}
