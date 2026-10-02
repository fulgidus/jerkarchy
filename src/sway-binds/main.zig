//! sway-binds — list sway keybindings, derived from the sway config.
//!
//!   sway-binds [--md] [config]      (default: ~/.config/sway/config)
//!
//! Parses the config statically (it's declarative, nothing is executed):
//! `set $var value` substitution, `\` line continuations, `mode "x" { }`
//! blocks and every `bindsym` line. From the config text it also takes:
//!   * section titles: a `# Title` comment between two `# ----` banners
//!   * optional descriptions: a `#: text` comment directly above a bindsym
//! Anything else is described from the sway command. `include` is not
//! followed (system config.d snippets don't define bindings).

const std = @import("std");
const Allocator = std.mem.Allocator;

const Fold = enum { none, digit, arrow };

const Bind = struct {
    line: u32, // 1-based line of the bindsym
    mode: []const u8,
    mods: []const []const u8,
    key: []const u8,
    locked: bool,
    release: bool,
    command: []const u8,
};

const Section = struct { line: u32, title: []const u8 };
const Desc = struct { text: []const u8, fold: Fold };

const Group = struct {
    mode: []const u8,
    mods: []const u8,
    locked: bool,
    release: bool,
    desc: Desc,
    keys: std.ArrayList([]const u8) = .empty,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = init.minimal.args.vector;

    var markdown = false;
    var path: ?[]const u8 = null;
    for (argv[1..]) |raw| {
        const a = std.mem.span(raw);
        if (std.mem.eql(u8, a, "--md")) markdown = true else if (path == null) path = a else usage();
    }
    const config_path = path orelse blk: {
        const home = init.environ_map.get("HOME") orelse usage();
        break :blk try std.fmt.allocPrint(arena, "{s}/.config/sway/config", .{home});
    };

    const src = try std.Io.Dir.cwd().readFileAlloc(io, config_path, arena, .limited(1 << 20));
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |l| try lines.append(arena, l);

    const sections = try findSections(arena, lines.items);
    const binds = try parseConfig(arena, lines.items);

    var out_buf: [8192]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &out_buf);
    const w = &fw.interface;

    if (markdown) {
        try w.print("# sway bindings\n\n_Generated from `{s}`._\n", .{config_path});
    } else {
        try w.print("\x1b[1;96msway bindings\x1b[0m  \x1b[2mgenerated from {s}  ·  q to close\x1b[0m\n", .{config_path});
    }

    var s_index: usize = 0;
    while (s_index <= sections.len) : (s_index += 1) {
        const lo: u32 = if (s_index == 0) 0 else sections[s_index - 1].line;
        const hi: u32 = if (s_index < sections.len) sections[s_index].line else std.math.maxInt(u32);
        const title = if (s_index == 0) "General" else sections[s_index - 1].title;

        var groups: std.ArrayList(Group) = .empty;
        for (binds) |b| {
            if (b.line < lo or b.line >= hi) continue;
            const desc = try describe(arena, b, lines.items);
            const mods = try renderMods(arena, b.mods);
            const g = for (groups.items) |*g| {
                if (std.mem.eql(u8, g.mode, b.mode) and std.mem.eql(u8, g.mods, mods) and
                    g.locked == b.locked and g.release == b.release and
                    g.desc.fold == desc.fold and std.mem.eql(u8, g.desc.text, desc.text)) break g;
            } else blk: {
                try groups.append(arena, .{ .mode = b.mode, .mods = mods, .locked = b.locked, .release = b.release, .desc = desc });
                break :blk &groups.items[groups.items.len - 1];
            };
            try g.keys.append(arena, b.key);
        }
        if (groups.items.len == 0) continue;

        const Row = struct { key: []const u8, text: []const u8, note: []const u8 };
        var rows: std.ArrayList(Row) = .empty;
        var width: usize = 0;
        for (groups.items) |g| {
            const key = try renderKey(arena, g);
            const text = try renderText(arena, g);
            var note: []const u8 = "";
            if (!std.mem.eql(u8, g.mode, "default")) note = try std.fmt.allocPrint(arena, "[{s} mode]", .{g.mode});
            if (g.locked) note = try std.fmt.allocPrint(arena, "{s}[also when locked]", .{note});
            if (g.release) note = try std.fmt.allocPrint(arena, "{s}[on release]", .{note});
            try rows.append(arena, .{ .key = key, .text = text, .note = note });
            width = @max(width, displayWidth(key));
        }

        if (markdown) {
            try w.print("\n## {s}\n\n| Key | Action |\n|---|---|\n", .{title});
            for (rows.items) |r| {
                try w.print("| `{s}` | {s}", .{ r.key, r.text });
                if (r.note.len > 0) try w.print(" _{s}_", .{r.note});
                try w.writeAll(" |\n");
            }
        } else {
            try w.print("\n\x1b[1;96m▌ {s}\x1b[0m\n", .{title});
            for (rows.items) |r| {
                try w.print("  \x1b[95m{s}\x1b[0m", .{r.key});
                for (0..width - displayWidth(r.key) + 2) |_| try w.writeByte(' ');
                try w.writeAll(r.text);
                if (r.note.len > 0) try w.print("  \x1b[2m{s}\x1b[0m", .{r.note});
                try w.writeByte('\n');
            }
        }
    }
    try w.flush();
}

