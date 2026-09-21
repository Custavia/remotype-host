#!/bin/sh
# Installs the Remotype Host from the unpacked tarball. Needs root for the
# three system paths; the host itself never runs as root.
set -eu
cd "$(dirname "$0")"
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo ./install.sh" >&2; exit 1; }
install -Dm755 remotype-host /usr/bin/remotype-host
install -Dm644 70-remotype-host.rules /usr/lib/udev/rules.d/70-remotype-host.rules
install -Dm644 remotype-host.desktop /etc/xdg/autostart/remotype-host.desktop
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger --name-match=uinput 2>/dev/null || true
modprobe uinput 2>/dev/null || true
echo "Installed. It starts with your next desktop login; to start it now: remotype-host"
echo "For non-US keyboard layouts install libxkbcommon-tools; for the pairing code as a notification, libnotify-bin."
