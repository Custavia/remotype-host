#!/usr/bin/env bash
# Builds the Linux host release artifacts for amd64 and arm64:
#   dist/remotype-host-<ver>-linux-<arch>.tar.gz
#   dist/remotype-host_<ver>_<deb-arch>.deb        (when dpkg-deb is available)
# Runs from any OS with Go; the .deb needs dpkg-deb (Debian/Ubuntu, or
# `brew install dpkg`). No hosted CI is involved.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: build-packages.sh <version>}"
OUT="dist"
mkdir -p "$OUT"

for ARCH in amd64 arm64; do
  echo "==> $ARCH"
  STAGE="$(mktemp -d)"
  GOOS=linux GOARCH="$ARCH" CGO_ENABLED=0 go build -trimpath \
    -ldflags "-s -w -X main.appVersion=$VERSION" -o "$STAGE/remotype-host" .

  # --- tarball: binary + rule + autostart + install/uninstall + README
  T="$STAGE/remotype-host-$VERSION-linux-$ARCH"
  mkdir -p "$T"
  cp "$STAGE/remotype-host" packaging/70-remotype-host.rules packaging/remotype-host.desktop \
     packaging/install.sh packaging/uninstall.sh README.md "$T/"
  chmod 755 "$T/install.sh" "$T/uninstall.sh" "$T/remotype-host"
  tar -C "$STAGE" -czf "$OUT/remotype-host-$VERSION-linux-$ARCH.tar.gz" "$(basename "$T")"
  echo "    $OUT/remotype-host-$VERSION-linux-$ARCH.tar.gz"

  # --- deb
  if command -v dpkg-deb >/dev/null; then
    D="$STAGE/deb"
    mkdir -p "$D/DEBIAN" "$D/usr/bin" "$D/usr/lib/udev/rules.d" "$D/etc/xdg/autostart" "$D/usr/share/doc/remotype-host"
    install -m755 "$STAGE/remotype-host" "$D/usr/bin/remotype-host"
    install -m644 packaging/70-remotype-host.rules "$D/usr/lib/udev/rules.d/"
    install -m644 packaging/remotype-host.desktop "$D/etc/xdg/autostart/"
    install -m644 README.md "$D/usr/share/doc/remotype-host/README.md"
    cat > "$D/DEBIAN/control" <<CTRL
Package: remotype-host
Version: $VERSION
Section: utils
Priority: optional
Architecture: $ARCH
Maintainer: Custavia <support.remotype@custavia.com>
Recommends: libxkbcommon-tools, libnotify-bin
Homepage: https://remotype.custavia.com
Description: Remotype Host — use your phone as this computer's keyboard and trackpad
 The computer side of Remotype. Works only on your local network, pairs with a
 code shown on this computer, encrypts every session, and never connects to the
 internet. Injects input through uinput, so it works under X11 and Wayland.
CTRL
    cat > "$D/DEBIAN/postinst" <<'POST'
#!/bin/sh
set -e
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger --name-match=uinput 2>/dev/null || true
modprobe uinput 2>/dev/null || true
POST
    chmod 755 "$D/DEBIAN/postinst"
    # Deliberately no conffiles: a removed package must not leave an autostart
    # entry pointing at a binary that is gone.
    dpkg-deb --root-owner-group --build "$D" "$OUT/remotype-host_${VERSION}_${ARCH}.deb" >/dev/null
    echo "    $OUT/remotype-host_${VERSION}_${ARCH}.deb"
  else
    echo "    (dpkg-deb not found — .deb skipped; build it on a Debian/Ubuntu machine)"
  fi
  rm -rf "$STAGE"
done

echo "==> checksums"
( cd "$OUT" && shasum -a 256 remotype-host-"$VERSION"-linux-*.tar.gz remotype-host_"$VERSION"_*.deb 2>/dev/null | tee "remotype-host-$VERSION-SHA256SUMS" )
