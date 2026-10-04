//! vkbd — test helper: press and release one key on a Wayland compositor
//! through zwp_virtual_keyboard_v1. Used by the tests to poke clients running
//! in a throwaway headless sway (e.g. dismissing the screensaver) without
//! going near the real keyboard: ydotool and friends type into the live
//! session.
//!
//!   WAYLAND_DISPLAY=wayland-N vkbd [KEYCODE]     (evdev code, default 30 = A)
const std = @import("std");
const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("sys/mman.h");
    @cInclude("unistd.h");
    @cInclude("string.h");
    @cInclude("wayland-client.h");
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("virtual-keyboard-unstable-v1-client-protocol.h");
});

var seat: ?*c.wl_seat = null;
var manager: ?*c.zwp_virtual_keyboard_manager_v1 = null;

fn global(_: ?*anyopaque, reg: ?*c.wl_registry, name: u32, iface: [*c]const u8, _: u32) callconv(.c) void {
    const i = std.mem.span(iface);
    if (std.mem.eql(u8, i, "wl_seat") and seat == null) {
        seat = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_seat_interface, 1));
    } else if (std.mem.eql(u8, i, "zwp_virtual_keyboard_manager_v1")) {
        manager = @ptrCast(c.wl_registry_bind(reg, name, &c.zwp_virtual_keyboard_manager_v1_interface, 1));
    }
}
fn globalRemove(_: ?*anyopaque, _: ?*c.wl_registry, _: u32) callconv(.c) void {}
const listener = c.wl_registry_listener{ .global = global, .global_remove = globalRemove };

fn die(msg: []const u8) noreturn {
    std.debug.print("vkbd: {s}\n", .{msg});
    std.process.exit(1);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const args = init.args.vector;
    const key: u32 = if (args.len > 1) std.fmt.parseInt(u32, std.mem.span(args[1]), 10) catch die("bad keycode") else 30;

    const display = c.wl_display_connect(null) orelse die("cannot connect to Wayland display");
    const reg = c.wl_display_get_registry(display);
    _ = c.wl_registry_add_listener(reg, &listener, null);
    _ = c.wl_display_roundtrip(display);
    if (seat == null or manager == null) die("compositor lacks wl_seat or zwp_virtual_keyboard_manager_v1");

    // A virtual keyboard must upload a keymap before sending keys.
    const ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse die("xkb context");
    const names = c.xkb_rule_names{ .rules = null, .model = null, .layout = "us", .variant = null, .options = null };
    const km = c.xkb_keymap_new_from_names(ctx, &names, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse die("xkb keymap");
    const str = c.xkb_keymap_get_as_string(km, c.XKB_KEYMAP_FORMAT_TEXT_V1) orelse die("xkb keymap string");
    const len = c.strlen(str) + 1;
    const fd = c.memfd_create("vkbd-keymap", c.MFD_CLOEXEC);
    if (fd < 0) die("memfd");
    if (c.write(fd, str, len) != @as(isize, @intCast(len))) die("write keymap");

    const kb = c.zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(manager, seat) orelse die("create keyboard");
    c.zwp_virtual_keyboard_v1_keymap(kb, c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, @intCast(len));
    _ = c.wl_display_roundtrip(display);
    // A headless seat gains its keyboard capability only now: give clients a
    // moment to bind the new wl_keyboard before the key arrives.
    _ = c.usleep(300_000);
    _ = c.wl_display_roundtrip(display);
    c.zwp_virtual_keyboard_v1_key(kb, 0, key, c.WL_KEYBOARD_KEY_STATE_PRESSED);
    _ = c.wl_display_roundtrip(display);
    c.zwp_virtual_keyboard_v1_key(kb, 10, key, c.WL_KEYBOARD_KEY_STATE_RELEASED);
    _ = c.wl_display_roundtrip(display);
    c.zwp_virtual_keyboard_v1_destroy(kb);
    _ = c.wl_display_roundtrip(display);
}
