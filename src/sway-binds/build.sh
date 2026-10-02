#!/bin/sh
# Build sway-binds and install to ~/.local/bin. Needs zig 0.16 (no libc).
set -e
cd "$(dirname "$0")"
${ZIG:-zig} build-exe main.zig -O ReleaseSafe -femit-bin=sway-binds
install -m755 sway-binds "$HOME/.local/bin/"
echo "installed ~/.local/bin/sway-binds"
