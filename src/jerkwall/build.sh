#!/bin/sh
# Build jerkwall and install to ~/.local/bin.
# Needs: zig (0.16), wayland-scanner, libwayland-client. Protocol XMLs are vendored.
set -e
cd "$(dirname "$0")"
mkdir -p gen
for p in wlr-layer-shell-unstable-v1 xdg-shell; do
    wayland-scanner client-header "protocol/$p.xml" "gen/$p-client-protocol.h"
    wayland-scanner private-code  "protocol/$p.xml" "gen/$p-protocol.c"
done
# -target x86_64-linux-gnu: zig's linker can't handle the .sframe relocations
# in this system's crt1.o; use zig's bundled glibc crt instead.
# Module flags (-O, -I, C sources) apply to the next -M; the shared title font
# lives in src/common.
${ZIG:-zig} build-exe -target x86_64-linux-gnu -O ReleaseFast -Igen -I/usr/include gen/*.c \
    --dep font -Mroot=main.zig -O ReleaseFast -Mfont=../common/font5x7.zig \
    -L/usr/lib -lc -lwayland-client -lwayland-egl -lEGL -lGLESv2 -femit-bin=jerkwall
install -m755 jerkwall "$HOME/.local/bin/"
echo "installed ~/.local/bin/jerkwall"
