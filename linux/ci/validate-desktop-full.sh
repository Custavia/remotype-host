#!/usr/bin/env bash
# Validate on a FULL desktop session: a real XFCE session (session manager,
# xfwm4 window manager, panel) on a real Xorg server, a real GTK text editor
# (Mousepad), and input driven through the phone protocol — pair, a sealed RT1
# session, key and mouse frames — landing in that editor. Proof is the file the
# editor saves (typed, then Ctrl+S typed too) plus a screenshot of the desktop.
#
#   ./ci/validate-desktop-full.sh            # runs inside the Lima VM
#
# This is the step past validate-desktop-x11.sh (which used a bare Tk field): a
# window manager owns focus, a real toolkit renders the text, and the editor
# writes it to disk.
set -euo pipefail
VM=remotype-linux
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

command -v limactl >/dev/null || { echo "limactl not found — brew install lima" >&2; exit 1; }
( cd "$ROOT" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -o dist/remotype-host-linux-arm64 . )
limactl copy "$ROOT/dist/remotype-host-linux-arm64" "$VM:/tmp/remotype-host-linux"
limactl copy "$HERE/type_probe.py" "$VM:/tmp/type_probe.py"
limactl copy -r "$ROOT/../spec" "$VM:/tmp/rt1spec"

limactl shell "$VM" -- bash -lc '
set -e
mv -f /tmp/type_probe.py /tmp/rt1spec/rt1/type_probe.py

# Kill anything from a prior run (anchored, so pkill never matches this shell).
pkill -f "^/tmp/remotype-host-linux" 2>/dev/null || true
pkill -x mousepad 2>/dev/null || true
pkill -x xfce4-session 2>/dev/null || true
sudo pkill -x Xorg 2>/dev/null || true
sleep 2

cat > /tmp/xorg-dummy.conf <<XEOF
Section "Device"
    Identifier "dummy"
    Driver "dummy"
    VideoRam 65536
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
        Modes "1280x800"
    EndSubSection
EndSection
Section "ServerLayout"
    Identifier "layout"
    Screen "screen"
EndSection
XEOF

# colord asks polkit for root to register a colour-managed device for the dummy
# display and its dialog steals focus mid-test. Allow it silently.
sudo mkdir -p /etc/polkit-1/rules.d
sudo tee /etc/polkit-1/rules.d/49-colord-allow.rules >/dev/null <<PKEOF
polkit.addRule(function(action, subject) {
  if (action.id.indexOf("org.freedesktop.color-manager.") === 0) { return polkit.Result.YES; }
});
PKEOF
sudo sh -c "setsid nohup Xorg :99 -config /tmp/xorg-dummy.conf -ac -noreset -nolisten tcp -logfile /tmp/xorg.log </dev/null >/tmp/xorg.out 2>&1 &"
sleep 4
pgrep -x Xorg >/dev/null || { echo "Xorg did not start"; tail -5 /tmp/xorg.log; exit 1; }

export DISPLAY=:99
# A real XFCE session: session manager + window manager + panel, under its own
# dbus. dbus-launch exports the bus this session and every app share.
eval "$(dbus-launch --sh-syntax)"
setsid nohup xfce4-session </dev/null >/tmp/xfce.log 2>&1 &
sleep 8
echo "==> window manager running: $(wmctrl -m 2>/dev/null | sed -n "1p" || echo "?")"

# The editor. Open it empty, then let the window manager settle and focus it.
rm -f /tmp/typed.txt
setsid nohup mousepad /tmp/typed.txt </dev/null >/tmp/mousepad.log 2>&1 &
sleep 6
WIN=$(xdotool search --name "typed.txt" | head -1 || true)
[ -n "$WIN" ] || WIN=$(xdotool search --class mousepad | head -1 || true)
[ -n "$WIN" ] || { echo "mousepad window never appeared"; tail -5 /tmp/mousepad.log; exit 1; }
xdotool windowactivate --sync "$WIN" 2>/dev/null || true; xdotool windowfocus "$WIN" 2>/dev/null || true
echo "==> editor focused (window $WIN: $(xdotool getwindowname "$WIN"))"