fn usage() noreturn {
    std.debug.print("usage: sway-binds [--md] [config]\n", .{});
    std.process.exit(2);
}

fn trimmed(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

fn isBanner(l: []const u8) bool {
    return std.mem.startsWith(u8, trimmed(l), "# ---");
}

fn findSections(arena: Allocator, lines: []const []const u8) ![]Section {
    var list: std.ArrayList(Section) = .empty;
    if (lines.len < 3) return list.items;
    for (1..lines.len - 1) |i| {
        const t = trimmed(lines[i]);
        if (!isBanner(lines[i - 1]) or !isBanner(lines[i + 1])) continue;
        if (!std.mem.startsWith(u8, t, "# ") or isBanner(t)) continue;
        try list.append(arena, .{ .line = @intCast(i + 1), .title = trimmed(t[2..]) });
    }
    return list.items;
}

const Var = struct { name: []const u8, value: []const u8 };

fn parseConfig(arena: Allocator, lines: []const []const u8) ![]Bind {
    var vars: std.ArrayList(Var) = .empty;
    var modes: std.ArrayList([]const u8) = .empty; // stack; empty = "default"
    var binds: std.ArrayList(Bind) = .empty;

    var i: usize = 0;
    while (i < lines.len) : (i += 1) {
        const start_line: u32 = @intCast(i + 1);
        // Join `\` continuations.
        var logical: std.ArrayList(u8) = .empty;
        var cur = trimmed(lines[i]);
        while (cur.len > 0 and cur[cur.len - 1] == '\\' and i + 1 < lines.len) {
            try logical.appendSlice(arena, trimmed(cur[0 .. cur.len - 1]));
            try logical.append(arena, ' ');
            i += 1;
            cur = trimmed(lines[i]);
        }
        try logical.appendSlice(arena, cur);
        const line = trimmed(logical.items);
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.eql(u8, line, "}")) {
            if (modes.items.len > 0) _ = modes.pop();
            continue;
        }
        if (std.mem.startsWith(u8, line, "set ")) {
            var toks = std.mem.tokenizeAny(u8, line[4..], " \t");
            const name = toks.next() orelse continue;
            const value = trimmed(toks.rest());
            try vars.append(arena, .{ .name = name, .value = try expand(arena, value, vars.items) });
            continue;
        }
        if (std.mem.startsWith(u8, line, "mode ") and line[line.len - 1] == '{') {
            const name = std.mem.trim(u8, trimmed(line[5 .. line.len - 1]), "\"");
            try modes.append(arena, try expand(arena, name, vars.items));
            continue;
        }
        if (line[line.len - 1] == '{') {
            try modes.append(arena, if (modes.items.len > 0) modes.items[modes.items.len - 1] else "default");
            continue;
        }
        if (!std.mem.startsWith(u8, line, "bindsym ")) continue;

        const expanded = try expand(arena, line["bindsym ".len..], vars.items);
        var toks = std.mem.tokenizeAny(u8, expanded, " \t");
        var locked = false;
        var release = false;
        var combo: []const u8 = "";
        while (toks.next()) |t| {
            if (std.mem.startsWith(u8, t, "--")) {
                if (std.mem.eql(u8, t, "--locked")) locked = true;
                if (std.mem.eql(u8, t, "--release")) release = true;
                continue;
            }
            combo = t;
            break;
        }
        if (combo.len == 0) continue;
        const command = trimmed(toks.rest());

        var parts: std.ArrayList([]const u8) = .empty;
        var p = std.mem.splitScalar(u8, combo, '+');
        while (p.next()) |part| try parts.append(arena, part);
        const key = parts.pop() orelse continue;

        try binds.append(arena, .{
            .line = start_line,
            .mode = if (modes.items.len > 0) modes.items[modes.items.len - 1] else "default",
            .mods = parts.items,
            .key = key,
            .locked = locked,
            .release = release,
            .command = command,
        });
    }
    return binds.items;
}

