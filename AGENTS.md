# AGENTS.md — working on jerkarchy

Rules for any agent (or human) changing this repo. `CLAUDE.md` is a symlink
to this file. Read it fully before your first edit. When a rule here
conflicts with your defaults, this file wins.

jerkarchy is a satirical, deliberately lazy rip-off of Omarchy: a sway-based
dotfiles preset for Arch-based systems, applied with chezmoi. The satire only
works if the thing actually works — so quality rules below are strict.

---

## 1. Git: gitflow

- **Forgejo is the source of truth:** `ssh://git@git.fulgid.us/fulgidus/jerkarchy.git`
  (port 22; ignore any `:2222` the web UI may show).
- GitHub (`github.com/fulgidus/jerkarchy`) is a **push mirror of `main` only**.
  Never push to GitHub. Anything pushed there directly is overwritten.
- Branching is **gitflow**:

  | Branch | From | Merges into | Purpose |
  |---|---|---|---|
  | `main` | — | — | released states only, each merge tagged `vX.Y.Z` (semver) |
  | `develop` | `main` | — | integration; the base for all work |
  | `feature/<name>` | `develop` | `develop` | any change: features, fixes, docs, chores |
  | `release/<X.Y.Z>` | `develop` | `main` **and** `develop` | version bump, final checks, tag on `main` |
  | `hotfix/<X.Y.Z>` | `main` | `main` **and** `develop` | urgent fix to a release, tag on `main` |

- `develop` is the **default branch** on Forgejo.
- **`main` is protected: no pushes, only pull-request merges on Forgejo.**
  A release or hotfix is a PR (`release/X.Y.Z` → `main`, or
  `hotfix/X.Y.Z` → `main`) that the user reviews and merges. After the merge:
  tag `vX.Y.Z` on the merge commit (annotated tag), push the tag, and merge
  `main` back into `develop`. Tags are mirrored to GitHub too.
- Merges use `--no-ff`. Delete merged `feature/*` branches (local and remote).
- **Agents never commit to `main` or `develop` directly**: work on
  `feature/*`, push it, and merge into `develop` when it's finished and
  verified (§4). Anything that reaches `main` (PRs, tags) is
  **outward-facing**: only with the user's go-ahead.
- Versions: `v0.0.0` is the first tag. Bump semver per release: patch for
  fixes, minor for new features or binds, major for breaking changes to the
  layout or installer.
- Never force-push `main` or `develop`. Never rewrite history someone else
  pushed; merge it.
- Commit messages: imperative summary line (≤ 72 chars), a body explaining
  *why* when it isn't obvious. **No `Co-Authored-By:` or other tool/agent
  attribution** in commits, PRs, tags, or files. The user is the author.
- No secrets, ever: Wi-Fi passwords, tokens, keys, `.bak` files, personal
  data. Scan before committing.

## 2. Repo layout and chezmoi

```
.chezmoiroot      → "home": chezmoi's source lives in home/
home/             dotfiles (chezmoi naming: dot_, executable_, private_, empty_, *.tmpl)
src/<tool>/       source of compiled helpers (Zig) + build.sh; binaries are never committed
                  (sway-binds: binding list; jerkwall: live Delaunay wallpaper)
install.sh        the whole installer; keep it short and readable
SNAPSHOT          Arch Linux Archive date (YYYY-MM-DD) that builds install from
ci/check.sh       all automated checks (local + GitHub Actions)
ci/vm-test.sh     end-to-end install test in a QEMU VM (before every release)
.github/          CI workflow (runs on main only; GitHub sees nothing else)
README.md         user-facing, satirical, sourced (see §9)
ROADMAP.md        what gets built, in which release, with which tools
AGENTS.md         this file (CLAUDE.md → symlink)
```

- **Repo and live system must match.** Edit files in `home/` and run
  `chezmoi apply`, or edit live and run `chezmoi re-add`. Before every commit,
  `chezmoi diff` must print nothing.
- Anything machine-specific (paths under `/home/<user>`, output names like
  `eDP-1`, battery thresholds, touchpad IDs) goes through a chezmoi template
  (`.tmpl`, `{{ .chezmoi.homeDir }}`, `{{ if stat … }}`) or stays out.
- No assets of unclear license (wallpapers, fonts, icons). If it isn't ours or
  clearly redistributable, it doesn't go in.
- Scope is the **sway** setup. River, Hyprland, caelestia, and the user's
  shell config are out of scope.

## 3. Dependency policy (read before adding anything)

