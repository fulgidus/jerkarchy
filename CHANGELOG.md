# Changelog

Releases are tagged on `main` (gitflow, see AGENTS.md). The release workflow
publishes the section for each version as its release notes.

## v0.1.4

- **Screenshots and screensaver GIFs on every release:** CI renders all
  themes (bar, wallpaper, terminal, settings menu) and records every
  screensaver mode, attaches them to the release, and publishes a
  **gallery** on the site.
- **Fix: a plain install (no profiles) exited at once in v0.1.3** — the
  profile list came out empty and `grep` failing on it ended the script.
  CI now dry-runs a plain install too.
- Releases now run shellcheck before tagging (v0.1.3's first CI run caught
  a warning and a root-only dry run; both fixed in v0.1.3).

## v0.1.3

- **Install profiles**, any combination: `install.sh --with
  dev,docker,office,gaming,browsers,creator,electronics`. Fashware-flagged
  apps (Neovim, Code-OSS, Emacs, LibreOffice, Thunderbird, LibreWolf,
  Vivaldi, Audacity, Blender) come next to their clean alternative, named
  with the reason at the end of the install; `--clean-only` skips them.
  Gaming enables Arch's multilib; docker enables its socket and group;
  electronics adds you to `uucp` for serial ports.
- **Updates:** `jerkarchy-update` (or Settings › help › update) pulls the
  source, shows what's new from the changelog, and re-runs the installer.
  Install choices (profiles, `--no-swayfx`, `--clean-only`) are remembered
  in `~/.config/jerkarchy/install.conf`.
- **SwayFX on plain Arch**, built from the AUR when there's a GPU; plain sway
  if there isn't or the build fails.
- Super+W falls back to Vivaldi when LibreWolf isn't installed.

## v0.1.2

- **Matte Billionaire (parody):** Omarchy's Matte Black, in Founding Patron
  gold and dollar green. Our own palette.
- **SwayFX by default where the repos carry it** (CachyOS), plain sway
  elsewhere. Opt out at install with `--no-swayfx` (or `JERKARCHY_SWAYFX=0`),
  or at runtime: Settings › animations › SwayFX effects. Re-running install.sh
  with SwayFX installed no longer trips over sway/SwayFX conflicts.
- **The source lives in `~/Documents/jerkarchy`** (XDG Documents); existing
  installs are moved from `~/.local/share/jerkarchy` and chezmoi follows.

## v0.1.1

- **Screensaver:** after 5 idle minutes (lock at 10; both settings, 0 = off),
  with a big title (`saver_title`) and the time. Modes (`saver_mode`): the
  live wallpaper, or terminal art drawn by jerksaver (Zig): matrix, bonsai,
  city, galaxy, planets, three-body orbits (figure-eight and
  Šuvakov–Dmitrašinović solutions, integrated live), random. Any input ends it.
- **Workspace slide:** both workspaces move (jerkslide, Zig), the bar stays
  put; Super+1–9, Super+Ctrl+←/→ and 4-finger touchpad swipes. Optional
  SwayFX fade on top. Settings › animations.
- **Lock and login screens** that look like the desktop: gtklock and greetd +
  nwg-hello, same card, theme colours, live wallpaper behind the login.
  install.sh enables greetd only when no display manager is set.
- **Settings:** grouped menu (look / system / help), arrow-key navigation
  (→ open, ← back), keyboard layout, screensaver, animations; title input
  with a live character counter (jerkprompt, Zig).
- **Fixes:** logout under sway (it asked uwsm first and did nothing); theme
  changes from the bar's gear now restart the wallpaper; flag themes no
  longer decorate the bar; About shows the real version.

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