/// Substitute `$name` variables, longest names first (sway semantics).
fn expand(arena: Allocator, s: []const u8, vars: []const Var) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '$') == null) return s;
    const sorted = try arena.dupe(Var, vars);
    std.mem.sort(Var, sorted, {}, struct {
        fn lt(_: void, a: Var, b: Var) bool {
            return a.name.len > b.name.len;
        }
    }.lt);
    var out: []const u8 = s;
    for (sorted) |v| out = try std.mem.replaceOwned(u8, arena, out, v.name, v.value);
    return out;
}

/// `#: text` in the comment block directly above the bindsym.
fn annotation(lines: []const []const u8, line: u32) ?[]const u8 {
    var i: usize = line - 1;
    while (i > 0) {
        i -= 1;
        const t = trimmed(lines[i]);
        if (t.len == 0) continue;
        if (t[0] != '#') return null;
        if (std.mem.startsWith(u8, t, "#:")) return trimmed(t[2..]);
    }
    return null;
}

fn isArrow(k: []const u8) bool {
    for ([_][]const u8{ "Left", "Right", "Up", "Down" }) |a| if (std.mem.eql(u8, k, a)) return true;
    return false;
}

fn describe(arena: Allocator, b: Bind, lines: []const []const u8) !Desc {
    if (annotation(lines, b.line)) |text| return .{ .text = text, .fold = .none };
    const cmd = b.command;
    const eql = std.mem.eql;

    const digit_key = b.key.len == 1 and b.key[0] >= '1' and b.key[0] <= '9';
    const Num = struct { []const u8, []const u8 };
    const numbered = [_]Num{
        .{ "workspace number ", "go to workspace #" },
        .{ "move container to workspace number ", "move window to workspace #" },
    };
    for (numbered) |n| if (digit_key and std.mem.startsWith(u8, cmd, n[0]) and eql(u8, trimmed(cmd[n[0].len..]), b.key))
        return .{ .text = n[1], .fold = .digit };

    const Dir = struct { []const u8, []const u8 };
    const directional = [_]Dir{ .{ "focus ", "focus window #" }, .{ "move ", "move window #" } };
    for (directional) |d| if (std.mem.startsWith(u8, cmd, d[0]) and isArrow(b.key) and
        std.ascii.eqlIgnoreCase(trimmed(cmd[d[0].len..]), b.key))
        return .{ .text = d[1], .fold = .arrow };

    const simple = [_]struct { []const u8, []const u8 }{
        .{ "kill", "close window" },
        .{ "fullscreen toggle", "toggle fullscreen" },
        .{ "floating toggle", "toggle floating" },
        .{ "sticky toggle", "toggle sticky (all workspaces)" },
        .{ "reload", "reload sway config" },
        .{ "exit", "exit sway" },
        .{ "scratchpad show", "show/hide scratchpad" },
        .{ "move scratchpad", "move window to scratchpad" },
        .{ "splith", "split horizontally" },
        .{ "splitv", "split vertically" },
        .{ "focus parent", "focus parent container" },
        .{ "focus child", "focus child container" },
    };
    for (simple) |s| if (eql(u8, cmd, s[0])) return .{ .text = s[1], .fold = .none };

    if (std.mem.startsWith(u8, cmd, "exec ")) return .{ .text = try prettyCommand(arena, cmd[5..]), .fold = .none };
    return .{ .text = cmd, .fold = .none };
}

