#!/bin/bash
# Prepares the Xcode project: generates the loopback settings and TrackPin.xcodeproj.
# Uses XcodeGen from PATH, or downloads its release once into ~/Library/Caches/TrackPin.
set -euo pipefail
cd "$(dirname "$0")"
xcodegen="$(command -v xcodegen || true)"
if [[ -z "$xcodegen" ]]; then
    cache="$HOME/Library/Caches/TrackPin/xcodegen"
    xcodegen="$cache/xcodegen/bin/xcodegen"
    if [[ ! -x "$xcodegen" ]]; then
        echo "Downloading XcodeGen…" >&2
        mkdir -p "$cache"
        curl -fsSL -o "$cache/xcodegen.zip" https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip
        unzip -qo "$cache/xcodegen.zip" -d "$cache"
    fi
fi
./scripts/configure.sh
"$xcodegen" generate --quiet
