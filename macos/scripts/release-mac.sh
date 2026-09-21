#!/bin/bash
# Release pipeline for Remotype Host (macOS): build → sign (Developer ID) →
# notarize → staple → DMG. See docs/RELEASING.md for the one-time setup.
#
# Prerequisites:
#   1. An Apple Developer Program membership.
#   2. A "Developer ID Application" certificate in the login keychain.
#   3. Notary credentials stored once:
#        xcrun notarytool store-credentials remotype \
#          --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
#   4. REMOTYPE_DEVELOPMENT_TEAM=<team-id> in the environment. No team id is
#      committed to this repository.
#
# Usage: REMOTYPE_DEVELOPMENT_TEAM=XXXXXXXXXX ./scripts/release-mac.sh [marketing-version]
set -euo pipefail

cd "$(dirname "$0")/.."
: "${REMOTYPE_DEVELOPMENT_TEAM:?set REMOTYPE_DEVELOPMENT_TEAM to your Apple Team ID}"

# ANCHORED to the setting line, not the word: a looser grep once matched a
# comment above the setting and an unattended run built one version, named the
# DMG after another, and `rm -f`d a shipped artifact. Two guards follow.
VERSION="${1:-$(awk -F'"' '/^ *MARKETING_VERSION: *"/{print $2; exit}' project.yml)}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "ERROR: could not read a version (got '$VERSION')."
  echo "Pass one explicitly: ./scripts/release-mac.sh 1.2.0"
  exit 1
}
PROFILE="${NOTARY_PROFILE:-remotype}"
OUT="dist"
APP_NAME="Remotype Host"

command -v xcodegen >/dev/null || { echo "xcodegen missing (brew install xcodegen)"; exit 1; }
security find-identity -v -p codesigning | grep -q "Developer ID Application" || {
  echo "ERROR: no 'Developer ID Application' certificate in the keychain."
  echo "Create one via Xcode → Settings → Accounts → Manage Certificates. See docs/RELEASING.md."
  exit 1
}

# Never overwrite a release that already exists — bump MARKETING_VERSION instead.
if [ -f "dist/RemotypeHost-${VERSION}.dmg" ]; then
  echo "ERROR: dist/RemotypeHost-${VERSION}.dmg already exists."
  echo "Bump MARKETING_VERSION in project.yml (or pass a new version) before releasing."
  exit 1
fi

echo "==> Building Release ${VERSION}"
xcodegen generate
# CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO: plain `build` (vs archive) injects the
# debug get-task-allow entitlement, which notarization rejects.
# OTHER_CODE_SIGN_FLAGS=--timestamp: notarization requires a secure timestamp.
# -destination 'generic/platform=macOS' is load-bearing: without it xcodebuild
# builds for THIS Mac and quietly narrows ARCHS to a single architecture, so a
# universal-configured project still produces a thin binary.
xcodebuild -project RemotypeHost.xcodeproj -scheme RemotypeHost \
  -configuration Release -derivedDataPath build-release \
  -destination 'generic/platform=macOS' \
  DEVELOPMENT_TEAM="$REMOTYPE_DEVELOPMENT_TEAM" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO "OTHER_CODE_SIGN_FLAGS=--timestamp" \
  build | tail -2

APP="build-release/Build/Products/Release/RemotypeHost.app"
[ -d "$APP" ] || { echo "build product missing"; exit 1; }

# A thin binary here means Intel Macs get an app that cannot launch at all.
ARCHS_BUILT=$(lipo -archs "$APP/Contents/MacOS/RemotypeHost")
case "$ARCHS_BUILT" in
  *x86_64*arm64*|*arm64*x86_64*) echo "==> Universal: $ARCHS_BUILT" ;;
  *) echo "ERROR: not universal (got '$ARCHS_BUILT'). Intel Macs could not run this."
     echo "Check ARCHS/ONLY_ACTIVE_ARCH and that -destination 'generic/platform=macOS' is set."
     exit 1 ;;
esac

echo "==> Verifying signature + hardened runtime"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP" >/dev/null

mkdir -p "$OUT"
ZIP="$OUT/RemotypeHost-${VERSION}.zip"
DMG="$OUT/RemotypeHost-${VERSION}.dmg"

echo "==> Notarizing the app (this waits on Apple — typically 1–5 min)"
ditto -c -k --keepParent "$APP" "$ZIP"
SUBMIT_OUT=$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1 | tee /dev/stderr)
if ! echo "$SUBMIT_OUT" | grep -q "status: Accepted"; then
  SUB_ID=$(echo "$SUBMIT_OUT" | awk '/id:/{print $2; exit}')
  echo "NOTARIZATION NOT ACCEPTED — findings:"
  xcrun notarytool log "$SUB_ID" --keychain-profile "$PROFILE" || true
  exit 1
fi

echo "==> Stapling ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Building DMG"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/${APP_NAME}.app"

if command -v create-dmg >/dev/null && [ -f installer/dmg-background.tiff ]; then
  # create-dmg drives Finder over AppleScript to write the window's .DS_Store —
  # the only way to set a background, icon size and positions — so this step
  # needs a real GUI session. It also exits non-zero on a benign unmount race,
  # hence the `|| true` plus the explicit check that the file appeared.
  create-dmg \
    --volname "$APP_NAME" \
    --background installer/dmg-background.tiff \
    --window-pos 200 120 --window-size 620 420 \
    --icon-size 128 \
    --icon "${APP_NAME}.app" 160 210 \
    --app-drop-link 460 210 \
    --hide-extension "${APP_NAME}.app" \
    --no-internet-enable \
    "$DMG" "$STAGE" >/dev/null 2>&1 || true
  [ -f "$DMG" ] || echo "create-dmg produced nothing — falling back to a plain image"
fi

if [ ! -f "$DMG" ]; then
  # An unstyled DMG installs perfectly well; a missing background must never be
  # the reason a release cannot ship.
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
fi
rm -rf "$STAGE"

# Sign + notarize the DMG itself so the download is trusted end-to-end.
codesign --force --timestamp --sign "Developer ID Application" "$DMG"
DMG_OUT=$(xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait 2>&1 | tee /dev/stderr)
echo "$DMG_OUT" | grep -q "status: Accepted" || { echo "DMG notarization failed"; exit 1; }
xcrun stapler staple "$DMG"

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo
echo "DONE"
echo "  DMG → $DMG"
echo "  Publish the DMG and its .sha256, and add the checksum to CHECKSUMS.md."
echo "  The host has no auto-updater: users get new versions from the download page."
