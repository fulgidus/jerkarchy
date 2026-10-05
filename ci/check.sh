#!/usr/bin/env bash
# ci/check.sh — every check a change must pass. Run it locally before merging
# into develop; the GitHub workflow runs the same script on main.
#
#   ci/check.sh            all checks
#   ci/check.sh --quick    skip the Zig build
#   CI_OUT=dir ci/check.sh  also keep the built binaries in dir (release job)
#
# Needs: bash, python3, chezmoi, sway, fuzzel, zig (unless --quick).
# Never touches the real home: everything renders into temp dirs.
# Lints with shellcheck when it's installed (CI always installs it).
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
QUICK=0; [ "${1:-}" = --quick ] && QUICK=1
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# Nothing here may reach a live session: no notifications on the user's bus,
# no IPC to their sway, logs in a private runtime dir.
export DBUS_SESSION_BUS_ADDRESS="unix:path=$TMP/no-bus"
unset WAYLAND_DISPLAY SWAYSOCK DISPLAY
export XDG_RUNTIME_DIR="$TMP/run"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
# Containers and fresh VMs default to the C locale, where fuzzel rejects the
# configs' non-ASCII prompt; real sessions are UTF-8.
export LC_ALL=C.UTF-8
fails=0

ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf '  \033[33mskip\033[0m  %s\n' "$*"; }
step() { printf '\n\033[1;96m▌ %s\033[0m\n' "$*"; }
need() { command -v "$1" >/dev/null || { bad "$1 not installed"; return 1; }; }

cd "$ROOT" || exit 1

# Scripts: chezmoi-managed executables + repo scripts.
mapfile -t SCRIPTS < <(
    { find home -type f -name 'executable_*'; echo install.sh; find ci src -name '*.sh'; } | sort -u)

step "render dotfiles (chezmoi → temp home)"
FAKEHOME="$TMP/home"; mkdir -p "$FAKEHOME"
if need chezmoi && HOME="$FAKEHOME" chezmoi apply --source "$ROOT" --destination "$FAKEHOME" \
        --no-tty --force >"$TMP/chezmoi.log" 2>&1; then
    ok "chezmoi apply ($(find "$FAKEHOME" -type f | wc -l) files)"
else
    bad "chezmoi apply"; sed 's/^/        /' "$TMP/chezmoi.log"
fi

step "shell syntax"
for f in "${SCRIPTS[@]}"; do
    case "$(head -1 "$f")" in
        *bash*) sh_="bash" ;;
        *sh*)   sh_="sh" ;;
        *)      continue ;;
    esac
    if $sh_ -n "$f" 2>"$TMP/err"; then ok "$sh_ -n $f"; else bad "$sh_ -n $f"; sed 's/^/        /' "$TMP/err"; fi
done

step "shellcheck"
if command -v shellcheck >/dev/null; then
    for f in "${SCRIPTS[@]}"; do
        head -1 "$f" | grep -q 'sh' || continue
        # Templates: lint what chezmoi renders, not the template syntax.
        lint=$f
        case "$f" in *.tmpl)
            lint=$(HOME="$FAKEHOME" chezmoi target-path --source "$ROOT" --destination "$FAKEHOME" "$ROOT/$f") ;;
        esac
        if shellcheck -S warning "$lint" >"$TMP/sc" 2>&1; then ok "$f"; else bad "$f"; sed 's/^/        /' "$TMP/sc"; fi
    done
else
    skip "shellcheck not installed (CI runs it)"
fi

step "sway config"
SWAYCFG="$FAKEHOME/.config/sway/config"
if need sway; then
    # Headless backend: sway -C still creates a backend, and CI/VMs have no seat.
    if HOME="$FAKEHOME" WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
            sway -C -c "$SWAYCFG" >"$TMP/sway" 2>&1 && ! grep -qiE 'error|warn' "$TMP/sway"; then
        ok "sway -C"
    else
        bad "sway -C"; sed 's/^/        /' "$TMP/sway"
    fi
fi

