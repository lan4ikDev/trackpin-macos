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

# The team of the first Apple Development certificate in the keychain (its OU field).
team="${TRACKPIN_TEAM:-}"
if [[ -z "$team" ]]; then
    team="$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1 || true)"
fi
if [[ -n "$team" ]]; then
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
