#!/bin/bash
set -euo pipefail

project="$(cd "$(dirname "$0")" && pwd)"
output="${1:-$project/build}"
app="$output/TrackPin.app"
extension="$app/Contents/PlugIns/TrackPinWidget.appex"
generated="$output/.generated"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$extension/Contents/MacOS" "$generated"
cp "$project/Info.plist" "$app/Contents/Info.plist"
cp "$project/Assets/TrackPin.icns" "$app/Contents/Resources/TrackPin.icns"
cp "$project/NativeWidget/Info.plist" "$extension/Contents/Info.plist"

if [[ ! -s "$generated/TrackPinBuild.swift" ]]; then
    port="$(( 49152 + RANDOM % 16384 ))"
    token="$(/usr/bin/uuidgen)"
    cat > "$generated/TrackPinBuild.swift" <<GEN
enum TrackPinBuild {
    static let port: UInt16 = $port
    static let token = "$token"
}
GEN
fi

options=(-swift-version 5 -target "$(uname -m)-apple-macosx14.0"
    -module-cache-path "$output/.module-cache" -O)
xcrun swiftc "${options[@]}" -module-name TrackPin -o "$app/Contents/MacOS/TrackPin" \
    "$project"/Sources/*.swift "$project"/Shared/*.swift "$generated/TrackPinBuild.swift"
xcrun swiftc "${options[@]}" -application-extension -module-name TrackPinWidget \
    -o "$extension/Contents/MacOS/TrackPinWidget" \
    "$project"/NativeWidget/*.swift "$project"/Shared/*.swift "$generated/TrackPinBuild.swift"
codesign --force --sign - --entitlements "$project/NativeWidget/Entitlements.plist" "$extension"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
"$app/Contents/MacOS/TrackPin" --self-test
