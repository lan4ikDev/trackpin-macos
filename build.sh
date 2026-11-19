#!/bin/bash
# Builds TrackPin.app from the command line.
#
#   TRACKPIN_TEAM=ABCDE12345 ./build.sh     # signed with your development certificate (recommended)
#   ./build.sh                              # ad hoc signature, the widget may not show up in the gallery
set -euo pipefail
project="$(cd "$(dirname "$0")" && pwd)"
output="${1:-$project/build}"
cd "$project"
./bootstrap.sh >/dev/null

signing=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
if [[ -n "${TRACKPIN_TEAM:-}" ]]; then
    signing=(DEVELOPMENT_TEAM="$TRACKPIN_TEAM" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates)
else
    echo "warning: TRACKPIN_TEAM is not set, signing ad hoc. macOS may hide the widget from the gallery." >&2
fi

xcodebuild -project TrackPin.xcodeproj -scheme TrackPin -configuration Release \
    -derivedDataPath "$output/DerivedData" "${signing[@]}" build | grep -E "error|warning: |BUILD" || true
app="$output/DerivedData/Build/Products/Release/TrackPin.app"
[[ -d "$app" ]] || { echo "Build failed" >&2; exit 1; }
rm -rf "$output/TrackPin.app"
cp -R "$app" "$output/TrackPin.app"
codesign --verify --deep --strict "$output/TrackPin.app"
"$output/TrackPin.app/Contents/MacOS/TrackPin" --self-test
echo "Built $output/TrackPin.app"
echo "Move it to /Applications and open it once, then add the widget from the desktop's \"Edit Widgets\" menu."
