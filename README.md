# jerkarchy

**Twelve men. One distro. Everyone finishes.**

*Ugly, boring & un-funded Linux.*

The immalleable dotfiles for the age of not being sponsored by billionaires.

> When you can vibe code whatever app comes to your mind, you should be able
> to vibe code your operating system. So we did. In one evening. For $0.

jerkarchy is an opinionated desktop setup for Arch-based systems, built on
**sway**. It is a deliberately lazy, half-assed, obvious rip-off of
[Omarchy](https://omarchy.org/), made to answer one question:

**What does $15.5 million buy that an evening and a dotfiles manager don't?**

## Install

```sh
curl -fsSL https://git.fulgid.us/fulgidus/jerkarchy/raw/branch/main/install.sh | bash
```

(While the repo is private, clone it and run `./install.sh` instead.)

That's it. That's the product. It installs some packages, runs
[chezmoi](https://www.chezmoi.io/), and builds one small Zig tool. No ISO, no
foundation, no patrons. Read the script first — it's short on purpose.

## Features

Omarchy, per its own homepage, gives you a tiling WM, AI integration,
themes, a dev stack and a nice installer. jerkarchy gives you:

| | Omarchy | jerkarchy |
|---|---|---|
| Tiling window manager | Hyprland | sway (oldest, most boring, most stable) |
| Hyprland-style splitting | yes | yes ([autotiling](https://github.com/nwg-piotr/autotiling)) |
| Bar | yes | waybar, with Wi-Fi/Bluetooth drop-downs, media, caffeine, battery + power profile in one item |
| Battery estimate that's actually right | ? | yes — from the real charge drop, not waybar's broken maths |
| Launcher / app drawer | yes | fuzzel / nwg-drawer |
| Lock screen that doesn't look like a crash | ? | yes (we learned this the hard way) |
| Keybinding cheat sheet | static | **generated from the config** (`Super+H`) |
| Workspaces that appear when you walk into them | yes | yes |
| Installer | ISO, 5 questions | `curl \| bash`, 0 questions |
| Wallpaper | a folder of images | a **live** Delaunay mesh that drifts and slowly shifts colour, written in Zig, GPU-drawn at 30 fps (CPU fallback), slows down on power-saver |
| Themes | 20+ | 19, each palette taken from its own upstream project (Tokyo Night, Catppuccin, Gruvbox, Nord, Rosé Pine, …). The default is still cyan. |
| Settings | ? | one drop-down (gear on the bar, `Super+,`): theme, wallpaper, power, network, … and a CLI, `jerkarchy-set` |
| AI agents | built in | the author vibe-coded the whole thing, so: *built out* |
| Funding | ~$15.5M pledged | $0 |

## Sponsors

None.

For comparison, the Omacom Foundation launched in August 2026 with twelve
$1M Founding Patrons — among them Tobi Lütke, Patrick Collison, Michael Dell,
Jack Dorsey, Matthew Prince, Drew Houston, Brian Armstrong, Jason Fried and
DHH — plus corporate patrons such as Meta Superintelligence Labs,
DigitalOcean and Alibaba Cloud, and AI-token pledges from Meta, Anthropic,
OpenAI, Fireworks and OpenRouter, for roughly $15.5M in total
([It's FOSS](https://itsfoss.com/news/omarchy-launches-omacom-foundation/),
[omarchy.org](https://omarchy.org/)). The foundation holds Hyprland's
trademarks and sponsors Hyprland, Quickshell and mise.

**Our opinion**, for what it's worth: a config collection like this one costs
an evening. When eight-figure money lines up behind one, it isn't buying
technology. It's buying a flag. Every individual patron named above — and
DigitalOcean — has an entry on the community list
[~rabbits/fashware](https://git.sr.ht/~rabbits/fashware); DHH, Jack Dorsey and
Tobi Lütke are also on Drew DeVault's
[weird little guys of FOSS](https://drewdevault.com/weird-guys/). Read the
entries and their sources, and decide for yourself.

## Full disclosure (the hypocrisy section)

- This repo was vibe-coded with an AI assistant from one of the labs pledging
  tokens to the Omacom Foundation. We know. That's the joke, and also the
  point: the tooling isn't the moat. Anyone can do this.
- It's mirrored to **GitHub** (Microsoft, also on the list) purely to burn
  their CI minutes. The source of truth is
  [git.fulgid.us](https://git.fulgid.us/fulgidus/jerkarchy).
- It runs on Linux, which Intel, Google, Red Hat, AMD and Meta co-develop. You
  can't escape everything. You can stop paying for flags.

## What's in the box

```
home/                 chezmoi source (dotfiles), applied to ~
  .config/sway        sway config: binds, rules, workspaces, monitors
  .config/waybar      bar config + style
  .config/fuzzel      launcher + bar-menu style
  .chezmoidata        themes (palettes) + default settings
  .local/bin          jerkarchy-settings, jerkarchy-set, notify-menu, wifi-menu, bt-menu, bar-battery, power-profile,
                      sway-ws, session-{lock,logout,menu}, screenshot, volume…
src/sway-binds        Zig: turns the sway config into the Super+H cheat sheet
src/jerkwall          Zig: the live wallpaper (layer-shell, GLES2, CPU fallback)
install.sh            the entire "installer"
```

Keybindings: press `Super+H`. They're generated from the config, so this
README can't go stale about them.

## License

[X11](LICENSE) (MIT plus one clause): keep the credit, and don't use the
author's name to promote your fork. Fork it, rename it, get it funded. We
dare you.