/// Shell command → short readable text: drop `pkill x ||` toggle prefixes,
/// reduce paths (/… or ~/…) to basenames, cap the length.
fn prettyCommand(arena: Allocator, raw: []const u8) ![]const u8 {
    var s = trimmed(raw);
    if (std.mem.startsWith(u8, s, "pkill ")) {
        if (std.mem.indexOf(u8, s, " || ")) |i| s = s[i + 4 ..];
    }
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "run ");
    var toks = std.mem.tokenizeScalar(u8, s, ' ');
    var first = true;
    while (toks.next()) |t| {
        if (!first) try out.append(arena, ' ');
        first = false;
        const is_path = t.len > 1 and (t[0] == '/' or std.mem.startsWith(u8, t, "~/"));
        try out.appendSlice(arena, if (is_path) std.fs.path.basename(t) else t);
    }
    const max = 64;
    if ((std.unicode.utf8CountCodepoints(out.items) catch out.items.len) > max) {
        var cut: usize = max;
        while (cut > 0 and (out.items[cut] & 0xC0) == 0x80) cut -= 1;
        out.shrinkRetainingCapacity(cut);
        try out.appendSlice(arena, "…");
    }
    return out.items;
}

fn renderMods(arena: Allocator, mods: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (mods) |m| {
        const name = if (std.mem.eql(u8, m, "Mod4")) "Super" else if (std.mem.eql(u8, m, "Mod1")) "Alt" else if (std.ascii.eqlIgnoreCase(m, "Control") or std.ascii.eqlIgnoreCase(m, "Ctrl")) "Ctrl" else m;
        try out.appendSlice(arena, name);
        try out.append(arena, '+');
    }
    return out.items;
}

fn prettyKey(arena: Allocator, k: []const u8) ![]const u8 {
    const table = [_]struct { []const u8, []const u8 }{
        .{ "Return", "Enter" },                    .{ "Escape", "Esc" },
        .{ "Left", "←" },                          .{ "Right", "→" },
        .{ "Up", "↑" },                            .{ "Down", "↓" },
        .{ "Prior", "PgUp" },                      .{ "Next", "PgDn" },
        .{ "Page_Up", "PgUp" },                    .{ "Page_Down", "PgDn" },
        .{ "minus", "-" },                         .{ "equal", "=" },
        .{ "backslash", "\\" },                    .{ "space", "Space" },
        .{ "period", "." },                        .{ "comma", "," },
        .{ "Delete", "Del" },                      .{ "Tab", "Tab" },
        .{ "button4", "ScrollUp" },                .{ "button5", "ScrollDown" },
        .{ "XF86AudioRaiseVolume", "VolumeUp" },   .{ "XF86AudioLowerVolume", "VolumeDown" },
        .{ "XF86AudioMute", "Mute" },              .{ "XF86AudioMicMute", "MicMute" },
        .{ "XF86AudioPlay", "Play" },              .{ "XF86AudioPause", "Pause" },
        .{ "XF86AudioNext", "Next" },              .{ "XF86AudioPrev", "Prev" },
        .{ "XF86MonBrightnessUp", "BrightnessUp" }, .{ "XF86MonBrightnessDown", "BrightnessDown" },
    };
    for (table) |e| if (std.mem.eql(u8, k, e[0])) return e[1];
    if (std.mem.startsWith(u8, k, "XF86")) return k[4..];
    if (k.len == 1) return std.ascii.allocUpperString(arena, k);
    return k;
}

fn renderKey(arena: Allocator, g: Group) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, g.mods);
    const keys = g.keys.items;
    if (g.desc.fold == .digit and keys.len > 1 and contiguousDigits(keys)) {
        try out.print(arena, "{s}–{s}", .{ keys[0], keys[keys.len - 1] });
    } else {
        const sep: []const u8 = if (g.desc.fold == .arrow) "" else " / ";
        for (keys, 0..) |k, i| {
            if (i > 0) try out.appendSlice(arena, sep);
            try out.appendSlice(arena, try prettyKey(arena, k));
        }
    }
    return out.items;
}

fn contiguousDigits(keys: []const []const u8) bool {
    for (keys[1..], 1..) |k, i| if (k[0] != keys[i - 1][0] + 1) return false;
    return true;
}

fn renderText(arena: Allocator, g: Group) ![]const u8 {
    const many = g.keys.items.len > 1;
    const fill: []const u8 = switch (g.desc.fold) {
        .none => return g.desc.text,
        .digit => if (many) "N" else g.keys.items[0],
        .arrow => if (many) "in that direction" else try std.ascii.allocLowerString(arena, g.keys.items[0]),
    };
    return std.mem.replaceOwned(u8, arena, g.desc.text, "#", fill);
}

fn displayWidth(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}
