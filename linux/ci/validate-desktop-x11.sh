#!/usr/bin/env bash
# Prove the last inch on a real X server: phone protocol → RT1 → uinput →
# kernel → udev → Xorg's libinput driver → the Spanish xkb layout → a toolkit
# text field. Xvfb cannot do this — it has no input hotplug and never reads
# evdev — so this uses Xorg with the GPU-less "dummy" video driver, which
# takes input exactly like a desktop's X server does.
#
#   ./ci/validate-desktop-x11.sh            # runs inside the Lima VM (ci/remotype-linux.yaml)
#
# The layout is set for EVERY keyboard through an InputClass, the way
# /etc/default/keyboard does on a real system: setxkbmap alone only touches
# the core keyboard, and a device that appears later — ours — would inherit
# the server default and type as US. That was the first thing this script
# caught.
set -euo pipefail
VM=remotype-linux
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
LAYOUT="${LAYOUT:-es}"
TEXT="${TEXT:-hola ñ;@é Ü}"

command -v limactl >/dev/null || { echo "limactl not found — brew install lima" >&2; exit 1; }
( cd "$ROOT" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -o dist/remotype-host-linux-arm64 . )
limactl copy "$ROOT/dist/remotype-host-linux-arm64" "$VM:/tmp/remotype-host-linux"
limactl copy "$HERE/xkey_receiver.py" "$VM:/tmp/xkey_receiver.py"
limactl copy "$HERE/type_probe.py" "$VM:/tmp/type_probe.py"
limactl copy -r "$ROOT/../spec" "$VM:/tmp/rt1spec"

limactl shell "$VM" -- bash -lc '
set -e
LAYOUT="'"$LAYOUT"'"; TEXT="'"$TEXT"'"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xserver-xorg-core xserver-xorg-video-dummy xserver-xorg-input-libinput python3-tk libxkbcommon-tools python3-cryptography >/dev/null 2>&1
mv -f /tmp/type_probe.py /tmp/rt1spec/rt1/type_probe.py
cat > /tmp/xorg-dummy.conf <<XEOF
Section "Device"
    Identifier "dummy"
    Driver "dummy"
    VideoRam 32768
EndSection
Section "Monitor"
    Identifier "monitor"
    HorizSync 5.0-1000.0
    VertRefresh 5.0-200.0
EndSection
Section "Screen"
    Identifier "screen"
    Device "dummy"
    Monitor "monitor"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "1024x768"
    EndSubSection
EndSection
Section "ServerLayout"
    Identifier "layout"
    Screen "screen"
EndSection
Section "InputClass"
    Identifier "layout for every keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "$LAYOUT"
EndSection
XEOF
# Never pkill -f a pattern that appears in THIS command line: it kills this shell.
pkill -f "^python3 /tmp/xkey_receiver" 2>/dev/null || true
pkill -f "^/tmp/remotype-host-linux" 2>/dev/null || true
sudo pkill -x Xorg 2>/dev/null || true
sleep 2
sudo sh -c "setsid nohup Xorg :99 -config /tmp/xorg-dummy.conf -ac -noreset -nolisten tcp -logfile /tmp/xorg.log </dev/null >/tmp/xorg.out 2>&1 &"
sleep 4
pgrep -x Xorg >/dev/null || { echo "Xorg did not start:"; tail -5 /tmp/xorg.log; exit 1; }
rm -f /tmp/keys.log /tmp/host.log /tmp/host.out /tmp/rt1code.txt
DISPLAY=:99 LANG=en_US.UTF-8 setsid nohup python3 /tmp/xkey_receiver.py /tmp/keys.log </dev/null >/tmp/rx.log 2>&1 &
sleep 3
chmod +x /tmp/remotype-host-linux
sg input -c "DISPLAY=:99 REMOTYPE_RT1_TEST_CODE_FILE=/tmp/rt1code.txt REMOTYPE_HOST_LOG=/tmp/host.log setsid nohup /tmp/remotype-host-linux </dev/null >/tmp/host.out 2>&1 &"
sleep 3
echo "==> host: $(grep -E "keyboard layout" /tmp/host.log)"
echo "==> Xorg: $(grep -c "Remotype Virtual Input: Applying InputClass" /tmp/xorg.log) InputClass applications to our device"
cd /tmp/rt1spec/rt1
export RT1_FLAVOR=go RT1_SUPPORT_DIR=$HOME/.config/remotype-host RT1_TEST_CODE_FILE=/tmp/rt1code.txt
python3 type_probe.py 127.0.0.1 50808 "$TEXT"
sleep 1
GOT="$(cut -f2 /tmp/keys.log | tr -d "\n")"
echo "==> sent:     $TEXT"
echo "==> received: $GOT"
[ "$GOT" = "$TEXT" ] && echo "PASS: the text field received exactly what the phone typed" || { echo "FAIL"; sed "s/\t/ | /" /tmp/keys.log; exit 1; }
'
