#!/bin/bash
# Makes a release in one command:
#
#   ./scripts/release.sh               # build, sign, notarize (if set up), publish on GitHub, update appcast.xml
#   ./scripts/release.sh --no-publish  # only build the DMG and update appcast.xml locally
#
# Before running:
#   1. Raise MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml, commit and push to main.
#   2. Write what changed into docs/releases/<version>.md (Markdown: paragraphs and "- " lists).
#      If the file is missing, the script drafts it from the commits since the last release and stops.
#
# Signing and notarization:
#   - The Sparkle EdDSA private key stays in the login keychain (account "trackpin"),
#     created once with Sparkle's generate_keys.
#   - With TRACKPIN_DEVELOPER_ID=1 the app is signed with a "Developer ID Application" certificate
#     (needs a paid Apple Developer account) and the DMG is notarized and stapled. Store the
#     notarization credentials once:
#       xcrun notarytool store-credentials trackpin --apple-id <id> --team-id <team> --password <app-specific password>
#     and set TRACKPIN_NOTARY_PROFILE if you named the profile differently.
#
# GitHub releases use the bare version as the tag (3.4.2), like the earlier releases.
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project"

publish=true
[[ "${1:-}" == "--no-publish" ]] && publish=false
repo="lan4ikDev/trackpin-macos"
notary_profile="${TRACKPIN_NOTARY_PROFILE:-trackpin}"

fail() { echo "error: $*" >&2; exit 1; }

# MARK: Checks before building anything

setting() { sed -n "s/^ *$1: *\"\{0,1\}\([^\"]*\)\"\{0,1\} *$/\1/p" project.yml | head -1; }
version="$(setting MARKETING_VERSION)"
build="$(setting CURRENT_PROJECT_VERSION)"
[[ -n "$version" && "$build" =~ ^[0-9]+$ ]] || fail "could not read the version from project.yml"
tag="$version"

# Sparkle compares the build number: it must grow with every release.
if [[ -f appcast.xml ]]; then
    latest_build="$(sed -n 's:.*<sparkle\:version>\([0-9]*\)</sparkle\:version>.*:\1:p' appcast.xml | sort -n | tail -1)"
    if [[ -n "$latest_build" ]] && (( build <= latest_build )); then
        same="$(grep -c "<sparkle:shortVersionString>$version</sparkle:shortVersionString>" appcast.xml || true)"
        if (( build < latest_build )) || [[ "$same" == 0 ]]; then
            fail "build $build is not above the last released build $latest_build: raise CURRENT_PROJECT_VERSION in project.yml"
        fi
        echo "note: build $build is already in appcast.xml, its entry will be replaced" >&2
    fi
    previous="$(sed -n 's:.*<sparkle\:shortVersionString>\(.*\)</sparkle\:shortVersionString>.*:\1:p' appcast.xml | head -1)"
fi

notes_file="docs/releases/$version.md"
if [[ ! -s "$notes_file" ]]; then
    mkdir -p docs/releases
    range="HEAD~20..HEAD"
    if [[ -n "${previous:-}" && "$previous" != "$version" ]] && git rev-parse -q --verify "refs/tags/$previous" >/dev/null; then
        range="$previous..HEAD"
    fi
    git log --no-merges --format='- %s' "$range" > "$notes_file"
    fail "wrote a draft of the release notes to $notes_file from the commits $range. Edit it, commit, and run again."
fi

