#!/usr/bin/env bash
# Show what a given xkb layout makes of the scancodes we send.
#
# uinput is a SCANCODE protocol: we say "the key at position AC10 was pressed"
# and the desktop's layout decides what character that is. This proves the
# consequence rather than arguing about it.
#
#   ./ci/layout-probe.sh us es de fr
set -euo pipefail
VM=remotype-linux
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
LAYOUTS=("${@:-us es}")

( cd "$ROOT" && GOOS=linux GOARCH=arm64 go build -o dist/layoutprobe ./ci/probe 2>/dev/null ) || true

limactl shell "$VM" -- bash -lc '
cp '"$ROOT"'/dist/layoutprobe /tmp/lp && chmod +x /tmp/lp
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libxkbcommon-tools >/dev/null 2>&1 || true
for LAYOUT in '"${LAYOUTS[*]}"'; do
  echo "=== layout: $LAYOUT"
  # The probe must create the device BEFORE xkbcli starts: xkbcli enumerates
  # /dev/input once at startup and does not watch for hotplug.
  sudo sh -c "nohup /tmp/lp > /dev/null 2>&1 & echo \$! > /tmp/lp.pid"
  sleep 2
  sudo sh -c "nohup xkbcli interactive-evdev --layout $LAYOUT > /tmp/xkb.log 2>&1 & echo \$! > /tmp/xkb.pid"
  sleep 7
  sudo kill "$(cat /tmp/xkb.pid)" 2>/dev/null || true
  sudo kill "$(cat /tmp/lp.pid)" 2>/dev/null || true
  sudo grep -oE "keysyms \[ [^]]+\] unicode \[ [^]]*\]" /tmp/xkb.log | head -10
  echo
done'
