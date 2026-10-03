#!/usr/bin/env bash
# ci/vm-test.sh — end-to-end install test in a throwaway VM.
#
# Boots the official Arch cloud image (pinned build, checksum-verified) in
# QEMU/KVM, points pacman at the SNAPSHOT date, runs install.sh from the
# current commit, then starts sway headless and checks that the desktop comes
# up (bar, notifications, drawer, autotiling). Saves a screenshot.
#
#   ci/vm-test.sh [--keep]     --keep: leave the VM running at the end (ssh hint printed)
#
# Needs: qemu-system-x86_64, qemu-img, KVM, python3, ssh, curl. ~4 GB RAM, ~6 GB disk.
# Cache: ${XDG_CACHE_HOME:-~/.cache}/jerkarchy-vm (base image; run dirs, removed
# afterwards unless --keep). Logs: $VM_TEST_OUT (default: the run dir).
set -euo pipefail

IMAGE_BUILD=20261001.604814
IMAGE=Arch-Linux-x86_64-cloudimg-$IMAGE_BUILD.qcow2
IMAGE_URL=https://geo.mirror.pkgbuild.com/images/v$IMAGE_BUILD/$IMAGE
IMAGE_SHA256=360f0fa49db6813bdc8e35bed230a2dc2ae3567b7b5ab74719c0a706e4e34e87

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/jerkarchy-vm
KEEP=0; [ "${1:-}" = --keep ] && KEEP=1
# On disk, not in /tmp: the guest's disk grows by GBs, and a full tmpfs
# froze the guest mid-install (writes fail, ssh dies) without an error.
mkdir -p "$CACHE"
RUN=$(mktemp -d "$CACHE/run.XXXXXX")
OUT=${VM_TEST_OUT:-$RUN/out}; mkdir -p "$OUT"
SNAPSHOT=$(cat "$ROOT/SNAPSHOT")