step "waybar config (JSON with // comments)"
for f in home/dot_config/waybar/*.jsonc; do
    if python3 - "$f" <<'EOF' 2>"$TMP/err"
import json, re, sys
json.loads(re.sub(r"^\s*//.*$", "", open(sys.argv[1]).read(), flags=re.M))
EOF
    then ok "$f"; else bad "$f"; sed 's/^/        /' "$TMP/err"; fi
done

step "fuzzel configs"
if need fuzzel; then
    for f in "$FAKEHOME"/.config/fuzzel/*.ini; do
        if fuzzel --config "$f" --check-config >"$TMP/err" 2>&1; then ok "${f#"$FAKEHOME"/}"; else bad "${f#"$FAKEHOME"/}"; sed 's/^/        /' "$TMP/err"; fi
    done
fi

step "themes (schema, and every theme renders and validates)"
if chezmoi data --source "$ROOT" --format json >"$TMP/data.json" 2>"$TMP/err" && python3 - "$TMP/data.json" <<'EOF' 2>"$TMP/err"
import json, re, sys
d = json.load(open(sys.argv[1]))
roles = "bg bg_alt border fg fg_bright fg_dim fg_mute accent accent2 ok warn err".split()
hexc = re.compile(r"^#[0-9a-fA-F]{6}$")
bad = []
for name, t in d["themes"].items():
    for r in roles:
        if not hexc.match(str(t.get(r, ""))): bad.append(f"{name}.{r} = {t.get(r)!r}")
    if len(t.get("ansi", [])) != 16 or not all(hexc.match(c) for c in t["ansi"]): bad.append(f"{name}.ansi")
    if not isinstance(t.get("light"), bool) or not t.get("title"): bad.append(f"{name}: title/light")
    if "wall" in t and not (2 <= len(t["wall"]) <= 12 and all(hexc.match(c) for c in t["wall"])): bad.append(f"{name}.wall (2-12 hex colours)")
    if t.get("group") == "flags" and not (t.get("wall") and t.get("ui") and all(hexc.match(c) for c in t["ui"])): bad.append(f"{name}: flags need wall + ui")
    if t.get("group", "flags") not in ("flags", "mono"): bad.append(f"{name}.group (flags|mono, or none)")
if d.get("theme") not in d["themes"]: bad.append(f"default theme {d.get('theme')!r} missing")
if bad: sys.exit("\n".join(bad))
print(" ".join(sorted(d["themes"])), file=open(sys.argv[1] + ".names", "w"))
EOF
then
    ok "schema ($(wc -w <"$TMP/data.json.names") themes)"
    mapfile -t TEMPLATES < <(find home -name '*.tmpl')
    for th in $(cat "$TMP/data.json.names"); do
        h="$TMP/theme-$th"; mkdir -p "$h/.config/chezmoi"
        printf 'sourceDir = "%s"\n[data]\ntheme = "%s"\n' "$ROOT" "$th" >"$h/.config/chezmoi/chezmoi.toml"
        r=""
        HOME="$h" chezmoi apply --config "$h/.config/chezmoi/chezmoi.toml" --destination "$h" \
            --no-tty --force </dev/null >"$TMP/err" 2>&1 || r="$r apply"
        if [ -z "$r" ]; then
            HOME="$h" WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
                sway -C -c "$h/.config/sway/config" >"$TMP/err" 2>&1 && ! grep -qiE 'error|warn' "$TMP/err" || r="$r sway"
            for f in "$h"/.config/fuzzel/*.ini; do fuzzel --config "$f" --check-config >/dev/null 2>&1 || r="$r ${f##*/}"; done
            # Outputs of *.tmpl sources must not contain template syntax or <no value>.
            for src in "${TEMPLATES[@]}"; do
                tgt=$(HOME="$h" chezmoi target-path --source "$ROOT" --destination "$h" "$ROOT/$src" 2>/dev/null) || continue
                grep -qE '\{\{|<no value>' "$tgt" 2>/dev/null && r="$r unrendered:${tgt#"$h"/}"
            done
        fi
        if [ -z "$r" ]; then ok "$th"; else bad "$th:$r"; sed 's/^/        /' "$TMP/err" | tail -5; fi
    done
