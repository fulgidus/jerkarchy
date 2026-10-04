//! jerkprompt — a one-line text input for the settings menu, with a live
//! "n left" counter. fuzzel can't count or restrict what you type, so a
//! limit would only show up as an error after the fact; here characters
//! outside --allow simply don't type and input stops at --max.
//!
//!   jerkprompt --out FILE [--prompt TEXT] [--initial TEXT] [--max N]
//!              [--allow CHARS] [--hint TEXT] [--accent RRGGBB --fg … --dim …]
//!
//! Enter writes the text to FILE and exits 0; Esc exits 1 without writing.
//! Runs in a small terminal (text-prompt opens one under the bar).
const std = @import("std");
const c = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("poll.h");
});

fn fail(msg: []const u8) noreturn {
    std.debug.print("jerkprompt: {s}\n", .{msg});
    std.process.exit(2);
}

fn sgr(buf: []u8, hexs: []const u8) []const u8 {
    const v = std.fmt.parseInt(u32, std.mem.trimStart(u8, hexs, "#"), 16) catch fail("bad colour");
    return std.fmt.bufPrint(buf, "\x1b[38;2;{d};{d};{d}m", .{ (v >> 16) & 255, (v >> 8) & 255, v & 255 }) catch "";
}

fn out(s: []const u8) void {
    _ = c.write(1, s.ptr, s.len);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const args = init.args.vector;
    var out_path: ?[*:0]const u8 = null;
    var prompt: []const u8 = "›";
    var initial: []const u8 = "";
    var hint: []const u8 = "enter: save · esc: cancel";
    var allow: ?[]const u8 = null;
    var max: usize = 64;
    var accent: []const u8 = "00f0ff";
    var fg: []const u8 = "e5e1e7";
    var dim: []const u8 = "55556a";
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        const k = std.mem.span(args[i]);
        const v = std.mem.span(args[i + 1]);
        if (std.mem.eql(u8, k, "--out")) out_path = args[i + 1]
        else if (std.mem.eql(u8, k, "--prompt")) prompt = v
        else if (std.mem.eql(u8, k, "--initial")) initial = v
        else if (std.mem.eql(u8, k, "--hint")) hint = v
        else if (std.mem.eql(u8, k, "--allow")) allow = v
        else if (std.mem.eql(u8, k, "--max")) max = std.math.clamp(std.fmt.parseInt(usize, v, 10) catch fail("bad --max"), 1, 256)
        else if (std.mem.eql(u8, k, "--accent")) accent = v
        else if (std.mem.eql(u8, k, "--fg")) fg = v
        else if (std.mem.eql(u8, k, "--dim")) dim = v
        else fail("unknown option");
    }
    if (i != args.len or out_path == null) fail("usage: jerkprompt --out FILE [--prompt T] [--initial T] [--max N] [--allow CHARS] [--hint T]");

    var text: [256]u8 = undefined;
    var len: usize = 0;
    for (initial) |ch| if (len < max and (allow == null or std.mem.indexOfScalar(u8, allow.?, ch) != null)) {
        text[len] = ch;
        len += 1;
    };

    var saved: c.struct_termios = undefined;
    _ = c.tcgetattr(0, &saved);
    var raw = saved;
    raw.c_lflag &= ~@as(c.tcflag_t, c.ICANON | c.ECHO | c.ISIG);
    raw.c_cc[c.VMIN] = 1;
    raw.c_cc[c.VTIME] = 0;
    _ = c.tcsetattr(0, c.TCSANOW, &raw);
    defer _ = c.tcsetattr(0, c.TCSANOW, &saved);

    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    var b3: [32]u8 = undefined;
    const c_accent = sgr(&b1, accent);
    const c_fg = sgr(&b2, fg);
    const c_dim = sgr(&b3, dim);
    out("\x1b[?25l");

    while (true) {
        // line 1: prompt, text, cursor block, counter; line 2: hint
        var line: [1024]u8 = undefined;
        const left = max - len;
        const shown = std.fmt.bufPrint(&line, "\x1b[H\x1b[2J {s}{s} {s}{s}{s}\u{2588}  {s}{d} left\r\n {s}{s}", .{
            c_accent, prompt, c_fg, text[0..len], c_accent, if (left == 0) c_accent else c_dim, left, c_dim, hint,
        }) catch "";
        out(shown);

        var ib: [16]u8 = undefined;
        const n = c.read(0, &ib, ib.len);
        if (n <= 0) return;
        const in = ib[0..@intCast(n)];
        if (in[0] == 0x1b) {
            if (in.len == 1) std.process.exit(1); // Esc alone: cancel
            continue; // arrows and other sequences: ignored
        }
        for (in) |ch| switch (ch) {
            '\r', '\n' => {
                const fd = std.c.open(out_path.?, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o600));
                if (fd >= 0) {
                    _ = c.write(fd, &text, len);
                    _ = c.close(fd);
                }
                return;
            },
            127, 8 => len -|= 1, // backspace
            21 => len = 0, // ctrl-u
            3 => std.process.exit(1), // ctrl-c
            else => if (ch >= 0x20 and ch < 0x7f and len < max and
                (allow == null or std.mem.indexOfScalar(u8, allow.?, ch) != null))
            {
                text[len] = ch;
                len += 1;
            },
        };
    }
}
