#!/usr/bin/env bash
# jerkarchy installer. Yes, this is all of it.
# curl -fsSL https://raw.githubusercontent.com/fulgidus/jerkarchy/main/install.sh | bash
#   … | bash -s -- --no-swayfx     plain sway even where SwayFX is available
#   … | bash -s -- --with dev,office   also install profiles, any combination:
#                                      dev docker office gaming browsers creator
#                                      electronics; add --clean-only to skip the
#                                      fashware-flagged apps in them
#   --swayfx undoes an earlier --no-swayfx.
# Re-run any time to add profiles: chosen ones are remembered for updates.
# Environment: JERKARCHY_SRC (source checkout; default ~/Documents/jerkarchy),
# JERKARCHY_REPO (clone URL), JERKARCHY_SWAYFX=0 (same as --no-swayfx),
# JERKARCHY_DRY_RUN=1 (print the package list and flagged apps, then stop).
set -euo pipefail

REPO=${JERKARCHY_REPO:-https://github.com/fulgidus/jerkarchy.git}  # public mirror of main
# The source checkout lives in your Documents folder (it's yours to read and
# hack on), not hidden in ~/.local/share as older versions did.
docs=$(xdg-user-dir DOCUMENTS 2>/dev/null || true)
[ -n "$docs" ] && [ "$docs" != "$HOME" ] || docs=$HOME/Documents
SRC=${JERKARCHY_SRC:-$docs/jerkarchy}
# Choices from earlier runs (profiles, --no-swayfx, --clean-only) are kept
# here so re-runs and jerkarchy-update don't undo them; options add to them.
CONF=${XDG_CONFIG_HOME:-$HOME/.config}/jerkarchy/install.conf
PROFILES_SAVED="" SWAYFX_SAVED=1 CLEAN_ONLY_SAVED=0
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"
SWAYFX=${JERKARCHY_SWAYFX:-$SWAYFX_SAVED}
WITH="" CLEAN_ONLY=$CLEAN_ONLY_SAVED
while [ $# -gt 0 ]; do
    case $1 in
        --no-swayfx)  SWAYFX=0 ;;
        --swayfx)     SWAYFX=1 ;;
        --clean-only) CLEAN_ONLY=1 ;;
        --with)       WITH=${2:?--with needs a list, e.g. dev,office}; shift ;;
        --with=*)     WITH=${1#--with=} ;;
        *) echo "unknown option: $1 (see the top of install.sh)" >&2; exit 2 ;;
    esac
    shift
done

# Profiles: profile, package, and for fashware-flagged apps the reason and the
# clean alternative in the same profile. Flagged apps are installed next to
# their alternative (so you can switch when you like) unless --clean-only.
PROFILES=$(cat <<'TABLE'
dev	base-devel
dev	helix
dev	vim
dev	ripgrep
dev	fd
dev	fzf
dev	neovim	maintainer Justin M. Keyes is on the weird-guys list	helix, vim
dev	code	Microsoft (Code - OSS) is on the fashware list	helix, vim
dev	emacs	GNU/FSF: Richard Stallman is on the weird-guys list	helix, vim
docker	docker
docker	docker-compose
docker	docker-buildx
office	gnumeric
office	abiword
office	zathura
office	zathura-pdf-mupdf
office	aerc
office	libreoffice-fresh	forked from OpenOffice.org, then Oracle's (fashware list)	gnumeric, abiword
office	thunderbird	Mozilla: co-founder Brendan Eich is on the weird-guys list	aerc
gaming	steam
gaming	lutris
gaming	wine
gaming	gamemode
gaming	lib32-gamemode
gaming	mangohud
gaming	lib32-mangohud
browsers	librewolf	a Firefox fork: Mozilla's co-founder Brendan Eich is on the weird-guys list	none: every engine is Mozilla's, Google's or Apple's
browsers	vivaldi	built on Chromium (Google, fashware list); its UI is closed source	none: every engine is Mozilla's, Google's or Apple's
creator	gimp
creator	shotcut
creator	inkscape
creator	tenacity
creator	audacity	Muse Group's 2021 telemetry and privacy-policy rug-pull	tenacity
creator	blender	funded by NVIDIA, Microsoft, AMD, Intel, Facebook, Dell, Adobe (fashware list)	none comparable
electronics	kicad
electronics	kicad-library
electronics	platformio-core
electronics	platformio-core-udev
electronics	arduino-cli
TABLE
)
# Remembered profiles plus the ones asked for now.
PROFILE_LIST=$(printf '%s\n' $PROFILES_SAVED $(printf '%s' "$WITH" | tr ',' ' ') | grep -v '^$' | sort -u)
for p in $PROFILE_LIST; do
    printf '%s\n' "$PROFILES" | cut -f1 | grep -qx "$p" || { echo "unknown profile: $p (dev docker office gaming browsers creator electronics)" >&2; exit 2; }
