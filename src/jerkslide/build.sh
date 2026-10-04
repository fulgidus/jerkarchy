#!/bin/sh
# Build jerkslide and install to ~/.local/bin.
# Needs: zig (0.16), wayland-scanner, libwayland-client. Protocol XMLs are vendored.
set -e
cd "$(dirname "$0")"
mkdir -p gen
for p in wlr-layer-shell-unstable-v1 xdg-shell viewporter; do
    wayland-scanner client-header "protocol/$p.xml" "gen/$p-client-protocol.h"
    wayland-scanner private-code  "protocol/$p.xml" "gen/$p-protocol.c"
done
# -target x86_64-linux-gnu: see src/jerkwall/build.sh.
${ZIG:-zig} build-exe main.zig gen/*.c -Igen -I/usr/include -L/usr/lib \
    -target x86_64-linux-gnu -lc -lwayland-client -O ReleaseFast -femit-bin=jerkslide
install -m755 jerkslide "$HOME/.local/bin/"
echo "installed ~/.local/bin/jerkslide"
