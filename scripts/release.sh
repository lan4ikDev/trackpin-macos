#!/bin/bash
# Makes a release: builds the DMG, signs it for Sparkle and adds it to appcast.xml.
#
#   ./scripts/release.sh
#
# Then commit appcast.xml, create the GitHub release v<version> and attach
# build/TrackPin-<version>.dmg. The EdDSA private key stays in the login keychain
# (account "trackpin"), created once with Sparkle's generate_keys.
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project"
"$project/scripts/make-dmg.sh"

app="$project/build/TrackPin.app"
version="$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString)"
build="$(defaults read "$app/Contents/Info.plist" CFBundleVersion)"
dmg="$project/build/TrackPin-$version.dmg"
sign_update="$(find "$HOME/Library/Caches/TrackPin/DerivedData/SourcePackages/artifacts" -path "*Sparkle/bin/sign_update" | head -1)"
[[ -x "$sign_update" ]] || { echo "Sparkle's sign_update was not found; build once first." >&2; exit 1; }
# Prints: sparkle:edSignature="…" length="…"
attributes="$("$sign_update" --account trackpin "$dmg")"

python3 - "$version" "$build" "$attributes" <<'PY'
import sys, email.utils, pathlib, re
version, build, attributes = sys.argv[1:4]
path = pathlib.Path("appcast.xml")
url = f"https://github.com/lan4ikDev/trackpin-macos/releases/download/v{version}/TrackPin-{version}.dmg"
item = f"""    <item>
      <title>TrackPin {version}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <link>https://github.com/lan4ikDev/trackpin-macos/releases/tag/v{version}</link>
      <enclosure url="{url}" type="application/octet-stream" {attributes} />
    </item>
"""
if path.exists():
    text = path.read_text()
    # Replace an item of the same build, otherwise put the new one first.
    text = re.sub(r"    <item>\n(?:(?!</item>).)*?<sparkle:version>%s</sparkle:version>.*?</item>\n" % re.escape(build), "", text, flags=re.S)
    text = text.replace("    <item>", item + "    <item>", 1) if "<item>" in text else text.replace("  </channel>", item + "  </channel>")
else:
    text = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>TrackPin</title>
    <link>https://raw.githubusercontent.com/lan4ikDev/trackpin-macos/main/appcast.xml</link>
{item}  </channel>
</rss>
"""
path.write_text(text)
PY
echo "Release $version ($build): $dmg"
echo "Next: commit appcast.xml, push, and attach the DMG to the GitHub release v$version."