done

say() { printf '\033[1;96m::\033[0m %s\n' "$*"; }

command -v pacman >/dev/null || { echo "jerkarchy needs an Arch-based system." >&2; exit 1; }
[ "$(id -u)" -ne 0 ] || { echo "run as your user, not root (sudo is used when needed)." >&2; exit 1; }

PKGS=(
  swaybg swayidle swaylock autotiling xorg-xwayland xdg-desktop-portal-wlr xdg-desktop-portal-gtk
  waybar fuzzel mako nwg-drawer polkit-gnome thunar
  gtklock gtklock-powerbar-module gtklock-playerctl-module gtklock-userinfo-module
  greetd nwg-hello
  wezterm fish starship ttf-jetbrains-mono-nerd
  grim slurp wl-clipboard cliphist jq libnotify
  pipewire pipewire-pulse wireplumber playerctl brightnessctl wiremix power-profiles-daemon
  networkmanager bluez bluez-utils
  chezmoi git zig
)

# Compositor: SwayFX (sway with animations; same config) unless opted out.
# From the repos where they carry it (CachyOS), else built from the AUR
# (plain Arch), falling back to plain sway if that fails. SwayFX renders
# with GLES only: without a GPU render node it would be a black screen, so
# GPU-less machines (VMs, servers) get plain sway. An installed SwayFX
# already provides sway.
BUILD_SWAYFX=0
if [ "$SWAYFX" = 1 ] && pacman -Q swayfx >/dev/null 2>&1; then
    say "compositor: SwayFX (installed)"
elif [ "$SWAYFX" = 1 ] && ! ls /dev/dri/renderD* >/dev/null 2>&1; then
    say "compositor: sway (SwayFX needs a GPU; none found)"; PKGS+=(sway)
elif [ "$SWAYFX" = 1 ] && pacman -Si swayfx >/dev/null 2>&1; then
    say "compositor: SwayFX (opt out: --no-swayfx)"; PKGS+=(swayfx)
elif [ "$SWAYFX" = 1 ]; then
    say "compositor: SwayFX, built from the AUR below (opt out: --no-swayfx)"; BUILD_SWAYFX=1
else
    say "compositor: sway"; PKGS+=(sway)
fi

# SwayFX from the AUR, built as you with makepkg. The PKGBUILD asks for
# "scenefx0.5", a name nothing on plain Arch provides: extra's scenefx is
# exactly that library (0.5), so point the dependency at it.
build_swayfx() {
    sudo pacman -S --needed --noconfirm base-devel || return 1
    local tmp; tmp=$(mktemp -d)
    git clone --depth 1 https://aur.archlinux.org/swayfx.git "$tmp/swayfx" || return 1
    sed -i 's/"scenefx0\.5"/"scenefx"/' "$tmp/swayfx/PKGBUILD"
    (cd "$tmp/swayfx" && makepkg -si --noconfirm --needed) || return 1
    rm -rf "$tmp"
}

FLAGGED=()
for p in $PROFILE_LIST; do
    while IFS=$'\t' read -r prof pkg why alt; do
        [ "$prof" = "$p" ] || continue
        if [ -n "$why" ]; then
            [ "$CLEAN_ONLY" = 1 ] && continue
            FLAGGED+=("$pkg: $why (clean alternative: $alt)")
        fi
        PKGS+=("$pkg")
    done <<<"$PROFILES"
