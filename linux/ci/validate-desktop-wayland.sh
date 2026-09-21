#!/usr/bin/env bash
# Validate on a REAL Wayland session: sway (a wlroots compositor) on a virtual
# KMS display, taking input through libinput the way any Wayland desktop does —
# no X server anywhere. Input is driven through the phone protocol (pair, a
# sealed RT1 session, key frames) into a Wayland terminal; the shell there runs
# the typed command and writes a file, which is the machine-checkable proof that
# the keystrokes reached a real Wayland client correctly. A grim screenshot is
# saved alongside.
#
#   ./ci/validate-desktop-wayland.sh          # runs inside the Lima VM
#
# Why this shape:
#   - The wlroots HEADLESS backend gives outputs but NO input (no libinput), so
#     a headless sway sees nothing our host injects. The DRM backend does create
#     a libinput session — so we give it a GPU-less display with the `vkms`
#     virtual-KMS kernel module and let sway use DRM on it.
#   - A Wayland compositor needs a seat to open /dev/input; `seatd` provides one,
#     with its socket owned by the `input` group the host user is already in.
set -euo pipefail
VM=remotype-linux
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

command -v limactl >/dev/null || { echo "limactl not found — brew install lima" >&2; exit 1; }
( cd "$ROOT" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -o dist/remotype-host-linux-arm64 . )
limactl copy "$ROOT/dist/remotype-host-linux-arm64" "$VM:/tmp/remotype-host-linux"
limactl copy "$HERE/type_probe.py" "$VM:/tmp/type_probe.py"
limactl copy -r "$ROOT/../spec" "$VM:/tmp/rt1spec"

limactl shell "$VM" -- bash -c '
set -e
mv -f /tmp/type_probe.py /tmp/rt1spec/rt1/type_probe.py
# One-time host setup (idempotent): the extra kernel modules carry vkms; seatd
# hands out a seat to the input group.
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sway seatd foot grim linux-modules-extra-$(uname -r) >/dev/null 2>&1 || true
sudo modprobe vkms 2>/dev/null || true
[ -e /dev/dri/card0 ] || { echo "vkms did not create /dev/dri/card0 — this kernel has no virtual KMS"; exit 1; }
sudo usermod -aG video,render pc 2>/dev/null || true
pgrep -x seatd >/dev/null || { sudo systemctl stop seatd 2>/dev/null || true; sudo rm -f /run/seatd.sock; sudo setsid seatd -g input </dev/null >/tmp/seatd.log 2>&1 & sleep 2; }

export XDG_RUNTIME_DIR=/run/user/$(id -u)
sudo mkdir -p "$XDG_RUNTIME_DIR"; sudo chown $(id -u):$(id -g) "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"

# Anchored kills only (a loose pattern would match this shell).
pkill -f "^/tmp/remotype-host-linux" 2>/dev/null || true
pkill -x sway 2>/dev/null || true
sleep 1

# Host first, so its uinput device exists before sway enumerates input.
rm -rf ~/.config/remotype-host /tmp/rt1code.txt /tmp/host.log /tmp/wl.txt /tmp/wl.png
chmod +x /tmp/remotype-host-linux
sg input -c "REMOTYPE_RT1_TEST_CODE_FILE=/tmp/rt1code.txt REMOTYPE_HOST_LOG=/tmp/host.log setsid nohup /tmp/remotype-host-linux </dev/null >/tmp/host.out 2>&1 &"
sleep 2

cat > /tmp/sway.cfg <<CFG
output "*" resolution 1280x800
input type:keyboard { xkb_layout us }
exec foot
CFG
unset WLR_BACKENDS
sg input -c "env XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR LIBSEAT_BACKEND=seatd WLR_DRM_DEVICES=/dev/dri/card0 setsid nohup sway -c /tmp/sway.cfg </dev/null >/tmp/sway.log 2>&1 &"
sleep 6
export SWAYSOCK=$(ls /run/user/$(id -u)/sway-ipc.* 2>/dev/null | head -1)
export WAYLAND_DISPLAY=$(basename $(ls /run/user/$(id -u)/wayland-[0-9]* 2>/dev/null | grep -v lock | head -1))
pgrep -x sway >/dev/null || { echo "sway did not start"; tail -8 /tmp/sway.log; exit 1; }

echo "==> sway sees our device as real Wayland input:"
swaymsg -t get_inputs | grep -E "Remotype Virtual Input|\"type\": \"(keyboard|pointer)\"" | sed "s/^ *//" | head -4
swaymsg "[app_id=foot] focus" >/dev/null 2>&1
sleep 1

cd /tmp/rt1spec/rt1
export RT1_FLAVOR=go RT1_SUPPORT_DIR=$HOME/.config/remotype-host RT1_TEST_CODE_FILE=/tmp/rt1code.txt
MARK="RT1-WAYLAND-OK-2468"
python3 - "$MARK" <<PYEOF
import base64, json, sys, time, importlib.util
sys.path.insert(0, "/tmp/rt1spec/rt1")
import interop_host as ih
spec = importlib.util.spec_from_file_location("tp", "/tmp/rt1spec/rt1/type_probe.py")
tp = importlib.util.module_from_spec(spec); spec.loader.exec_module(tp)
link, keys = tp.open_session("127.0.0.1", 50808, ih.load_phone_key())
c = 0
def send(o):
    global c
    link.send_raw(base64.b64encode(ih.seal(json.dumps(o).encode(), keys["c2h"], ih.P2H, c))); c += 1; time.sleep(0.04)
send({"t":"key","c":"u","mods":1})   # Ctrl+U: clear any prompt line first
for ch in "echo %s > /tmp/wl.txt" % sys.argv[1]:
    send({"t":"key","c":ch})
send({"t":"key","k":"enter"})
print("command typed into the Wayland terminal via the phone protocol")
PYEOF
sleep 1.5
grim -o Virtual-1 /tmp/wl.png 2>/dev/null && echo "==> grim screenshot: /tmp/wl.png ($(stat -c%s /tmp/wl.png) bytes)"
GOT="$(cat /tmp/wl.txt 2>/dev/null || true)"
echo "==> the shell in the Wayland terminal wrote: $GOT"
[ "$GOT" = "$MARK" ] && echo "PASS: keystrokes reached a real Wayland client, verbatim" || { echo "FAIL"; exit 1; }
'
limactl copy "$VM:/tmp/wl.png" "$ROOT/dist/wayland-validation.png" 2>/dev/null || true
