# Roadmap

Each line is a release (gitflow: `release/X.Y.Z` → PR into `main` → tag).
Tools marked ⚠ need a fashware audit (AGENTS.md §3) before they're adopted.
Every release must pass the VM install test, not just "works on my laptop".

| Release | Scope | Tools |
|---|---|---|
| **v0.1.0 — it installs** | CI on every push (`sway -C`, `bash -n`/shellcheck, waybar JSON, Zig build); VM install test (fresh Arch → `install.sh` → working desktop); **snapshot pinning** (`SNAPSHOT` date → Arch Linux Archive mirror for CI, VM test and installs); fix known gaps: ~~launcher (`fuzzel.ini`) still has caelestia colours~~ (themed), ~~no default wallpaper~~ (jerkwall), machine-specific bits into templates | GitHub Actions, QEMU + archiso, shellcheck ⚠, Arch Linux Archive |
| **v0.2.0 — themes** | ~~one palette → every config~~; ~~settings menu + `jerkarchy-set`~~; ~~19 upstream palettes~~; still to do: a parody of an Omarchy theme | chezmoi data + `.tmpl` (nothing new) |
| **v0.3.0 — screensaver** | full-screen terminal effect before the idle lock; any key → lock | terminaltexteffects ⚠ (what Omarchy uses) or cmatrix/cbonsai ⚠ |
| **v0.4.0 — omakase profiles** | `install.sh --with docker,office,gaming,dev` | Docker ⚠, LibreOffice ⚠, Steam (Valve, clean), Neovim/VSCodium ⚠ |
| **v0.5.0 — login screen** | themed login, VM-tested before it touches a real machine | greetd + tuigreet ⚠, or an SDDM theme |
| **v0.6.0 — opt-in AI** | selection / screenshot / terminal assistant keys, off by default, local models only | llama.cpp ⚠ |
| **v0.7.0 — updates** | `jerkarchy-update` = pull + `chezmoi apply` + rebuild helpers; **automatic snapshot bumps** (below) | chezmoi, GitHub Actions |
| **v1.0.0 — ISO** | net-install ISO (< 2 GB) built in Actions, attached to a GitHub Release, installs jerkarchy on first boot | archiso |

## Automatic snapshot bumps (v0.7.0)

Goal: stay current without babysitting; hear about it only when it breaks.

1. Weekly scheduled GitHub Actions job checks out `main`, sets `SNAPSHOT` to
   today, runs the full pipeline (lint, config checks, Zig build, VM install
   test).
2. **Green:** push `feature/snapshot-YYYY-MM-DD` to Forgejo and merge it into
   `develop` (`--no-ff`). No notification. It reaches `main` with the next
   release. Needs a Forgejo write deploy key stored as a GitHub secret.
3. **Red:** push nothing; the pinned snapshot stays. GitHub emails the owner
   on failed scheduled runs; the job also opens a GitHub issue with the
   failing step and log excerpt.

## Related project: fashware audit CLI

A separate project (name TBD), not part of this repo: source on
git.fulgid.us, mirrored to GitHub, published independently on the AUR.
Planned after v0.1.0.

- CLI (Zig preferred): audit a package/repo, or the whole installed system,
  on three axes (adjacency, governance, controversy) with sources.
- pacman hook: informs on install, never blocks.
- Own verdict database (tier, sources, date, verified/reported), versioned and
  updatable separately from the code.
- The two third-party lists are **fetched live and cached, never bundled**
  (their redistribution licence is unclear).
- jerkarchy consumes it: `install.sh` installs it, CI runs it over
  jerkarchy's own package list.

## Later / maybe

- Per-project dev shells via Nix — if ever, use **Lix** (community fork,
  AFNix-hosted), opt-in only, never for the system layer.
- A real pacman repo (Forgejo's Arch registry) if chezmoi-based updates stop
  being enough.
