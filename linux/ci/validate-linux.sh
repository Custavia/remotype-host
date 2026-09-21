#!/usr/bin/env bash
# Validate the Linux host's input path against a real kernel, real udev and real
# libinput — the layer X11 and every Wayland compositor sit on.
#
#   ./ci/validate-linux.sh            # boot if needed, run, leave the VM up
#   ./ci/validate-linux.sh --clean    # …then delete the VM and reclaim the disk
#
# Why a VM and not Docker: Docker Desktop's LinuxKit VM exposes /dev/uinput, so
# the loopback keymap test runs there, but it has no udev (the event node never
# appears on its own) and no libinput. This VM has both, so it can answer the
# question Docker cannot: does a compositor actually accept the device we create?
set -euo pipefail

VM=remotype-linux
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

if ! command -v limactl >/dev/null; then
  echo "limactl not found — brew install lima" >&2; exit 1
fi

if ! limactl list --format '{{.Name}}' 2>/dev/null | grep -qx "$VM"; then
  echo "==> creating VM $VM"
  limactl start --name="$VM" --tty=false "$HERE/remotype-linux.yaml"
elif [ "$(limactl list --format '{{.Status}}' "$VM" 2>/dev/null)" != "Running" ]; then
  echo "==> starting VM $VM"
  limactl start --tty=false "$VM"
fi

echo "==> building the loopback test for linux/arm64"
( cd "$ROOT" && GOOS=linux GOARCH=arm64 go test -c -o dist/keymap.test . )

echo "==> running in the VM, watched by libinput"
limactl shell "$VM" -- bash -lc '
set -euo pipefail
cp '"$ROOT"'/dist/keymap.test /tmp/keymap.test
chmod +x /tmp/keymap.test
sudo modprobe uinput 2>/dev/null || true
# NOTE: never pkill -f "libinput debug-events" here. This script is passed to
# bash as one argument, so its own command line contains that string and pkill
# would match — and kill — the shell running it. Use a pidfile.
sudo sh -c '"'"'nohup libinput debug-events --show-keycodes > /tmp/li.log 2>&1 & echo $! > /tmp/li.pid'"'"'
sleep 2
sudo /tmp/keymap.test -test.v 2>&1 | grep -E "^(=== RUN|--- (PASS|FAIL)|PASS|FAIL|ok)|verified" || true
sleep 1
sudo kill "$(cat /tmp/li.pid)" 2>/dev/null || true

echo
echo "==> did libinput accept the device?"
if sudo grep -q "Remotype Virtual Input" /tmp/li.log; then
  sudo grep -m1 "Remotype Virtual Input" /tmp/li.log
  caps=$(sudo grep -m1 "Remotype Virtual Input" /tmp/li.log | grep -o "cap:[a-z]*")
  # cap:k is keyboard, cap:p is pointer. We advertise both, so we need both — a
  # device that comes up keyboard-only would still pass the loopback test while
  # the trackpad silently did nothing under a real compositor.
  case "$caps" in
    *k*p*|*p*k*) echo "    OK: libinput sees keyboard AND pointer ($caps)" ;;
    *) echo "    FAIL: expected keyboard+pointer, got $caps" >&2; exit 1 ;;
  esac
else
  echo "    FAIL: libinput never saw the device" >&2; exit 1
fi

n=$(sudo grep -c KEYBOARD_KEY /tmp/li.log || echo 0)
echo "    libinput reported $n keyboard events"
[ "$n" -gt 100 ] || { echo "    FAIL: too few events reached libinput" >&2; exit 1; }
'

if [ "${1:-}" = "--clean" ]; then
  echo "==> deleting VM to reclaim disk"
  limactl stop "$VM" 2>/dev/null || true
  limactl delete "$VM"
fi
echo "==> done"