say()  { printf '\033[1;96m::\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

QEMU_PID="" HTTP_PID=""
cleanup() {
    cp "$RUN/serial.log" "$OUT/serial.log" 2>/dev/null || true
    [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null || true
    if [ "$KEEP" = 0 ]; then
        [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null; sleep 1; rm -rf "$RUN"
    fi
}
trap cleanup EXIT

[ -w /dev/kvm ] || die "no access to /dev/kvm"
for t in qemu-system-x86_64 qemu-img python3 ssh scp curl git; do command -v $t >/dev/null || die "$t missing"; done

# --- base image (cached, verified) -------------------------------------------
mkdir -p "$CACHE"
if ! echo "$IMAGE_SHA256  $CACHE/$IMAGE" | sha256sum -c --status 2>/dev/null; then
    say "downloading $IMAGE"
    curl -fL --progress-bar -o "$CACHE/$IMAGE.part" "$IMAGE_URL"
    echo "$IMAGE_SHA256  $CACHE/$IMAGE.part" | sha256sum -c --status || die "checksum mismatch"
    mv "$CACHE/$IMAGE.part" "$CACHE/$IMAGE"
fi
qemu-img create -q -f qcow2 -F qcow2 -b "$CACHE/$IMAGE" "$RUN/disk.qcow2" 20G

# --- cloud-init over HTTP (NoCloud via SMBIOS; no ISO tooling needed) ----------
ssh-keygen -q -t ed25519 -N '' -f "$RUN/key"
mkdir -p "$RUN/seed"
cat > "$RUN/seed/user-data" <<EOF
#cloud-config
users:
  - name: arch
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys: ["$(cat "$RUN/key.pub")"]
EOF
printf 'instance-id: jerkarchy-vm\nlocal-hostname: jerkarchy-vm\n' > "$RUN/seed/meta-data"
HTTP_PORT=$(free_port); SSH_PORT=$(free_port)
python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$RUN/seed" >"$RUN/http.log" 2>&1 &
HTTP_PID=$!

say "booting VM (ssh on localhost:$SSH_PORT)"
qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 4096 -nographic \
    -drive "file=$RUN/disk.qcow2,if=virtio" \
    -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" \
    -smbios "type=1,serial=ds=nocloud;s=http://10.0.2.2:$HTTP_PORT/" \
    -serial "file:$RUN/serial.log" -monitor none -display none >/dev/null 2>&1 &
QEMU_PID=$!

SSH=(ssh -q -i "$RUN/key" -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 arch@127.0.0.1)
# Bounded: with QEMU's user networking the TCP connect always succeeds, so a
# dead guest network hangs ssh at the banner and ConnectTimeout never fires.
vm() { timeout "${VM_TIMEOUT:-90}" "${SSH[@]}" "$@"; }

for _ in $(seq 1 60); do vm true 2>/dev/null && break; kill -0 "$QEMU_PID" 2>/dev/null || die "QEMU exited (see $RUN/serial.log)"; sleep 3; done
vm true || die "VM never came up on ssh (see $RUN/serial.log)"
VM_TIMEOUT=600 vm 'sudo cloud-init status --wait >/dev/null 2>&1 || true'
# Keep the user's systemd instance and /run/user/<uid> alive between ssh calls
# (sway, its IPC socket and sway-session.target live there).
vm 'sudo loginctl enable-linger arch'
# Stream the guest journal to the serial console: if the guest's network
# dies, $RUN/serial.log (copied to $OUT) still says why.
vm "sudo systemd-run -q --unit=jerkarchy-journal sh -c 'journalctl -f -o short-monotonic >/dev/ttyS0 2>&1'"
say "VM up"

# --- pin pacman to SNAPSHOT, ship the current commit ---------------------------
say "pinning pacman to SNAPSHOT $SNAPSHOT"
VM_TIMEOUT=1800 vm "echo 'Server = https://archive.archlinux.org/repos/${SNAPSHOT//-//}/\$repo/os/\$arch' | sudo tee /etc/pacman.d/mirrorlist >/dev/null
    sudo pacman -Syyuu --noconfirm >/dev/null"

git -C "$ROOT" bundle create -q "$RUN/repo.bundle" HEAD
scp -q -i "$RUN/key" -P "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$RUN/repo.bundle" "$ROOT/install.sh" arch@127.0.0.1:

# --- the actual test: install.sh, unattended ------------------------------------
say "running install.sh in the VM (log: $OUT/install.log)"
# Run detached so a network reconfiguration (NetworkManager taking over) can't kill it.
vm 'nohup env JERKARCHY_REPO=$HOME/repo.bundle bash ./install.sh >install.log 2>&1; echo $? >install.rc' \
    </dev/null >/dev/null 2>&1 &
for _ in $(seq 1 240); do
    sleep 5
    rc=$(vm 'cat install.rc 2>/dev/null' 2>/dev/null || true)
    [ -n "$rc" ] && break
done
vm 'cat install.log' >"$OUT/install.log" 2>/dev/null || true
[ "${rc:-}" = 0 ] || { tail -30 "$OUT/install.log"; die "install.sh failed (rc=${rc:-timeout})"; }
say "install.sh finished"

# --- headless desktop smoke test ---------------------------------------------------
say "starting sway headless"
# Use the user's real session bus (linger keeps systemd --user and dbus up),
# so user services (pipewire, portals, sway-session.target) behave as at login.
vm 'export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
    systemctl --user start pipewire.socket pipewire-pulse.socket wireplumber.service 2>/dev/null || true
    nohup env WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
        sway >sway.log 2>&1 &' </dev/null >/dev/null 2>&1
sleep 15

fails=0
check() {  # check <description> <command run in the VM>; output kept on failure
    if vm "$2" >"$RUN/check.out" 2>&1; then printf '  \033[32mok\033[0m    %s\n' "$1"
    else
        printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fails=$((fails + 1))
        sed 's/^/        /' "$RUN/check.out" | tail -15
    fi
}
SWAYENV='export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus; export SWAYSOCK=$(ls $XDG_RUNTIME_DIR/sway-ipc.*.sock | head -1) WAYLAND_DISPLAY=wayland-1;'
check "sway is running"               "pgrep -x sway"
check "sway answers IPC (1 output)"   "$SWAYENV swaymsg -t get_outputs -r | grep -q HEADLESS"
check "config passes sway -C"         "WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 sway -C -c ~/.config/sway/config"
check "Xwayland available"            "command -v Xwayland"
check "PipeWire Pulse server up"      "$SWAYENV pactl info | grep -q 'Server Name: PulseAudio (on PipeWire'"
check "waybar started"                "pgrep -x waybar"
check "mako started"                  "pgrep -x mako"
check "nwg-drawer resident"           "pgrep -f '^nwg-drawer -r'"
check "autotiling running"            "pgrep -f autotiling"
check "jerkwall (wallpaper) running"  "pgrep -x jerkwall"
check "sway-binds renders the list"   "test \$(~/.local/bin/sway-binds | grep -c '▌') -ge 5"
check "chezmoi: no drift"             "test -z \"\$(chezmoi diff)\""
check "bar-battery prints JSON"       "\$HOME/.local/bin/bar-battery | python3 -c 'import json,sys; json.load(sys.stdin)'"
vm "$SWAYENV grim /tmp/shot.png" && scp -q -i "$RUN/key" -P "$SSH_PORT" -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null arch@127.0.0.1:/tmp/shot.png "$OUT/screenshot.png" 2>/dev/null \
    && say "screenshot: $OUT/screenshot.png"
vm 'cat sway.log' >"$OUT/sway.log" 2>/dev/null || true

echo
if [ "$KEEP" = 1 ]; then say "VM kept: ssh -i $RUN/key -p $SSH_PORT arch@127.0.0.1  (kill $QEMU_PID to stop)"; fi
say "logs: $OUT"
if [ "$fails" -eq 0 ]; then printf '\033[1;32mVM install test passed\033[0m\n'; exit 0; fi
printf '\033[1;31m%d VM check(s) failed\033[0m\n' "$fails"; exit 1