else
    bad "theme data"; sed 's/^/        /' "$TMP/err"
fi

step "jerkarchy-set (writes chezmoi.toml [data] in a temp home)"
JH="$TMP/set-home"; mkdir -p "$JH/.config/chezmoi"
printf 'sourceDir = "%s"\n\n[data]\ntheme = "jerkarchy"\n\n[diff]\npager = ""\n' "$ROOT" >"$JH/.config/chezmoi/chezmoi.toml"
JS="$FAKEHOME/.local/bin/jerkarchy-set"
jset() { HOME="$JH" XDG_CONFIG_HOME="$JH/.config" SWAYSOCK="" "$JS" "$@" </dev/null; }
if HOME="$JH" chezmoi apply --no-tty --force </dev/null >"$TMP/err" 2>&1 &&
        jset theme nord >/dev/null 2>"$TMP/err" && jset wall_fps 24 >/dev/null 2>>"$TMP/err" &&
        [ "$(jset get theme)" = nord ] && [ "$(jset get wall_fps)" = 24 ] &&
        grep -q '^--fps 24$' "$JH/.config/jerkwall/config" &&
        awk '/^\[diff\]/{d=1} d&&/wall_fps/{exit 1}' "$JH/.config/chezmoi/chezmoi.toml"; then
    ok "set + apply (theme, wall_fps; key lands in [data])"
else
    bad "set + apply"; sed 's/^/        /' "$TMP/err"
fi
if jset kb_layout it,us >/dev/null 2>&1 && jset kb_variant ,intl >/dev/null 2>&1 && jset kb_options none >/dev/null 2>&1 &&
        grep -q '^    xkb_layout it,us$' "$JH/.config/sway/config" && grep -q '^    xkb_variant ,intl$' "$JH/.config/sway/config" &&
        ! grep -q xkb_options "$JH/.config/sway/config"; then
    ok "keyboard settings render into the sway config (none clears)"
else bad "keyboard settings"; fi
if jset fx_animation_ms 400 >/dev/null 2>&1 && [ "$(jset get fx_animation_ms)" = 400 ]; then ok "fx_animation_ms set"; else bad "fx_animation_ms set"; fi
for args in "slide_ms 1001" "saver_min 999" "fx_animation_ms 2001" "fx_animation_ms fast" "theme nope" "wall_fps 0" "wall_fps 2.5" "wall_contrast 9" "bogus 1" "kb_layout IT" "kb_layout it;us" "kb_options a\$b"; do
    # shellcheck disable=SC2086
    if jset $args >/dev/null 2>&1; then bad "accepts '$args'"; else ok "rejects '$args'"; fi
done
echo 'hand edit' >>"$JH/.config/mako/config"
if jset theme tokyo-night >/dev/null 2>&1 || ! grep -q '^theme = "nord"' "$JH/.config/chezmoi/chezmoi.toml"; then
    bad "hand-edited file: must refuse and leave settings unchanged"
else ok "refuses to clobber a hand-edited file"; fi

step "notify-menu (stub makoctl / wl-copy / fuzzel)"
NS="$TMP/notify-stub"; mkdir -p "$NS"
cat >"$NS/makoctl" <<'EOF'
#!/bin/sh
case "$1 $2" in
    "list -j")    echo '[{"id":7,"app_name":"a","summary":"Shown","body":"multi\nline","actions":{"x":"Do X"}}]' ;;
    "history -j") echo '[{"id":3,"app_name":"b","summary":"Old","body":"","actions":{}}]' ;;
    *) echo "$*" >>"$NS_LOG" ;;
