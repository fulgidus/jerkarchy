#!/usr/bin/env bash
# ci/screenshots.sh [--gifs] OUTDIR [THEME…] — one 1280×720 PNG per theme
# (all themes by default): the bar, the live wallpaper, a terminal showing the
# 16 ANSI colours and the settings menu, each rendered in a throwaway home
# inside a headless sway (private D-Bus; never the live session).
# --gifs: also OUTDIR/saver-MODE.gif, a short loop of every screensaver mode
# (default theme). CI attaches all of it to releases and the site shows it.
#
# Needs: chezmoi sway waybar wezterm fuzzel grim jq, jerkwall and jerksaver
# ($JERKWALL / $JERKSAVER, default ~/.local/bin/…); ffmpeg for --gifs.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GIFS=0
[ "${1:-}" = --gifs ] && { GIFS=1; shift; }
out=${1:?usage: ci/screenshots.sh [--gifs] OUTDIR [THEME…]}; shift
mkdir -p "$out"
JW=${JERKWALL:-$HOME/.local/bin/jerkwall}
[ -x "$JW" ] || { echo "screenshots: no jerkwall at $JW (build it, or set JERKWALL)" >&2; exit 1; }
themes=("$@")
[ ${#themes[@]} -gt 0 ] || mapfile -t themes < <(chezmoi data --source "$ROOT" --format json | jq -r '.themes | keys[]')

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
for th in "${themes[@]}"; do
    h=$work/$th
    mkdir -p "$h/.config/chezmoi"
    printf 'sourceDir = "%s"\n[data]\ntheme = "%s"\n' "$ROOT" "$th" >"$h/.config/chezmoi/chezmoi.toml"
    if ! HOME=$h chezmoi apply --config "$h/.config/chezmoi/chezmoi.toml" --destination "$h" \
            --no-tty --force </dev/null >"$work/err" 2>&1; then
        echo "$th: render failed"; sed 's/^/    /' "$work/err"; fails=$((fails + 1)); continue
    fi
    # The real config minus daemons and session glue, a fixed output, and the
    # terminal floating so the wallpaper shows. No SSID or now-playing.
    cfg=$work/$th.conf
    grep -vE '^\s*(exec|exec_always|include)\b|dbus-update' "$h/.config/sway/config" >"$cfg"
    printf '%s\n' 'output * resolution 1280x720 scale 1' \
        'for_window [app_id="org.wezfurlong.wezterm"] floating enable, resize set 600 380, move position 30 60' >>"$cfg"
    sed -i 's/"network", //; s/"modules-center": \["mpris"\]/"modules-center": []/' "$h/.config/waybar/sway.jsonc"

    if ! read -r wd sock pid < <("$ROOT/ci/headless-sway.sh" "$cfg" 60); then
        echo "$th: headless sway didn't start"; fails=$((fails + 1)); continue
    fi
    m() { SWAYSOCK=$sock swaymsg -q "exec env HOME=$h XDG_CONFIG_HOME=$h/.config $*"; }
    m "$JW"
    m "waybar -c $h/.config/waybar/sway.jsonc"
    m "wezterm --config-file $h/.config/wezterm/wezterm.lua start --always-new-process -- sh -c 'printf \"\\\\033[1m$th\\\\033[0m\\\\n\\\\n\"; for i in 0 1 2 3 4 5 6 7; do printf \"\\\\033[4\${i}m   \\\\033[0m\"; done; echo; for i in 0 1 2 3 4 5 6 7; do printf \"\\\\033[10\${i}m   \\\\033[0m\"; done; printf \"\\\\n\\\\n\"; ls --color=always -la /etc | head -9; sleep 60'"
    sleep 3
    m "$h/.local/bin/jerkarchy-settings"
    sleep 2.5
    if WAYLAND_DISPLAY=$wd grim "$out/$th.png"; then echo "$th: ok"; else echo "$th: grim failed"; fails=$((fails + 1)); fi
    # terminal first (it complains when its compositor vanishes), then sway
    pkill -f "^[^ ]*wezterm[^ ]* --config-file $h/"
    sleep 1
    kill "$pid" 2>/dev/null
    sleep 0.5
done
echo "$(( ${#themes[@]} - fails ))/${#themes[@]} themes captured in $out"

# Screensaver loops: run the real `screensaver` script in a jerkarchy-theme
# home, grab frames, encode a GIF (palette per GIF, 640 px wide).
if [ "$GIFS" = 1 ]; then
    JS=${JERKSAVER:-$HOME/.local/bin/jerksaver}
    h=$work/saver
    mkdir -p "$h/.config/chezmoi"
    printf 'sourceDir = "%s"\n[data]\ntheme = "jerkarchy"\n' "$ROOT" >"$h/.config/chezmoi/chezmoi.toml"
    HOME=$h chezmoi apply --config "$h/.config/chezmoi/chezmoi.toml" --destination "$h" --no-tty --force </dev/null >/dev/null
    cp "$JW" "$JS" "$h/.local/bin/"
    cfg=$work/saver.conf
    grep -vE '^\s*(exec|exec_always|include)\b|dbus-update' "$h/.config/sway/config" >"$cfg"
    echo 'output * resolution 1280x720 scale 1' >>"$cfg"
    for mode in wallpaper matrix bonsai city galaxy planets threebody; do
        read -r wd sock pid < <("$ROOT/ci/headless-sway.sh" "$cfg" 90) || { echo "saver $mode: no sway"; fails=$((fails + 1)); continue; }
        SWAYSOCK=$sock swaymsg -q "exec env HOME=$h XDG_CONFIG_HOME=$h/.config $h/.local/bin/screensaver $mode"
        # bonsai grows in its first ~3 s: start right away so the loop shows it
        wait0=2.5 step=0.12 n=48
        [ "$mode" = bonsai ] && wait0=0.4 step=0.06 n=60
        sleep "$wait0"
        fr=$work/frames-$mode; mkdir -p "$fr"
        for i in $(seq -w 1 "$n"); do WAYLAND_DISPLAY=$wd grim "$fr/f$i.png"; sleep "$step"; done
        pkill -x jerksaver; pkill -f "^$h/.local/bin/jerkwall --mode saver"; sleep 1
        kill "$pid" 2>/dev/null; sleep 0.5
        if ffmpeg -loglevel error -y -framerate 8 -i "$fr/f%02d.png" \
                -vf "scale=640:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=96[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" \
                -loop 0 "$out/saver-$mode.gif"; then
            echo "saver $mode: ok ($(du -k "$out/saver-$mode.gif" | cut -f1) KB)"
        else echo "saver $mode: gif failed"; fails=$((fails + 1)); fi
    done
fi
[ "$fails" -eq 0 ]
