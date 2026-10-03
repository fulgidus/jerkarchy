# Changelog

Releases are tagged on `main` (gitflow, see AGENTS.md). The release workflow
publishes the section for each version as its release notes.

## v0.1.0

First release: it installs, on a fresh Arch, unattended, and the VM test
proves it.

- **Desktop:** sway + autotiling, waybar, fuzzel, mako, nwg-drawer,
  swaylock/swayidle, wezterm + fish + starship. Key bindings follow the
  author's old Hyprland layout; `Super+H` shows them, generated from the
  config.
- **Bar:** Wi-Fi and Bluetooth drop-downs, audio mixer, media, caffeine,
  battery + power profile in one item with a battery estimate that's actually
  right.
- **Wallpaper:** jerkwall, a live Delaunay mesh in Zig (GLES2, CPU fallback).
  The lock screen shows the same frame.
- **Themes:** 48: classics from their upstream projects, flags (queer, bi,
  trans, polyam, antifa) and 24 monochrome. Every config with a colour
  follows the theme; flag themes also put the flag on the bar.
- **Settings:** one menu (`Super+,` or the bar's gear) and one command,
  `jerkarchy-set`, for theme, wallpaper, keyboard layout and power profile.
- **Notifications:** click for the notification's actions, copy, dismiss,
  dismiss all; dismissed ones stay copyable in the history.
- **Installer:** `install.sh`, zero questions, official Arch repos only.
- **CI:** `ci/check.sh` on an Arch container pinned to the `SNAPSHOT` date;
  `ci/vm-test.sh` boots a pinned Arch cloud image, installs, and checks that
  the desktop comes up.

Assets: `jerkwall` and `sway-binds` built by CI for x86_64 (the installer
builds them from source; these are for convenience).
