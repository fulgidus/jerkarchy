#!/bin/sh
# Build jerksaver (terminal screensavers) and install to ~/.local/bin.
# Needs zig 0.16 and libc; the title font is shared with jerkwall (src/common).
set -e
cd "$(dirname "$0")"
${ZIG:-zig} build-exe -target x86_64-linux-gnu -O ReleaseFast \
    --dep font -Mroot=main.zig -O ReleaseFast -Mfont=../common/font5x7.zig -lc -femit-bin=jerksaver
install -m755 jerksaver "$HOME/.local/bin/"
echo "installed ~/.local/bin/jerksaver"
