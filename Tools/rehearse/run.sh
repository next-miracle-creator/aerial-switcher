#!/bin/zsh
# Rehearse the fork against /tmp/asw-fakehome: seed a throwaway home, build, run.
# Nothing here writes to ~/Library — the real wallpaper store and manifest are only read,
# once, to seed the fake home.
set -euo pipefail

real="$HOME/Library/Application Support/com.apple.wallpaper"
seed=/tmp/asw-seed
here=$(cd "$(dirname "$0")" && pwd)
core="$here/../../Sources/AerialCore"
fake=/tmp/asw-fakehome
wallpaper="$fake/Library/Application Support/com.apple.wallpaper"

mkdir -p "$seed"
[ -f "$seed/entries.json" ] || cp "$real/aerials/manifest/entries.json" "$seed/entries.json"
[ -f "$seed/Index.plist" ] || cp "$real/Store/Index.plist" "$seed/Index.plist"
[ -f /tmp/asw-fakehome-pristine.plist ] || cp "$seed/Index.plist" /tmp/asw-fakehome-pristine.plist

rm -rf "$fake"
mkdir -p "$wallpaper/Store" "$wallpaper/aerials/manifest" "$wallpaper/aerials/videos" \
         "$fake/Library/Application Support/AerialSwitcher"
cp /tmp/asw-fakehome-pristine.plist "$wallpaper/Store/Index.plist"
cp "$seed/entries.json" "$wallpaper/aerials/manifest/entries.json"
ln -sfn "$real/aerials/manifest/TVIdleScreenStrings.bundle" \
        "$wallpaper/aerials/manifest/TVIdleScreenStrings.bundle"
for id in 4C108785-A7BA-422E-9C79-B0129F1D5550 52ACB9B8-75FC-4516-BC60-4550CFF3B661; do
  printf 'x' > "$wallpaper/aerials/videos/$id.mov"
done
cat > "$fake/Library/Application Support/AerialSwitcher/config.json" <<'JSON'
{
  "autoDownload": false,
  "enabled": true,
  "paused": false,
  "schedules": {
    "0DC99DD8-3386-4D1E-8878-C43E97EB710A": { "day": "17:58", "evening": "17:59" }
  },
  "setID": "0DC99DD8-3386-4D1E-8878-C43E97EB710A"
}
JSON

cd "$here"
out=$(swiftc -swift-version 5 -o rehearse main.swift "$core"/*.swift 2>&1) || { print -r -- "$out"; exit 1; }
print -r -- "$out" | grep -E "error" && exit 1
./rehearse
