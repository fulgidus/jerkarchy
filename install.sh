#!/usr/bin/env bash
# jerkarchy installer. Yes, this is all of it.
# curl -fsSL https://raw.githubusercontent.com/fulgidus/jerkarchy/main/install.sh | bash
set -euo pipefail

REPO=${JERKARCHY_REPO:-https://github.com/fulgidus/jerkarchy.git}  # public mirror of main
SRC=${JERKARCHY_SRC:-$HOME/.local/share/jerkarchy}

say() { printf '\033[1;96m::\033[0m %s\n' "$*"; }

command -v pacman >/dev/null || { echo "jerkarchy needs an Arch-based system." >&2; exit 1; }
[ "$(id -u)" -ne 0 ] || { echo "run as your user, not root (sudo is used when needed)." >&2; exit 1; }

PKGS=(
  sway swaybg swayidle swaylock autotiling xorg-xwayland xdg-desktop-portal-wlr xdg-desktop-portal-gtk
  waybar fuzzel mako nwg-drawer polkit-gnome thunar
  gtklock gtklock-powerbar-module gtklock-playerctl-module gtklock-userinfo-module
  greetd nwg-hello
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
# Keep an existing config (it holds your settings) on re-install.
if [ ! -f "$HOME/.config/chezmoi/chezmoi.toml" ]; then
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

say "done. log out (or reboot), pick 'Sway' at the login screen, press Super+H."
say "funding received: \$0. features missing: surprisingly few."
