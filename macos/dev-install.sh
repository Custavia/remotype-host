#!/bin/bash
#
# dev-install.sh — build + install the Remotype Host locally with a STABLE
# signature, so macOS keeps your Accessibility / Screen Recording grants across
# updates instead of stranding them (toggle shows "on" but the host says "needed").
#
# Why this exists: macOS TCC stores each permission grant against the app's CODE
# SIGNATURE (its "designated requirement"), not just the bundle id. Install a build
# signed differently from the one you granted — an Xcode *Debug* build (Apple
# Development + get-task-allow) vs the *Developer ID* release — and the OS can't
# match the stored grant to the new binary, so it goes stale. This script always
# builds + signs with the SAME Developer ID identity, so the grant carries forward
# and you grant ONCE.
#
# Usage:
#   ./dev-install.sh            # build Release (Developer ID) + install + launch
#   ./dev-install.sh --reset    # also clear stale grants first (you'll re-grant once)
#
set -euo pipefail
cd "$(dirname "$0")"
# Your Apple Team ID — the Developer ID identity the Release config signs with.
: "${REMOTYPE_DEVELOPMENT_TEAM:?set REMOTYPE_DEVELOPMENT_TEAM to your Apple Team ID}"

APP_ID="com.custavia.remotype.host"
APP_NAME="Remotype Host.app"
DD="${TMPDIR:-/tmp}/RemotypeHost-devinstall"

RESET=false
[[ "${1:-}" == "--reset" ]] && RESET=true

echo "▸ Generating project + building Release (Developer ID signature)…"
command -v xcodegen >/dev/null && xcodegen generate >/dev/null
# generic/platform=macOS, not the default "this Mac" — otherwise xcodebuild
# narrows ARCHS to the host architecture and the local install is thin, which
# means the Intel slice never gets exercised until a user finds it broken.
xcodebuild -project RemotypeHost.xcodeproj -scheme RemotypeHost -configuration Release \
  -derivedDataPath "$DD" -destination 'generic/platform=macOS' \
  DEVELOPMENT_TEAM="$REMOTYPE_DEVELOPMENT_TEAM" build >/dev/null
APP="$DD/Build/Products/Release/RemotypeHost.app"
[[ -d "$APP" ]] || { echo "build produced no app at $APP" >&2; exit 1; }

echo "▸ Quitting the running host…"
osascript -e 'quit app "Remotype Host"' 2>/dev/null || true
sleep 1

if $RESET; then
  echo "▸ Clearing stale permission grants (you'll re-grant once)…"
  tccutil reset Accessibility "$APP_ID" >/dev/null 2>&1 || true
  tccutil reset ScreenCapture "$APP_ID" >/dev/null 2>&1 || true
fi

echo "▸ Installing to /Applications…"
rm -rf "/Applications/$APP_NAME"
cp -R "$APP" "/Applications/$APP_NAME"

echo "▸ Launching…"
open "/Applications/$APP_NAME"

VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
  "/Applications/$APP_NAME/Contents/Info.plist" 2>/dev/null || echo "?")
cat <<EOF

✓ Installed Remotype Host $VER (fixed port 50808, ephemeral fallback).
  Every install via this script uses the SAME Developer ID signature, so macOS
  should keep your Accessibility + Screen Recording grants across updates — you
  shouldn't have to re-grant. If a grant ever goes stale (toggle reads "on" but
  the host says "needed"), re-run with:  ./dev-install.sh --reset
EOF