if $publish; then
    command -v gh >/dev/null || fail "GitHub CLI (gh) is needed to publish: brew install gh, then gh auth login"
    [[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || fail "release from main"
    [[ -z "$(git status --porcelain)" ]] || fail "commit or stash your changes first"
    git fetch -q origin main
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "push main first: the release tag points at the pushed commit"
    if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
        fail "release $tag already exists on GitHub: raise the version in project.yml"
    fi
fi

# MARK: Build, notarize, sign for Sparkle

"$project/scripts/make-dmg.sh"
app="$HOME/Library/Caches/TrackPin/DerivedData/Build/Products/Release/TrackPin.app"
built_version="$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString)"
built_build="$(defaults read "$app/Contents/Info.plist" CFBundleVersion)"
[[ "$built_version" == "$version" && "$built_build" == "$build" ]] \
    || fail "the built app is $built_version ($built_build), project.yml says $version ($build)"
dmg="$project/build/TrackPin-$version.dmg"

if [[ -n "${TRACKPIN_DEVELOPER_ID:-}" ]]; then
    echo "Notarizing $dmg (profile $notary_profile)…"
    xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$dmg"
    spctl --assess --type open --context context:primary-signature -v "$dmg"
else
    echo "note: not notarized (set TRACKPIN_DEVELOPER_ID=1 with a Developer ID certificate to notarize)" >&2
fi

# Sign after stapling: stapling changes the DMG's bytes.
sign_update="$(find "$HOME/Library/Caches/TrackPin/DerivedData/SourcePackages/artifacts" -path "*Sparkle/bin/sign_update" | head -1)"
[[ -x "$sign_update" ]] || fail "Sparkle's sign_update was not found; build once first."
# Prints: sparkle:edSignature="…" length="…"
attributes="$("$sign_update" --account trackpin "$dmg")"

python3 - "$version" "$build" "$attributes" "$tag" "$notes_file" "$repo" <<'PY'
import sys, email.utils, html, pathlib, re
version, build, attributes, tag, notes_file, repo = sys.argv[1:7]

def to_html(markdown):
    """Paragraphs and "- " lists, enough for Sparkle's update window."""
    out, items, para = [], [], []
    def inline(text):
        text = html.escape(text)
        text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
        return re.sub(r"`(.+?)`", r"<code>\1</code>", text)
    def flush():
        if para: out.append("<p>" + inline(" ".join(para)) + "</p>"); para.clear()
        if items: out.append("<ul>" + "".join(f"<li>{inline(i)}</li>" for i in items) + "</ul>"); items.clear()
    for line in markdown.splitlines():
        line = line.strip()
        if line.startswith(("- ", "* ")):
            if para: flush()
            items.append(line[2:])
        elif line.startswith("#"):
            flush(); out.append("<h3>" + inline(line.lstrip("# ")) + "</h3>")
        elif not line:
            flush()
        else:
            if items: flush()
            para.append(line)
    flush()
    return "\n".join(out)

notes = to_html(pathlib.Path(notes_file).read_text()).replace("]]>", "]]&gt;")
path = pathlib.Path("appcast.xml")
base = f"https://github.com/{repo}/releases"
item = f"""    <item>
      <title>TrackPin {version}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <link>{base}/tag/{tag}</link>
      <description><![CDATA[
{notes}
      ]]></description>
      <enclosure url="{base}/download/{tag}/TrackPin-{version}.dmg" type="application/octet-stream" {attributes} />
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
    <link>https://raw.githubusercontent.com/{repo}/main/appcast.xml</link>
{item}  </channel>
</rss>
"""
path.write_text(text)
PY
echo "Release $version ($build): $dmg"

if ! $publish; then
    echo "Not published. To publish by hand: create the GitHub release $tag with $dmg, then commit and push appcast.xml."
    exit 0
fi

# MARK: Publish
# The DMG goes up first and appcast.xml after it, so Sparkle never offers a file that is not there yet.

gh release create "$tag" "$dmg" --repo "$repo" --target "$(git rev-parse HEAD)" \
    --title "TrackPin $version" --notes-file "$notes_file"
url="https://github.com/$repo/releases/download/$tag/TrackPin-$version.dmg"
for attempt in 1 2 3 4 5; do
    status="$(curl -sIL -o /dev/null -w '%{http_code}' "$url" || true)"
    [[ "$status" == 200 ]] && break
    sleep 3
done
[[ "$status" == 200 ]] || fail "the DMG is not downloadable yet ($url answers $status); appcast.xml is not pushed"

git add appcast.xml
git commit -q -m "Release $version ($build)"
git push -q origin main
echo "Published TrackPin $version: https://github.com/$repo/releases/tag/$tag"
