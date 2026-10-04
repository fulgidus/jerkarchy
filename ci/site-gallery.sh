#!/usr/bin/env bash
# ci/site-gallery.sh SHOTS OUT — turn ci/screenshots.sh output into a web
# gallery: OUT/gallery.html plus OUT/gallery/ (JPEG thumbnails of every theme,
# the screensaver GIFs). CI runs it after the screenshots and publishes OUT
# with the site. Needs ffmpeg, jq, chezmoi (theme titles and groups).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
shots=${1:?usage: ci/site-gallery.sh SHOTS OUT}
out=${2:?usage: ci/site-gallery.sh SHOTS OUT}
mkdir -p "$out/gallery"
data=$(chezmoi data --source "$ROOT" --format json)
version=$(cat "$ROOT/VERSION")

esc() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }

figure() {  # figure KEY: one theme's thumbnail + caption
    local key=$1 title
    [ -f "$shots/$key.png" ] || return 0
    ffmpeg -loglevel error -y -i "$shots/$key.png" -vf scale=960:-1 -q:v 4 "$out/gallery/$key.jpg"
    title=$(printf '%s' "$data" | jq -r --arg k "$key" '.themes[$k].title' | esc)
    printf '<figure><img src="gallery/%s.jpg" width="960" height="540" loading="lazy" alt="%s theme"><figcaption>%s · <code>jerkarchy-set theme %s</code></figcaption></figure>\n' \
        "$key" "$title" "$title" "$key"
}

section() {  # section ID HEADING NOTE JQ-FILTER-FOR-KEYS
    local id=$1 heading=$2 note=$3 filter=$4 keys
    keys=$(printf '%s' "$data" | jq -r ".themes | to_entries | map(select($filter)) | sort_by(.key) | .[].key")
    [ -n "$keys" ] || return 0
    printf '<section id="%s"><h2>%s</h2><p class="note">%s</p><div class="grid">\n' "$id" "$heading" "$note"
    for k in $keys; do figure "$k"; done
    printf '</div></section>\n'
}

savers=""
for mode in wallpaper matrix bonsai city galaxy planets threebody; do
    [ -f "$shots/saver-$mode.gif" ] || continue
    cp "$shots/saver-$mode.gif" "$out/gallery/"
    savers="$savers<figure><img src=\"gallery/saver-$mode.gif\" width=\"640\" height=\"360\" loading=\"lazy\" alt=\"$mode screensaver\"><figcaption>$mode · <code>jerkarchy-set saver_mode $mode</code></figcaption></figure>"
done

{
cat <<HEAD
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>jerkarchy gallery</title>
<style>
:root { --bg: #0a0a0f; --panel: #12121a; --line: #2a2a35; --fg: #c8c8d0; --dim: #8a8aa0; --cyan: #00f0ff;
  --mono: "JetBrains Mono", ui-monospace, Menlo, Consolas, monospace; color-scheme: dark; }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg); font: 15px/1.55 var(--mono); }
main { max-width: 1200px; margin: 0 auto; padding: 32px 16px 56px; display: grid; gap: 40px; }
h1 { margin: 0; color: var(--cyan); font-size: 1.8rem; } h2 { margin: 0 0 4px; color: var(--cyan); font-size: 1.1rem; }
a { color: var(--cyan); } .note, header p { color: var(--dim); margin: 4px 0 14px; max-width: 72ch; }
nav { display: flex; flex-wrap: wrap; gap: 6px 16px; margin-top: 10px; }
.grid { display: grid; gap: 18px; grid-template-columns: repeat(auto-fill, minmax(min(100%, 340px), 1fr)); }
figure { margin: 0; } img { width: 100%; height: auto; display: block; border: 1px solid var(--line); background: var(--panel); }
figcaption { color: var(--dim); font-size: .8rem; margin-top: 4px; overflow-wrap: anywhere; } code { color: var(--cyan); }
</style>
</head>
<body>
<main>
<header><h1>jerkarchy gallery</h1>
<p>v$version, rendered by CI in a headless sway on every release: each theme with the bar, the live wallpaper, a terminal and the settings menu, and every screensaver. <a href="./">← back</a></p>
<nav><a href="#savers">screensavers</a><a href="#classic">classic</a><a href="#flags">flags</a><a href="#mono">monochrome</a></nav></header>
HEAD
if [ -n "$savers" ]; then
    printf '<section id="savers"><h2>Screensavers</h2><p class="note">After 5 idle minutes, with a big title. Pick one in Settings › screensaver.</p><div class="grid">%s</div></section>\n' "$savers"
fi
section classic "Classic" "Palettes from each theme's own project (and one parody)." '(.value.group // "") == ""'
section flags "Flags" "Colours from each flag's SVG on Wikimedia Commons." '.value.group == "flags"'
section mono "Monochrome" "One hue per theme, dark and light." '.value.group == "mono"'
printf '</main>\n</body>\n</html>\n'
} >"$out/gallery.html"
echo "gallery: $(ls "$out/gallery" | wc -l) images → $out/gallery.html"