done
if [ "${JERKARCHY_DRY_RUN:-0}" = 1 ]; then  # tests: show what would happen, change nothing
    printf 'package: %s\n' "${PKGS[@]}"
    [ ${#FLAGGED[@]} -gt 0 ] && printf 'flagged: %s\n' "${FLAGGED[@]}"
    exit 0
fi
# Steam and the lib32 libraries live in Arch's official multilib repo.
if printf '%s\n' $PROFILE_LIST | grep -qx gaming && ! grep -q '^\[multilib\]' /etc/pacman.conf; then
    say "enabling the multilib repo (gaming profile)"
    sudo sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
    sudo pacman -Sy
fi

say "installing packages (sudo)${PROFILE_LIST:+, profiles: $(echo $PROFILE_LIST)}"
# --ask 4: if switching between sway and SwayFX, replace the other one.
sudo pacman -S --needed --noconfirm --ask 4 "${PKGS[@]}"

if [ "$BUILD_SWAYFX" = 1 ] && ! build_swayfx; then
    say "SwayFX build failed: installing plain sway instead"
    sudo pacman -S --needed --noconfirm sway
fi

say "enabling services"
sudo systemctl enable --now NetworkManager bluetooth power-profiles-daemon
if printf '%s\n' $PROFILE_LIST | grep -qx docker; then
    # The docker group is root-equivalent; it's what "docker without sudo" means.
    sudo systemctl enable --now docker.socket
    sudo usermod -aG docker "$(id -un)"
fi
if printf '%s\n' $PROFILE_LIST | grep -qx electronics; then
    sudo usermod -aG uucp "$(id -un)"   # serial ports (/dev/ttyACM*, /dev/ttyUSB*) for boards
fi
mkdir -p "$(dirname "$CONF")"
cat > "$CONF" <<CONFEOF
# jerkarchy install choices, written by install.sh; re-runs and
# jerkarchy-update reuse them. Edit with care, or re-run install.sh.
PROFILES_SAVED="$(echo $PROFILE_LIST)"
SWAYFX_SAVED=$SWAYFX
CLEAN_ONLY_SAVED=$CLEAN_ONLY
CONFEOF

# Older installs kept the source in ~/.local/share/jerkarchy: move it.
old=$HOME/.local/share/jerkarchy
if [ -z "${JERKARCHY_SRC:-}" ] && [ -d "$old/.git" ] && [ ! -e "$SRC" ]; then
    say "moving the source from $old to $SRC"
    mkdir -p "$(dirname "$SRC")" && mv "$old" "$SRC"
fi

say "fetching dotfiles into $SRC"
if [ -d "$SRC/.git" ]; then git -C "$SRC" pull --ff-only; else git clone --depth 1 "$REPO" "$SRC"; fi

say "applying dotfiles (chezmoi)"
mkdir -p "$HOME/.config/chezmoi"
# Keep an existing config (it holds your settings) on re-install; just point
# it at the source.
if [ -f "$HOME/.config/chezmoi/chezmoi.toml" ]; then
    sed -i "s|^sourceDir = .*|sourceDir = \"$SRC\"|" "$HOME/.config/chezmoi/chezmoi.toml"
else
    cat > "$HOME/.config/chezmoi/chezmoi.toml" <<CFG
sourceDir = "$SRC"

# jerkarchy settings override the defaults in home/.chezmoidata/settings.toml.
# Change them with jerkarchy-set KEY VALUE or the settings menu (Super+,).
[data]
CFG
fi
chezmoi apply

say "building Zig helpers (sway-binds, jerkwall, jerkslide, jerksaver, jerkprompt)"
for tool in sway-binds jerkwall jerkslide jerksaver jerkprompt; do ZIG=/usr/bin/zig "$SRC/src/$tool/build.sh"; done

say "login screen (greetd + nwg-hello, themed like the lock screen)"
# The greeter runs as another user and can't read your home: its files live
# in /var/lib/jerkarchy/greeter (yours, so greeter-sync needs no sudo).
sudo install -d -o "$(id -un)" -m 755 /var/lib/jerkarchy/greeter
for f in nwg-hello.css nwg-hello.json jerkarchy.glade; do
    sudo ln -sfn "/var/lib/jerkarchy/greeter/$f" "/etc/nwg-hello/$f"
done
# Only replace greetd's stock config (the agreety one), never a custom one.
if grep -q '^command = "agreety' /etc/greetd/config.toml 2>/dev/null; then
    sudo sed -i 's|^command = "agreety.*|command = "sway -c /var/lib/jerkarchy/greeter/sway-config"|' /etc/greetd/config.toml
fi
"$HOME/.local/bin/greeter-sync"
# Switching display managers is yours to do: enable greetd only if none is set.
if dm=$(systemctl show -P Id display-manager.service 2>/dev/null) && [ -n "$dm" ] && [ "$dm" != display-manager.service ]; then
    say "keeping your display manager ($dm). To switch: sudo systemctl disable $dm && sudo systemctl enable greetd"
else
    sudo systemctl enable greetd
fi

if [ ${#FLAGGED[@]} -gt 0 ]; then
    say "installed, but on the fashware lists (switch when you like; --clean-only skips them):"
    printf '     %s\n' "${FLAGGED[@]}"
fi
say "done. log out (or reboot), pick 'Sway' at the login screen, press Super+H."
say "funding received: \$0. features missing: surprisingly few."
