#!/bin/bash
# Builds TrackPin and packs it into build/TrackPin-<version>.dmg with an Applications link,
# ready to drag and drop.
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd)"
"$project/build.sh"
app="$HOME/Library/Caches/TrackPin/DerivedData/Build/Products/Release/TrackPin.app"
mkdir -p "$project/build"
version="$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString)"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -R "$app" "$staging/TrackPin.app"
ln -s /Applications "$staging/Applications"
dmg="$project/build/TrackPin-$version.dmg"
rm -f "$dmg"
hdiutil create -quiet -volname "TrackPin $version" -srcfolder "$staging" -fs HFS+ -format UDZO "$dmg"
echo "Created $dmg"
