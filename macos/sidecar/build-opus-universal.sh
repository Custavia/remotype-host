#!/bin/bash
# Build a UNIVERSAL (arm64 + x86_64) static libopus and vendor it.
#
# Replaces the old `vendor-opus.sh`, which copied Homebrew's archive — and
# Homebrew on Apple Silicon ships arm64 only. That single archive is what made
# the whole app arm64-only, because the cast helper links it statically and
# nothing can be fatter than its thinnest input. Its own TODO said so:
# "for a universal RemotypeHost release, build/lipo an arm64+x86_64 libopus.a".
#
# Built from source rather than lipo'ing two Homebrew installs so both slices are
# provably the same version of the same code.
#
# Usage: ./sidecar/build-opus-universal.sh [opus-version]
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-1.5.2}"
SRC_URL="https://downloads.xiph.org/releases/opus/opus-${VERSION}.tar.gz"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Fetching opus ${VERSION}"
curl -fsSL "$SRC_URL" -o "$WORK/opus.tar.gz"
tar xzf "$WORK/opus.tar.gz" -C "$WORK"
SRC="$WORK/opus-${VERSION}"

# The two slices are configured and built independently — a static archive has no
# notion of architecture beyond what the compiler put in it, so this is the only
# way to get both.
for pair in "arm64:arm64-apple-darwin" "x86_64:x86_64-apple-darwin"; do
  ARCH="${pair%%:*}"
  HOST="${pair##*:}"
  echo "==> Building libopus for ${ARCH}"
  BUILD="$WORK/build-$ARCH"
  mkdir -p "$BUILD"
  ( cd "$BUILD"
    "$SRC/configure" \
      --host="$HOST" \
      --disable-shared --enable-static \
      --disable-doc --disable-extra-programs \
      CFLAGS="-arch $ARCH -mmacosx-version-min=13.0 -O2" \
      LDFLAGS="-arch $ARCH -mmacosx-version-min=13.0" \
      >/dev/null
    make -j"$(sysctl -n hw.ncpu)" >/dev/null )
  cp "$BUILD/.libs/libopus.a" "$WORK/libopus-$ARCH.a"
done

echo "==> Fusing the slices"
mkdir -p third_party/opus/include third_party/opus/lib
lipo -create "$WORK/libopus-arm64.a" "$WORK/libopus-x86_64.a" \
     -output third_party/opus/lib/libopus.a
cp "$SRC"/include/*.h third_party/opus/include/

echo "vendored universal libopus ${VERSION}:"
lipo -info third_party/opus/lib/libopus.a
