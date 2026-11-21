#!/bin/bash
# Builds TrackPin.app from the command line.
#
#   ./build.sh                       # signs with your Apple Development certificate, if there is one
#   TRACKPIN_TEAM=ABCDE12345 ./build.sh
#   ./build.sh --install             # also replaces /Applications/TrackPin.app and restarts it
#
# The build happens in ~/Library/Caches/TrackPin: inside an iCloud synced Documents folder
# codesign can fail on half-synced temporary files.
set -euo pipefail
project="$(cd "$(dirname "$0")" && pwd)"
install=false
[[ "${1:-}" == "--install" ]] && install=true
cd "$project"
./bootstrap.sh >/dev/null

# TRACKPIN_DEVELOPER_ID=1 signs for distribution with a "Developer ID Application" certificate
# (paid Apple Developer account), as notarization requires. Otherwise the first Apple Development
# certificate is used.
certificate="Apple Development"
[[ -n "${TRACKPIN_DEVELOPER_ID:-}" ]] && certificate="Developer ID Application"
# The team of the first matching certificate in the keychain (its OU field).
team="${TRACKPIN_TEAM:-}"
if [[ -z "$team" ]]; then
    team="$(security find-certificate -a -c "$certificate" -p 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1 || true)"
fi
if [[ -n "${TRACKPIN_DEVELOPER_ID:-}" ]]; then
    [[ -n "$team" ]] || { echo "No Developer ID Application certificate in the keychain." >&2; exit 1; }
    identity="Developer ID Application"
    signing=(DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity"
             "OTHER_CODE_SIGN_FLAGS=--timestamp")
elif [[ -n "$team" ]]; then
    signing=(DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates)
else
    echo "warning: no Apple Development certificate, signing ad hoc. macOS may hide the widget from the gallery." >&2
    signing=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
fi

derived="$HOME/Library/Caches/TrackPin/DerivedData"
log="$HOME/Library/Caches/TrackPin/build.log"
if ! xcodebuild -project TrackPin.xcodeproj -scheme TrackPin -configuration Release \
        -derivedDataPath "$derived" "${signing[@]}" build >"$log" 2>&1; then
    grep -E "error:" "$log" | sort -u >&2 || true
    echo "Build failed, see $log" >&2
    exit 1
fi
app="$derived/Build/Products/Release/TrackPin.app"
if [[ -n "${TRACKPIN_DEVELOPER_ID:-}" ]]; then
    # Xcode signs Sparkle.framework but not the helpers inside it, and notarization rejects those.
    # Re-sign them inside out (as Sparkle's documentation describes), then the app around them.
    sign=(codesign -f -s "$identity" -o runtime --timestamp)
    sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
    for helper in "$sparkle/XPCServices/Installer.xpc" "$sparkle/XPCServices/Downloader.xpc" \
                  "$sparkle/Autoupdate" "$sparkle/Updater.app"; do
        if [[ -e "$helper" ]]; then "${sign[@]}" --preserve-metadata=entitlements "$helper"; fi
    done
    "${sign[@]}" "$app/Contents/Frameworks/Sparkle.framework"
    "${sign[@]}" --preserve-metadata=entitlements "$app/Contents/PlugIns/TrackPinWidget.appex"
    "${sign[@]}" --entitlements "$project/TrackPin.entitlements" "$app"
fi
codesign --verify --deep --strict "$app"
"$app/Contents/MacOS/TrackPin" --self-test
# No copy in the project folder: every extra TrackPin.app that Spotlight finds can show up as a
# second TrackPin in the widget gallery.
echo "Built $app"

if $install; then
    osascript -e 'quit app "TrackPin"' >/dev/null 2>&1 || true
    pkill -x TrackPin || true
    pkill -x TrackPinWidget || true
    sleep 1
    rm -rf /Applications/TrackPin.app
    cp -R "$app" /Applications/TrackPin.app
    open /Applications/TrackPin.app
    # Make the widget host load the new extension instead of a running old one.
    sleep 2
    killall chronod >/dev/null 2>&1 || true
    echo "Installed and started /Applications/TrackPin.app"
fi
