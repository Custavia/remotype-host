#!/bin/bash
# Build the Go/Pion cast helper and embed + sign it into the RemotypeHost app
# bundle. Invoked as a Run Script build phase (project.yml postCompileScripts),
# so it runs before Xcode's final code-sign, which then seals the nested helper.
#
# Statically links the vendored libopus → the shipped helper has no external
# dylib dependency. Built UNIVERSAL (arm64 + x86_64) so the app can be: a nested
# binary that is thinner than its host makes the whole bundle unusable on the
# missing arch, and this helper was the reason the app shipped arm64-only.
# Requires a universal libopus — see build-opus-universal.sh.
# If Go is absent the build still succeeds WITHOUT the helper: the host simply
# advertises direct:0 and Cast DIRECT is unavailable (graceful degrade).
set -euo pipefail

# Xcode's build PATH is minimal — locate Go in the usual spots.
for p in /usr/local/go/bin /opt/homebrew/bin /usr/local/bin "$HOME/go/bin"; do
  [ -x "$p/go" ] && export PATH="$p:$PATH"
done
if ! command -v go >/dev/null 2>&1; then
  echo "warning: go not found — Cast DIRECT helper NOT built (host will report direct:0)"
  exit 0
fi

SIDECAR="$SRCROOT/sidecar"
DEST="${CODESIGNING_FOLDER_PATH}/Contents/Helpers"
mkdir -p "$DEST"

# One cgo build per slice, then lipo. Go cannot emit a fat binary itself, and
# cgo cannot be cross-compiled without telling clang which arch to target — the
# -arch flags are what make the x86_64 pass work on an Apple Silicon machine.
# ARCHS comes from Xcode, so a Debug build (arm64 only) stays fast and a Release
# build (arm64 x86_64) gets both.
BUILD_ARCHS="${ARCHS:-arm64}"
echo "building remotype-cast-helper (CGO, static libopus) for: $BUILD_ARCHS"
SLICES=""
for A in $BUILD_ARCHS; do
  case "$A" in
    arm64)  GOA=arm64 ;;
    x86_64) GOA=amd64 ;;
    *) echo "warning: unknown arch '$A' — skipped"; continue ;;
  esac
  OUT="$DERIVED_FILE_DIR/cast-helper-$A"
  mkdir -p "$DERIVED_FILE_DIR"
  CGO_ENABLED=1 GOOS=darwin GOARCH="$GOA" \
    CGO_CFLAGS="-arch $A -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET:-13.0}" \
    CGO_LDFLAGS="-arch $A -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET:-13.0}" \
    go -C "$SIDECAR" build -trimpath -o "$OUT" .
  SLICES="$SLICES $OUT"
done
# shellcheck disable=SC2086
lipo -create $SLICES -output "$DEST/remotype-cast-helper"
echo "helper is $(lipo -archs "$DEST/remotype-cast-helper")"

# Inside-out signing: sign the nested helper now; the app's own signature (run by
# Xcode after this phase) records its hash and seals the bundle. (No bash arrays —
# macOS ships bash 3.2, where an empty "${arr[@]}" trips `set -u`.)
HELPER="$DEST/remotype-cast-helper"
# The nested helper must carry a signature of the SAME kind as the app, ad-hoc
# included: Xcode's final seal of the bundle refuses any unsigned subcomponent
# ("code object is not signed at all"), so skipping the ad-hoc case broke every
# Debug build that had no signing identity. A secure timestamp and the hardened
# runtime only apply to a real identity.
if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  if [ "${ENABLE_HARDENED_RUNTIME:-NO}" = "YES" ] && [ "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]; then
    codesign --force --options runtime --timestamp --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$HELPER"
  else
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$HELPER"
  fi
  echo "signed helper with ${EXPANDED_CODE_SIGN_IDENTITY}"
fi
