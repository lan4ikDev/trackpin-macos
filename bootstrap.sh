#!/bin/bash
# Prepares the Xcode project: generates the loopback settings and TrackPin.xcodeproj.
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v xcodegen >/dev/null; then
    echo "XcodeGen is required: brew install xcodegen" >&2
    exit 1
fi
./scripts/configure.sh
xcodegen generate
echo "Open TrackPin.xcodeproj, pick your team under Signing & Capabilities for both targets, then Run."
