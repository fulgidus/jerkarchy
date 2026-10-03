#!/usr/bin/env bash
# jerkarchy installer. Yes, this is all of it.
# curl -fsSL https://git.fulgid.us/fulgidus/jerkarchy/raw/branch/main/install.sh | bash
set -euo pipefail

REPO=${JERKARCHY_REPO:-https://git.fulgid.us/fulgidus/jerkarchy.git}
SRC=${JERKARCHY_SRC:-$HOME/.local/share/jerkarchy}

say() { printf '\033[1;96m::\033[0m %s\n' "$*"; }

command -v pacman >/dev/null || { echo "jerkarchy needs an Arch-based system." >&2; exit 1; }
[ "$(id -u)" -ne 0 ] || { echo "run as your user, not root (sudo is used when needed)." >&2; exit 1; }

PKGS=(
  sway swaybg swayidle swaylock autotiling xorg-xwayland xdg-desktop-portal-wlr xdg-desktop-portal-gtk
  waybar fuzzel mako nwg-drawer polkit-gnome
  wezterm fish starship ttf-jetbrains-mono-nerd
  grim slurp wl-clipboard cliphist jq libnotify
  pipewire pipewire-pulse wireplumber playerctl brightnessctl wiremix power-profiles-daemon
  networkmanager bluez bluez-utils
  chezmoi git zig
)

say "installing packages (sudo)"
sudo pacman -S --needed --noconfirm "${PKGS[@]}"

say "enabling services"
sudo systemctl enable --now NetworkManager bluetooth power-profiles-daemon

say "fetching dotfiles into $SRC"
if [ -d "$SRC/.git" ]; then git -C "$SRC" pull --ff-only; else git clone --depth 1 "$REPO" "$SRC"; fi

say "applying dotfiles (chezmoi)"
mkdir -p "$HOME/.config/chezmoi"
printf 'sourceDir = "%s"\n' "$SRC" > "$HOME/.config/chezmoi/chezmoi.toml"
chezmoi apply

say "building Zig helpers (sway-binds, jerkwall)"
for tool in sway-binds jerkwall; do ZIG=/usr/bin/zig "$SRC/src/$tool/build.sh"; done

say "done. log out, pick 'Sway' at the login screen, press Super+H."
say "funding received: \$0. features missing: surprisingly few."
