#!/bin/sh
# Build jerkprompt (one-line input with a counter) and install to ~/.local/bin.
set -e
cd "$(dirname "$0")"
${ZIG:-zig} build-exe main.zig -target x86_64-linux-gnu -O ReleaseSafe -lc -femit-bin=jerkprompt
install -m755 jerkprompt "$HOME/.local/bin/"
echo "installed ~/.local/bin/jerkprompt"