esac
EOF
printf '#!/bin/sh\ncat >"%s/clip"\n' "$NS" >"$NS/wl-copy"
# fuzzel stub: record the rows, pick row $PICK's hidden column.
printf '#!/bin/sh\ncat >"%s/rows"; awk -F"\\t" -v p="${PICK:-1}" "NR==p{print \\$2}" "%s/rows"\n' "$NS" "$NS" >"$NS/fuzzel"
chmod +x "$NS"/*
NM="$FAKEHOME/.local/bin/notify-menu"
nm() { HOME="$FAKEHOME" NS_LOG="$NS/log" PATH="$NS:$PATH" "$NM" "$@"; }
nm copy 7 && [ "$(cat "$NS/clip")" = "$(printf 'Shown\nmulti\nline')" ] && ok "copy: summary + body" || bad "copy: summary + body"
nm copy 3 && [ "$(cat "$NS/clip")" = "Old" ] && ok "copy from history" || bad "copy from history"
if nm copy 99 2>/dev/null; then bad "copy of a missing id must fail"; else ok "copy of a missing id fails"; fi
PICK=1 nm 7 && grep -qx 'invoke -n 7 x' "$NS/log" && ok "menu: invokes the notification's action" || bad "menu: invoke action"
PICK=3 nm 7 && grep -qx 'dismiss -n 7' "$NS/log" && ok "menu: dismiss" || bad "menu: dismiss"
PICK=1 nm 3 && ! grep -q dismiss "$NS/rows" && ok "history entry: copy only, no dismiss" || bad "history entry rows"

step "install.sh profiles (dry run: nothing installed)"
IH="$TMP/inst-home"; mkdir -p "$IH"
dry() { HOME="$IH" XDG_CONFIG_HOME="$IH/.config" JERKARCHY_DRY_RUN=1 bash install.sh "$@" 2>&1; }
# A plain install (no profiles, nothing saved) must get through: v0.1.3 died
# here silently (grep matching nothing under pipefail).
if out=$(dry) && printf '%s\n' "$out" | grep -qx 'package: waybar'; then
    ok "plain install (no profiles) resolves"
else bad "plain install (no profiles)"; printf '%s\n' "$out" | sed 's/^/        /' | tail -5; fi
out=$(dry --with dev,office)
if printf '%s\n' "$out" | grep -qx 'package: helix' && printf '%s\n' "$out" | grep -qx 'package: neovim' &&
        printf '%s\n' "$out" | grep -q '^flagged: libreoffice-fresh:.*gnumeric' && ! printf '%s\n' "$out" | grep -qx 'package: steam'; then
    ok "--with dev,office: clean picks + flagged apps, flagged ones explained"
else bad "--with dev,office"; printf '%s\n' "$out" | sed 's/^/        /' | tail -8; fi
out=$(dry --with dev,office --clean-only)
if ! printf '%s\n' "$out" | grep -qE '^(package: (neovim|code|emacs|libreoffice-fresh|thunderbird)$|flagged:)' &&
        printf '%s\n' "$out" | grep -qx 'package: aerc'; then
    ok "--clean-only drops every flagged app"
else bad "--clean-only"; fi
out=$(dry --with dev,gaming,office,browsers,creator,electronics)
if printf '%s\n' "$out" | grep -qx 'package: steam' && printf '%s\n' "$out" | grep -qx 'package: kicad' &&
        printf '%s\n' "$out" | grep -qx 'package: tenacity' && printf '%s\n' "$out" | grep -qx 'package: librewolf'; then
    ok "profiles stack (all seven at once)"
else bad "stacking profiles"; fi
if dry --with nosuch >/dev/null; then bad "accepts an unknown profile"; else ok "rejects an unknown profile"; fi
mkdir -p "$IH/.config/jerkarchy"
printf 'PROFILES_SAVED="docker"\nSWAYFX_SAVED=0\nCLEAN_ONLY_SAVED=0\n' >"$IH/.config/jerkarchy/install.conf"
out=$(dry)
if printf '%s\n' "$out" | grep -qx 'package: docker' && printf '%s\n' "$out" | grep -q 'compositor: sway$'; then
    ok "saved choices (profiles, --no-swayfx) are kept on re-runs"
else bad "saved choices"; printf '%s\n' "$out" | sed 's/^/        /' | tail -5; fi

step "jerkarchy-update (throwaway remote; stub install.sh)"
UR="$TMP/upd"; mkdir -p "$UR"
(   set -e
    git init -q --bare "$UR/remote.git"
    git clone -q "$UR/remote.git" "$UR/work" 2>/dev/null
    cd "$UR/work"; mkdir home
    printf '0.1.2\n' >VERSION; printf '# Changelog\n\n## v0.1.2\n\n- old\n' >CHANGELOG.md
    printf 'echo STUB-INSTALL-RAN "$JERKARCHY_SRC"\n' >install.sh
    git add -A; git -c user.name=t -c user.email=t@t commit -qm v1; git push -q origin HEAD 2>/dev/null
    git clone -q "$UR/remote.git" "$UR/user" 2>/dev/null
    printf '0.1.3\n' >VERSION; printf '# Changelog\n\n## v0.1.3\n\n- new thing\n\n## v0.1.2\n\n- old\n' >CHANGELOG.md
    git -c user.name=t -c user.email=t@t commit -qam v2; git push -q origin HEAD 2>/dev/null
) >"$TMP/err" 2>&1
UH="$TMP/upd-home"; mkdir -p "$UH/.config/chezmoi"
printf 'sourceDir = "%s/user"\n' "$UR" >"$UH/.config/chezmoi/chezmoi.toml"
upd() { HOME="$UH" XDG_CONFIG_HOME="$UH/.config" sh "$ROOT/home/dot_local/bin/executable_jerkarchy-update" 2>&1; }
out=$(upd)
if printf '%s\n' "$out" | grep -q 'v0.1.2 → v0.1.3' && printf '%s\n' "$out" | grep -qx -- '- new thing' &&
        ! printf '%s\n' "$out" | grep -qx -- '- old' && printf '%s\n' "$out" | grep -q "STUB-INSTALL-RAN $UR/user"; then
    ok "pulls, shows only the new changelog, runs the new install.sh"
else bad "update"; printf '%s\n' "$out" | sed 's/^/        /' | tail -8; fi
if upd | grep -q 'up to date (v0.1.3)'; then ok "says when it's up to date"; else bad "up-to-date case"; fi
echo x >>"$UR/user/VERSION"
if upd >/dev/null; then bad "must refuse with local changes"; else ok "refuses with local changes"; fi

step "bar-battery against fake batteries (output must be valid JSON)"
BB="$FAKEHOME/.local/bin/bar-battery"
fake() {  # fake <status> <capacity> [charge_now] [current_now]
    d="$TMP/bat-$1-$2"; mkdir -p "$d"
    printf '%s\n' "$1" > "$d/status"; printf '%s\n' "$2" > "$d/capacity"
    echo "${3:-2000000}" > "$d/charge_now"; echo 2519000 > "$d/charge_full"
    echo 4071000 > "$d/charge_full_design"; echo "${4:-400000}" > "$d/current_now"
    echo 15800000 > "$d/voltage_now"; echo 50 > "$d/charge_control_start_threshold"
    echo 90 > "$d/charge_control_end_threshold"; echo "$d"
}
for case in "Discharging 78" "Discharging 3" "Charging 54" "Full 100" "Not_charging 95" "Discharging ''"; do
    read -r st cap <<<"$case"; st=${st//_/ }; [ "$cap" = "''" ] && cap=""
    dir=$(fake "$st" "$cap")
    if XDG_RUNTIME_DIR="$TMP" HOME="$FAKEHOME" "$BB" "$dir" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["text"] and "class" in d' 2>"$TMP/err"; then
        ok "$st ${cap:-<empty>}%"
    else
        bad "$st ${cap:-<empty>}%"; sed 's/^/        /' "$TMP/err"
    fi
done

if XDG_RUNTIME_DIR="$TMP" HOME="$FAKEHOME" "$BB" "$TMP/no-such-battery" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "nobattery" in d["class"]' 2>"$TMP/err"; then
    ok "no battery (desktop/VM): profile only"
else
    bad "no battery"; sed 's/^/        /' "$TMP/err"
fi

step "repo hygiene"
# Raw Nerd Font (private-use) glyphs get stripped by editors: use escapes.
# Only tracked text files (build outputs and binaries are ignored by git).
if git ls-files -z | xargs -0 grep -lIP '[\x{E000}-\x{F8FF}\x{F0000}-\x{FFFFD}]' 2>/dev/null >"$TMP/pua"; [ -s "$TMP/pua" ]; then
    bad "raw private-use glyphs in:"; sed 's/^/        /' "$TMP/pua"
else ok "no raw private-use glyphs"; fi
if grep -rnEi 'BEGIN [A-Z ]*PRIVATE KEY|(api[_-]?key|secret|token|passw(or)?d)[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9/+_-]{12,}' \
        home install.sh ci src >"$TMP/sec" 2>/dev/null; then
    bad "possible secrets:"; sed 's/^/        /' "$TMP/sec"
else ok "no obvious secrets"; fi
if git log --format=%B 2>/dev/null | grep -qi '^co-authored-by:'; then
    bad "commit messages contain Co-Authored-By trailers"
else ok "no attribution trailers in history"; fi
if find . -path ./.git -prune -o \( -name '*.bak*' -o -name '*~' \) -print | grep -q .; then
    bad "backup files present"
else ok "no backup files"; fi
if grep -qxE '[0-9]+\.[0-9]+\.[0-9]+' VERSION 2>/dev/null; then ok "VERSION = $(cat VERSION)"; else bad "VERSION missing or not X.Y.Z"; fi
if [ -f SNAPSHOT ] && grep -qxE '[0-9]{4}-[0-9]{2}-[0-9]{2}' SNAPSHOT; then
    ok "SNAPSHOT = $(cat SNAPSHOT)"
else bad "SNAPSHOT missing or not YYYY-MM-DD"; fi

step "zig: jerkwall"
if [ "$QUICK" = 1 ]; then
    skip "--quick"
elif need zig && need wayland-scanner; then
    if (cd src/jerkwall && mkdir -p "$TMP/jw-gen" && for p in wlr-layer-shell-unstable-v1 xdg-shell; do
            wayland-scanner client-header "protocol/$p.xml" "$TMP/jw-gen/$p-client-protocol.h" &&
            wayland-scanner private-code "protocol/$p.xml" "$TMP/jw-gen/$p-protocol.c" || exit 1; done &&
        zig build-exe -target x86_64-linux-gnu -O ReleaseFast -I"$TMP/jw-gen" -I/usr/include "$TMP"/jw-gen/*.c \
            --dep font -Mroot=main.zig -O ReleaseFast -Mfont=../common/font5x7.zig \
            -L/usr/lib -lc -lwayland-client -lwayland-egl -lEGL -lGLESv2 -femit-bin="$TMP/jerkwall") >"$TMP/zig" 2>&1; then
        ok "build"
        [ -n "${CI_OUT:-}" ] && mkdir -p "$CI_OUT" && cp "$TMP/jerkwall" "$CI_OUT/"
        if "$TMP/jerkwall" --fps x >/dev/null 2>&1; then bad "rejects bad --fps"; else ok "rejects bad --fps"; fi
        if "$TMP/jerkwall" --stops ff0000 >/dev/null 2>&1; then bad "rejects a one-colour --stops"; else ok "rejects a one-colour --stops"; fi
        if HOME="$TMP" "$TMP/jerkwall" --stops e40303,ff8c00,ffed00,008026,004dff,750787 --frame 64 36 "$TMP/stops.png" >/dev/null 2>&1 &&
                [ -s "$TMP/stops.png" ]; then ok "--stops renders a frame"; else bad "--stops renders a frame"; fi
    else
        bad "build"; sed 's/^/        /' "$TMP/zig"
    fi
fi

step "screensaver (headless sway + virtual keyboard)"
if [ "$QUICK" = 1 ]; then
    skip "--quick"
elif [ ! -x "$TMP/jerkwall" ]; then
    skip "jerkwall wasn't built"
else
    vk="$TMP/vkbd-gen"; mkdir -p "$vk"
    glibc=$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$')
    case "$glibc" in 2.4[4-9]|2.[5-9]*) glibc=2.43 ;; esac  # newest zig can target
    if wayland-scanner client-header ci/vkbd/protocol/virtual-keyboard-unstable-v1.xml "$vk/virtual-keyboard-unstable-v1-client-protocol.h" &&
            wayland-scanner private-code ci/vkbd/protocol/virtual-keyboard-unstable-v1.xml "$vk/virtual-keyboard-unstable-v1-protocol.c" &&
            (cd ci/vkbd && zig build-exe main.zig "$vk"/*.c -I"$vk" -I/usr/include -L/usr/lib -target "x86_64-linux-gnu${glibc:+.$glibc}" \
                -lc -lwayland-client -lxkbcommon -O ReleaseSafe -femit-bin="$TMP/vkbd") >"$TMP/err" 2>&1; then
        printf 'output * resolution 640x360 scale 1\n' >"$TMP/saver.conf"
        if read -r wd _ spid < <(ci/headless-sway.sh "$TMP/saver.conf" 30 2>/dev/null); then
            WAYLAND_DISPLAY=$wd HOME="$TMP" "$TMP/jerkwall" --mode saver --fps 10 >/dev/null 2>&1 & jp=$!
            sleep 1.5
            if kill -0 "$jp" 2>/dev/null; then ok "saver starts"; else bad "saver starts"; fi
            WAYLAND_DISPLAY=$wd "$TMP/vkbd" >/dev/null 2>&1; sleep 0.5
            if kill -0 "$jp" 2>/dev/null; then bad "a key press dismisses the saver"; kill "$jp"; else ok "a key press dismisses the saver"; fi
            kill "$spid" 2>/dev/null
        else
            skip "headless sway didn't start here"
        fi
    else
        bad "build vkbd"; sed 's/^/        /' "$TMP/err" | tail -5
    fi
fi

step "zig: jerkslide (workspace slide)"
if [ "$QUICK" = 1 ]; then
    skip "--quick"
elif need zig && need wayland-scanner; then
    js="$TMP/js-gen"; mkdir -p "$js"
    if (cd src/jerkslide && for p in wlr-layer-shell-unstable-v1 xdg-shell viewporter; do
            wayland-scanner client-header "protocol/$p.xml" "$js/$p-client-protocol.h" &&
            wayland-scanner private-code "protocol/$p.xml" "$js/$p-protocol.c" || exit 1; done &&
        zig build-exe main.zig "$js"/*.c -I"$js" -I/usr/include -L/usr/lib \
            -target x86_64-linux-gnu -lc -lwayland-client -O ReleaseFast -femit-bin="$TMP/jerkslide") >"$TMP/zig" 2>&1; then
        ok "build"
        [ -n "${CI_OUT:-}" ] && mkdir -p "$CI_OUT" && cp "$TMP/jerkslide" "$CI_OUT/"
        printf 'output * resolution 320x180 scale 1\n' >"$TMP/slide.conf"
        if read -r wd _ spid < <(ci/headless-sway.sh "$TMP/slide.conf" 30 2>/dev/null); then
            { printf 'P6\n320 180\n255\n'; head -c $((320 * 180 * 3)) /dev/zero; } >"$TMP/shot.ppm"
            out=$(WAYLAND_DISPLAY=$wd timeout 5 "$TMP/jerkslide" HEADLESS-1 left 100 <"$TMP/shot.ppm" 2>"$TMP/err")
            if [ "$out" = ready ]; then ok "overlay up, slides, exits"; else bad "jerkslide run"; sed 's/^/        /' "$TMP/err"; fi
            if WAYLAND_DISPLAY=$wd timeout 5 "$TMP/jerkslide" HEADLESS-1 left 100 </dev/null >/dev/null 2>&1; then
                bad "rejects garbage input"; else ok "rejects garbage input"; fi
            kill "$spid" 2>/dev/null
        else
            skip "headless sway didn't start here"
        fi
    else
        bad "build"; sed 's/^/        /' "$TMP/zig"
    fi
fi

step "zig: jerksaver (terminal screensavers)"
if [ "$QUICK" = 1 ]; then
    skip "--quick"
elif need zig; then
    if (cd src/jerksaver && zig build-exe -target x86_64-linux-gnu -O ReleaseFast \
            --dep font -Mroot=main.zig -O ReleaseFast -Mfont=../common/font5x7.zig -lc -femit-bin="$TMP/jerksaver") >"$TMP/zig" 2>&1; then
        ok "build"
        [ -n "${CI_OUT:-}" ] && mkdir -p "$CI_OUT" && cp "$TMP/jerksaver" "$CI_OUT/"
        if "$TMP/jerksaver" nosuchmode >/dev/null 2>&1; then bad "rejects an unknown mode"; else ok "rejects an unknown mode"; fi
        if "$TMP/jerksaver" matrix --title 'bad"title' >/dev/null 2>&1; then bad "rejects a title the font can't draw"; else ok "rejects a title the font can't draw"; fi
        # Every mode runs a few frames in a pseudo-terminal, then quits on a key.
        if command -v script >/dev/null; then
            for m in matrix bonsai city galaxy planets threebody; do
                if (sleep 1.6; printf q) | timeout 10 script -qec "stty cols 120 rows 40; $TMP/jerksaver $m" /dev/null >/dev/null 2>&1; then
                    ok "$m runs and quits on a key"
                else bad "$m runs and quits on a key"; fi
            done
        else skip "script (util-linux) missing: modes not run"; fi
    else
        bad "build"; sed 's/^/        /' "$TMP/zig"
    fi
fi

step "zig: jerkprompt (text input with a counter)"
if [ "$QUICK" = 1 ]; then
    skip "--quick"
elif need zig; then
    if (cd src/jerkprompt && zig build-exe main.zig -target x86_64-linux-gnu -O ReleaseSafe -lc -femit-bin="$TMP/jerkprompt") >"$TMP/zig" 2>&1; then
        ok "build"
        [ -n "${CI_OUT:-}" ] && mkdir -p "$CI_OUT" && cp "$TMP/jerkprompt" "$CI_OUT/"
        if command -v script >/dev/null; then
            rm -f "$TMP/jp.out"
            (sleep 0.8; printf 'my "box" 0123456789012345678'; sleep 0.3; printf '\177\r') |
                timeout 10 script -qec "$TMP/jerkprompt --out $TMP/jp.out --max 16 --allow 'abcdefghijklmnopqrstuvwxyz0123456789 '" /dev/null >/dev/null 2>&1
            if [ "$(cat "$TMP/jp.out" 2>/dev/null)" = "my box 01234567" ]; then
                ok "filters characters, stops at --max, backspace"
            else bad "jerkprompt input: got '$(cat "$TMP/jp.out" 2>/dev/null)'"; fi
            rm -f "$TMP/jp.out"
            (sleep 0.8; printf 'abc'; sleep 0.2; printf '\033') |
                timeout 10 script -qec "$TMP/jerkprompt --out $TMP/jp.out" /dev/null >/dev/null 2>&1
            if [ -e "$TMP/jp.out" ]; then bad "Esc must not save"; else ok "Esc cancels without saving"; fi
        else skip "script (util-linux) missing"; fi
    else
        bad "build"; sed 's/^/        /' "$TMP/zig"
    fi
fi

step "zig: sway-binds"
if [ "$QUICK" = 1 ]; then
    skip "--quick"
elif need zig; then
    if (cd src/sway-binds && zig build-exe main.zig -O ReleaseSafe -femit-bin="$TMP/sway-binds") >"$TMP/zig" 2>&1; then
        ok "build"
        [ -n "${CI_OUT:-}" ] && mkdir -p "$CI_OUT" && cp "$TMP/sway-binds" "$CI_OUT/"
        if "$TMP/sway-binds" "$SWAYCFG" >"$TMP/binds" 2>&1 && [ "$(grep -c '▌' "$TMP/binds")" -ge 5 ]; then
            ok "renders the binding list ($(grep -c '▌' "$TMP/binds") sections)"
        else
            bad "sway-binds output"; head -20 "$TMP/binds" | sed 's/^/        /'
        fi
    else
        bad "build"; sed 's/^/        /' "$TMP/zig"
    fi
fi

echo
if [ "$fails" -eq 0 ]; then printf '\033[1;32mall checks passed\033[0m\n'; exit 0; fi
printf '\033[1;31m%d check(s) failed\033[0m\n' "$fails"; exit 1
