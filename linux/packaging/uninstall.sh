#!/bin/sh
# Removes everything install.sh put in place. The per-user identity and
# pairings under ~/.config/remotype-host are the user's and are left alone —
# delete that directory to forget every phone.
set -eu
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo ./uninstall.sh" >&2; exit 1; }
rm -f /usr/bin/remotype-host /usr/lib/udev/rules.d/70-remotype-host.rules /etc/xdg/autostart/remotype-host.desktop
udevadm control --reload-rules 2>/dev/null || true
echo "Removed."