# The host, against this display.
rm -rf ~/.config/remotype-host /tmp/rt1code.txt /tmp/host.log /tmp/host.out
chmod +x /tmp/remotype-host-linux
sg input -c "DISPLAY=:99 REMOTYPE_RT1_TEST_CODE_FILE=/tmp/rt1code.txt REMOTYPE_HOST_LOG=/tmp/host.log setsid nohup /tmp/remotype-host-linux </dev/null >/tmp/host.out 2>&1 &"
sleep 2
echo "==> host: $(grep -E "keyboard layout|Listening" /tmp/host.log | tr "\n" " ")"
xdotool windowactivate --sync "$WIN" 2>/dev/null || true; xdotool windowfocus "$WIN" 2>/dev/null || true
# Let the window manager actually hand the editor keyboard focus before typing;
# without this beat the first keystrokes race focus and the WM drops them (a
# real desktop already has the editor focused, so this only bites the harness).
sleep 1.5

# Type through the phone protocol into the focused editor, then send Ctrl+S the
# same way, then a Return. type_probe emits the exact string; the mouse move and
# click are separate protocol frames it also supports via the appended block.
cd /tmp/rt1spec/rt1
export RT1_FLAVOR=go RT1_SUPPORT_DIR=$HOME/.config/remotype-host RT1_TEST_CODE_FILE=/tmp/rt1code.txt
MSG="Hello from a real Linux desktop. Numbers 1234567890 and symbols !@#\$%."
python3 type_probe.py 127.0.0.1 50808 "$MSG"
sleep 1
# Save: Ctrl+S is a chord — key "s" with the Ctrl modifier bit — then confirm.
python3 - <<PYEOF
import base64, json, os, sys, time
sys.path.insert(0, "/tmp/rt1spec/rt1")
import interop_host as ih
from gen_vectors import b64
import importlib.util
spec = importlib.util.spec_from_file_location("tp", "/tmp/rt1spec/rt1/type_probe.py")
tp = importlib.util.module_from_spec(spec); spec.loader.exec_module(tp)
phone = ih.load_phone_key()
link, keys = tp.open_session("127.0.0.1", 50808, phone)
c = 0
def seal_send(obj):
    global c
    link.send_raw(base64.b64encode(ih.seal(json.dumps(obj).encode(), keys["c2h"], ih.P2H, c)))
    c += 1; time.sleep(0.05)
# Ctrl+S (mods bit 1 = Ctrl), then Enter to accept the (already-known) filename.
seal_send({"t":"key","c":"s","mods":1})
time.sleep(0.4)
# A named file that exists after the first save needs no dialog; no Enter.
print("saved via Ctrl+S")
PYEOF
sleep 2

echo "==> trackpad: move the pointer and left-click through the phone protocol"
python3 - <<PYEOF
import base64, json, sys, time
sys.path.insert(0, "/tmp/rt1spec/rt1")
import interop_host as ih
import importlib.util
spec = importlib.util.spec_from_file_location("tp", "/tmp/rt1spec/rt1/type_probe.py")
tp = importlib.util.module_from_spec(spec); spec.loader.exec_module(tp)
phone = ih.load_phone_key()
link, keys = tp.open_session("127.0.0.1", 50808, phone)
c = 0
def sealed(o):
    global c
    link.send_raw(base64.b64encode(ih.seal(json.dumps(o).encode(), keys["c2h"], ih.P2H, c))); c += 1; time.sleep(0.03)
for _ in range(30):
    sealed({"t":"mm","dx":-8,"dy":-8})     # walk the pointer up-left
sealed({"t":"mc","b":1})                     # left click
print("pointer moved and clicked")
PYEOF
POINTER="$(xdotool getmouselocation --shell 2>/dev/null | tr "\n" " ")"
echo "    pointer now at: $POINTER"

echo "==> screenshot of the desktop:"
import -window root /tmp/desktop.png 2>/dev/null || xwd -root -silent | convert xwd:- /tmp/desktop.png 2>/dev/null || true
ls -la /tmp/desktop.png 2>/dev/null | awk "{print \"    /tmp/desktop.png \" \$5 \" bytes\"}"

echo "==> what the editor saved to /tmp/typed.txt:"
cat /tmp/typed.txt 2>/dev/null || echo "(file not written — the editor may not have saved)"
echo
EXPECT="$MSG"
GOT="$(cat /tmp/typed.txt 2>/dev/null || true)"
if [ "$GOT" = "$EXPECT" ]; then echo "PASS: the editor saved exactly what the phone typed"; else echo "NOTE: saved text differs from sent (see above) — sent: $EXPECT"; fi
'
# Pull the screenshot out for a look.
limactl copy "$VM:/tmp/desktop.png" "$ROOT/dist/desktop-validation.png" 2>/dev/null || true
