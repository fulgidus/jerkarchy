#!/usr/bin/env bash
# ci/headless-sway.sh CONFIG [SECONDS] — start a throwaway headless sway for
# tests and print "WAYLAND_DISPLAY SWAYSOCK PID" once it answers IPC.
# Never touches the live session (no config.d include, no env export —
# the caller's config must be trimmed accordingly). Killed after SECONDS (60).
# Gets its own D-Bus session: test clients on the user's bus have posted
# notifications there and crashed the live waybar (GApplication uniqueness).
set -euo pipefail
cfg=$1; ttl=${2:-60}
log=$(mktemp "${TMPDIR:-/tmp}/headless-sway.XXXXXX.log")
# HEADLESS_RENDERER=gles2 to test GPU clients (default pixman: works without a GPU)
read -r bus dpid < <(dbus-daemon --session --fork --print-address=1 --print-pid=1 | paste -s -d' ')
DBUS_SESSION_BUS_ADDRESS=$bus WLR_BACKENDS=headless WLR_RENDERER=${HEADLESS_RENDERER:-pixman} WLR_LIBINPUT_NO_DEVICES=1 \
    sway -c "$cfg" >"$log" 2>&1 &
pid=$!
( sleep "$ttl"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
# The private bus goes away with sway.
( while kill -0 "$pid" 2>/dev/null; do sleep 1; done; kill "$dpid" 2>/dev/null ) >/dev/null 2>&1 &
sock="$XDG_RUNTIME_DIR/sway-ipc.$(id -u).$pid.sock"
for _ in $(seq 1 100); do
    kill -0 "$pid" 2>/dev/null || { echo "headless sway died, log: $log" >&2; exit 1; }
    if [ -S "$sock" ] && SWAYSOCK=$sock swaymsg -t get_version >/dev/null 2>&1; then
        out=$(mktemp "${TMPDIR:-/tmp}/headless-sway.XXXXXX")
        SWAYSOCK=$sock swaymsg -q "exec sh -c 'echo \$WAYLAND_DISPLAY > $out'"
        for _ in $(seq 1 50); do [ -s "$out" ] && break; sleep 0.1; done
        echo "$(cat "$out") $sock $pid"; rm -f "$out"; exit 0
    fi
    sleep 0.1
done
echo "headless sway never answered IPC, log: $log" >&2; kill "$pid"; exit 1