Every new package, library, service, or tool must pass a **fashware audit**
before it is added, using the user's two lists:
[~rabbits/fashware](https://git.sr.ht/~rabbits/fashware) and
[weird little guys of FOSS](https://drewdevault.com/weird-guys/). Fetch them
live; they change.

- Three separate verdicts: **adjacency** (owned/founded/led/funded by a listed
  entity or person, or a hard dependency on one), **governance** (rug-pulls,
  license churn, telemetry, stealth rebrands), **controversy** (unlisted
  leaders whose public conduct matches the lists' criteria).
- **No gray zones on lineage:** a fork of, or project led by people from, a
  flagged project is flagged too. Report it as a hit, not as nuance.
- Universal infrastructure (Linux, GNU toolchain, Mesa, languages) is
  mentioned, never scored.
- Report hits plainly with sources and let the user decide. Don't silently
  skip a good tool, and don't silently add a flagged one.
- **Prefer Zig** where a reasonable Zig option exists; always state each
  pick's language.
- Known results so far: flagged — Hyprland, dwl/suckless, KDE (Google and
  Framework patrons), network-manager-applet (IBM → Red Hat), iwd/ConnMan
  (Intel), Ghostty, CachyOS (Framework sponsorship), mise (Omacom Foundation).
  Clean — sway/wlroots, waybar, fuzzel, mako, nwg-drawer, autotiling, wezterm,
  starship, swaylock, blueman, pwvucontrol (not in Arch repos), wiremix, shellcheck,
  COSMIC. Accepted as test-only tooling despite a hit: QEMU (Red Hat → IBM).
- **Check that a program exists before wiring it in** (`command -v`). Do not
  copy app names from old configs (this repo already shipped dead binds to
  `codium`, `blueman`, `pavucontrol`). If something isn't installed, either
  ask the user to install it or add a visible fallback — never a silent no-op.
- **Packages must be in Arch's official repos** (`core`/`extra`): the user's
  machine has CachyOS repos, plain Arch doesn't. Check against the pinned
  `SNAPSHOT` database, not the local `pacman -Si`. (pwvucontrol was CachyOS-only
  and broke install.sh; the VM test caught it.)
- Never install system packages yourself; the user runs `sudo`. Give them the
  exact command.

## 4. Verify before you claim

"It should work" is not done. Done means you saw it work.

- **`ci/check.sh` must pass before any merge into `develop`.** It renders the
  dotfiles with chezmoi into a temp home and runs every automated check
  (shell syntax, shellcheck, `sway -C`, waybar JSON, fuzzel configs,
  `bar-battery` edge cases, hygiene, the Zig build). GitHub Actions runs the
  same script on `main`, inside an Arch container pinned to `SNAPSHOT`. When
  you add a check, prove it can fail (break the thing once in a throwaway
  worktree).
- **`ci/vm-test.sh` must pass before every release** (and after any change to
  `install.sh` or the package list). It boots the pinned Arch cloud image in
  QEMU/KVM, pins pacman to `SNAPSHOT`, runs `install.sh` from the current
  commit, starts sway headless and checks the desktop comes up, plus a
  screenshot. Its first run caught three real bugs (a CachyOS-only package,
  missing Xwayland, missing pipewire-pulse) that local checks never could.
- **`SNAPSHOT`** holds the Arch Linux Archive date that CI (and later the VM
  test and installer) install from. Bump it deliberately, never by accident.

- **sway config:** `sway -C -c home/dot_config/sway/config` must exit 0 with
  no warnings. Then `swaymsg reload` on the live session if appropriate.
- **Shell scripts:** `sh -n` (or `bash -n`) for every changed script, then run
  the script's data path for real (parse/lookup logic separately from UI).
- **waybar JSON:** parse it (strip `//` comments first) after every edit;
  restart waybar and screenshot the bar (`grim -g …`) to check the result.
- **Nested tests** for anything compositor-level:
  `WLR_BACKENDS=wayland sway -c <trimmed-config>` inside the live session.
  The trimmed config must **not** contain `include /etc/sway/config.d/*`,
  `dbus-update-activation-environment`, or any daemon that already runs live
  (waybar, mako, nwg-drawer resident, swayidle). Afterwards confirm
  `systemctl --user show-environment` still shows the live `WAYLAND_DISPLAY`.
  Breaking the live session's env happened once; don't repeat it.
- **Edge cases with fake data:** e.g. `bar-battery` takes a fake sysfs dir as
  `$1` — test charging, full, plugged, critical, and empty/garbage values.
  Output consumed by waybar must stay valid JSON in every case.
- Say plainly what you could *not* test (clicks, hover tooltips, real
  pairing/connecting, multi-monitor) instead of implying it was tested.
- **The user can't see your tool output.** Screenshots and renders you view
  are visible only to you. To show the user something visual, open it on
  their screen (`swaymsg exec qview <file>`) or save it under `~/Pictures`
  and tell them where.

## 5. Shell scripts (`home/dot_local/bin/`)

- POSIX `sh` unless bash is genuinely needed; `set -e` where it's safe.
- A header comment: what it does, usage, and *why* it exists if it replaces
  something stock.
- Programs spawned by sway get sway's environment, not your shell's: use full
  paths (`$bin/…`, `$HOME/.local/bin/…`) in binds.
- sway parses quotes and `;` inside `exec` lines its own way: anything beyond
  `exec program args` goes into a script.
- **`pkill -f` patterns must be anchored** to the target's command line
  (`^fuzzel --config …`, `^/usr/bin/wezterm-gui start .*--class …`). An
  unanchored pattern has already killed the agent's own shell. Toggles use
  this pattern: kill-if-running-else-start.
- Never parse display text to recover data. Carry hidden fields (tab-separated
  MAC, SSID, flags) alongside what's shown and look selections up by them.
- Numeric reads from sysfs/IPC must tolerate missing, empty, or non-numeric
  values.
- The agent's own tool shell may be **zsh** (no word splitting, glob errors on
  `[`/`*`). Run multi-word loops with `bash -c` or arrays from a file.

## 6. sway config conventions

- Keybinds follow the user's old Hyprland layout (Super+T terminal, Super+Q
  close, Super+arrows focus, Super+Shift+arrows move, Super+Alt+1–9 move to
  workspace, Super+Ctrl+←/→ relative workspaces via `sway-ws`, Ctrl+Alt+Del
  session menu). Don't introduce WM-default binds that clash with that.
- **The binding list is generated, never hand-written.** `Super+H` renders
  `sway-binds` output from the config. To make that work:
  - group binds into sections with banner comments:
    ```
    # ------------------------------------------------------------------
    # Section title
    # ------------------------------------------------------------------
    ```
  - label a bind with `#: description` on the line(s) directly above it when
    the auto-generated text (from the command) isn't readable;
  - never add a separate cheat-sheet file.
- Check new binds for duplicates (`sway -C` warns) and against existing ones.

## 7. Look and feel

- Palette (use these exact values): background `#0a0a0f`, text `#c8c8d0`,
  bright text `#e5e1e7`, dim `#55556a`/`#8a8aa0`, borders `#2a2a35`,
  **cyan `#00f0ff`** (focus/accent), **magenta `#ff2b6d`** (alerts,
  discharging, performance), green `#00ff9f` (charging, power-saver), yellow
  `#ffcc00` (caffeine, warnings). Font: JetBrainsMono Nerd Font. Square
  corners, 1–2 px borders, no animations.
- **Bar popups must look like the bar**: fuzzel drop-downs anchored top-right
  under the bar, styled by `home/dot_config/fuzzel/bar-menu.ini`
  (`wifi-menu`, `bt-menu` are the reference). No centered generic windows
  for things a menu can do.
- **Icons:** Material Design Nerd Font glyphs. Private-use glyphs get stripped
  by editing tools, so **never write raw glyphs into files**:
  - waybar JSON: `\uXXXX` escapes (surrogate pairs for U+F0000+);
  - shell scripts: `printf` octal escapes (`printf '\363\260\214\252'`);
  - before proposing an icon, render it with the real font and check the shape
    (codepoint guesses have been wrong before).
- Bar text is terse: icon + value, no redundant prefixes. Info that doesn't
  fit goes in the tooltip.

## 8. Zig helpers (`src/`)

- Zig 0.16. Main signature: `pub fn main(init: std.process.Init) !void`
  (or `Init.Minimal` for argv only); file I/O via `std.Io` (`init.io`).
- Prefer no libc. If libc is required (e.g. `@cImport` of libwayland), build
  with `-target x86_64-linux-gnu`: Zig's linker can't handle the `.sframe`
  relocations in this system's `crt1.o`.
- Each tool has a `build.sh` that builds and installs into `~/.local/bin`.

## 9. README and other prose

- The README is satire **with sources**. Every factual claim about people,
  companies, or money links a source; opinions are labelled as opinions.
- Report list memberships as facts ("has an entry on the fashware list"),
  attribute the lists' reasons to their authors, and never add contact
  details or anything that facilitates harassment.
- Keep the hypocrisy section honest and current, without naming or promoting
  specific AI products.
- License: X11, `Copyright (c) 2026 Alessio Corsi`. Credit is required;
  using the author's name to promote forks is not allowed. Don't change the
  license text.

## 10. Talking to the user

- Blunt and concise. Recommend; don't survey. One question at a time, and
  only for decisions that are genuinely theirs.
- Own mistakes immediately and specifically; fix them, then save the lesson
  here if it's a convention.
- Before anything outward-facing (publishing, making a repo public, merging
  or pushing to `main`, tagging a release, deleting), confirm with the user
  unless they already said so in the current request.
