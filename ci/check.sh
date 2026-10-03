#!/usr/bin/env bash
# ci/check.sh — every check a change must pass. Run it locally before merging
# into develop; the GitHub workflow runs the same script on main.
#
#   ci/check.sh            all checks
#   ci/check.sh --quick    skip the Zig build
#
# Needs: bash, python3, chezmoi, sway, fuzzel, zig (unless --quick).
# shellcheck is used when installed (CI always installs it).
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
QUICK=0; [ "${1:-}" = --quick ] && QUICK=1
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fails=0

ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf '  \033[33mskip\033[0m  %s\n' "$*"; }
step() { printf '\n\033[1;96m▌ %s\033[0m\n' "$*"; }
need() { command -v "$1" >/dev/null || { bad "$1 not installed"; return 1; }; }

cd "$ROOT"

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
        *bash*) sh_=bash ;;
        *sh*)   sh_=sh ;;
        *)      continue ;;
    esac
    if $sh_ -n "$f" 2>"$TMP/err"; then ok "$sh_ -n $f"; else bad "$sh_ -n $f"; sed 's/^/        /' "$TMP/err"; fi
done

step "shellcheck"
if command -v shellcheck >/dev/null; then
    for f in "${SCRIPTS[@]}"; do
        head -1 "$f" | grep -q 'sh' || continue
        if shellcheck -S warning "$f" >"$TMP/sc" 2>&1; then ok "$f"; else bad "$f"; sed 's/^/        /' "$TMP/sc"; fi
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
        zig build-exe main.zig "$TMP"/jw-gen/*.c -I"$TMP/jw-gen" -I/usr/include -L/usr/lib \
            -target x86_64-linux-gnu -lc -lwayland-client -O ReleaseFast -femit-bin="$TMP/jerkwall") >"$TMP/zig" 2>&1; then
        ok "build"
        if "$TMP/jerkwall" --fps x >/dev/null 2>&1; then bad "rejects bad --fps"; else ok "rejects bad --fps"; fi
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
