# Remotype Host (Linux)

A small Go companion that receives keyboard / trackpad / media events from the
Remotype phone app over the LAN (discovered via Bonjour `_hsbtk._tcp`) and
injects them through the Linux kernel's **uinput** device. Nothing is injected
until the phone has paired with this computer using a code shown here, and
every frame after that is encrypted — see [`../docs/RT1.md`](../docs/RT1.md).

Because uinput events flow through evdev exactly like a real USB keyboard and
mouse, this host works under **both X11 and Wayland** (libinput reads evdev) —
that's the whole point of going through the kernel rather than an X11-only
XTEST path.

## Build

From any OS:

```sh
GOOS=linux GOARCH=amd64 go build -o dist/remotype-host-linux .
```

Or natively on Linux:

```sh
go build -o dist/remotype-host-linux .
```

## Grant access to /dev/uinput

By default `/dev/uinput` is root-only, so the host can't open it as a regular
user. Add a udev rule and put yourself in the `input` group:

1. Create `/etc/udev/rules.d/99-remotype-uinput.rules`:

   ```
   KERNEL=="uinput", MODE="0660", GROUP="input"
   ```

2. Make sure the `uinput` module loads at boot (some distros don't autoload it):

   ```sh
   echo uinput | sudo tee /etc/modules-load.d/uinput.conf
   sudo modprobe uinput
   ```

3. Add your user to the `input` group, then reload udev (and log out/in, or
   reboot, so the new group membership takes effect):

   ```sh
   sudo usermod -aG input "$USER"
   sudo udevadm control --reload-rules && sudo udevadm trigger
   ```

You should then be able to read/write `/dev/uinput` without root.

## Run

```sh
./dist/remotype-host-linux
```

It listens on port 50808 (or an ephemeral port if that one is taken) and
advertises `_hsbtk._tcp` on the LAN. Open Remotype on your phone (same Wi-Fi)
and pick this computer. If the host exits with "Could not open /dev/uinput",
revisit the udev step above.

## The tray

On a desktop the host shows a system-tray icon and menu — the same shape as the
macOS menu bar and the Windows tray, built on the same library — with the port
it is listening on, the Wi-Fi-only promise, **Pair a phone…**, a **Paired
phones** submenu (remove one, or all), **About**, and **Quit**. The icon is a
StatusNotifierItem, so it appears wherever the desktop has a status-notifier
host: KDE, most panels, XFCE with the Status Notifier plugin, sway with waybar;
GNOME needs the AppIndicator extension. On a headless machine (no display) the
host stays a plain background process and puts the pairing code in the log;
`-no-tray` forces that anywhere, `-tray` forces the icon.

## Pairing

The first time a phone picks this computer, a 12-character pairing code is
printed in the terminal the host runs in — and posted as a desktop notification
when `notify-send` (libnotify) is installed, for a host started as a service.
Enter it on the phone within ten minutes. Three wrong attempts retire the code;
tapping the computer on the phone again mints a new one.

After that the phone is remembered and reconnects without a code. The host's
identity and its paired phones live in `~/.config/remotype-host/` as
owner-only files:

```sh
remotype-host-linux -devices      # list the paired phones
remotype-host-linux -forget-all   # remove every pairing (each phone pairs again)
```

Deleting that directory does the same as `-forget-all` and also gives the host
a new identity, so every phone sees an unknown computer and has to pair again.

Logging goes to stdout; set `REMOTYPE_HOST_LOG=/path/to/host.log` to mirror it
into a file.

## Scope / status

- **Implemented:** the RT1 trust layer — pairing, sealed sessions and the
  guard that refuses every message until the peer has proved it is a paired
  phone (the crypto and session code is shared with the Windows host file for
  file; only the surface that shows the code is Linux-specific); the v2
  handshake (`hello` → `hi`); and injection for `key`, `text`, `mod`, `mm`,
  `mb`, `mc`, `sc`, `zoom`, `cc` via uinput. Like the Windows host, pairing
  and sessions are per connection: a second paired phone coexists with the
  first rather than evicting it.
- **Out of scope (parsed, no-op):** the Spotlight overlay messages
  (`ovl.mode` / `ovl.move` / `ovl.ink` / `ovl.clear` / `ovl.cursor`) — see
  `../docs/PROTOCOL.md`; the overlay is a macOS/Windows feature for now. A v2 client that sends them won't error;
  the host just ignores them.
- The clipboard / vitals / open-app / proximity v2 features are not
  implemented here either (unknown `t` is a safe no-op).

> **Keycode caveat:** the ASCII→`KEY_*` and named-key tables are a hand-built
> US-layout map and have **not** been validated on real Linux hardware. Expect
> to QA the keymap on-device (non-US layouts in particular may map differently).

## Keyboard layouts

uinput is a scancode protocol: the host says "the key at this position went
down" and the desktop's active layout decides what character that is. The
built-in table is the US layout, so on any other layout the same scancodes
type the wrong thing — under Spanish the US `;` key types `ñ`, and the US `'`
key is a dead accent that types nothing and corrupts the next letter.

So the host translates each character under the layout that is actually
active, through xkbcommon (`xkbcli how-to-type`, package `libxkbcommon-tools`)
— the one layer X11 and every Wayland compositor share for exactly this
decision. Shift and AltGr are pressed as the layout requires. The layout is
taken from, in order: `-layout es` (or `es(cat)`), `REMOTYPE_LAYOUT`,
`setxkbmap -query` (X11), GNOME's input-sources, KDE's `kxkbrc`, else US.

Characters a layout reaches only through a dead-key sequence (é on Spanish)
have no direct key; they are logged once and skipped rather than mistyped.

`layout_linux_test.go` proves this on the real device: it types ñ, ', ;, @ and
n under the Spanish layout and reads back the exact keycodes and modifiers, and
é, É and ü as their dead-key sequences.

One thing this surfaced that applies to *any* virtual keyboard on X11: the
layout has to be set for every keyboard, not only the core one. `setxkbmap es`
on its own configures the core keyboard; a device that appears afterwards —
this host's, on startup — inherits the server default and types as US. Real
desktops already do the right thing (`/etc/default/keyboard` becomes an
InputClass for all keyboards; GNOME and KDE apply the layout per device), and
`ci/validate-desktop-x11.sh` configures its test server the same way.

## Install

Built packages are on https://remotype.custavia.com/downloads/ and on this
repository's Releases page, with their SHA-256 in [`../CHECKSUMS.md`](../CHECKSUMS.md).

From the `.deb` (`packaging/build-packages.sh` builds it for amd64 and arm64):

```sh
sudo dpkg -i remotype-host_<version>_<arch>.deb
sudo apt install libxkbcommon-tools libnotify-bin   # layouts, notifications (recommended)
```

or from the tarball: `sudo ./install.sh`. Either way you get `/usr/bin/remotype-host`,
a udev rule that lets the logged-in user open `/dev/uinput` (no group or root
needed), and an autostart entry so the host runs with your desktop session —
where it can see your keyboard layout and post the pairing code as a
notification. Log out and in, or start it now with `remotype-host`.

Removing the package (`dpkg -r`, or `sudo ./uninstall.sh`) takes all three
files away; your identity and pairings under `~/.config/remotype-host/` are
yours and stay until you delete them.

## Validating the trust layer

`rt1_selftest.go` reproduces every value in `../spec/rt1/vectors.json` at
startup and logs "RT1 self-test passed". The probes in `../spec/rt1/` then
exercise a *running* host over a real socket: `interop_host.py` (guard,
handshake, sealed frames, tamper, clean reconnect, the full ceremony),
`pairing_edges.py` (cancel, drop, bystanders, the three-wrong burn) and
`probation_probe.py` (an unpaired socket can neither inject nor evict). Start
the host with `REMOTYPE_RT1_TEST_CODE_FILE=/tmp/rt1code.txt` so the scripts can
read the code the way a user would, then:

```sh
export RT1_FLAVOR=go RT1_SUPPORT_DIR=$HOME/.config/remotype-host \
       RT1_TEST_CODE_FILE=/tmp/rt1code.txt \
       RT1_CODE_CMD="cat /tmp/rt1code.txt" RT1_CLEAR_CMD="rm -f /tmp/rt1code.txt" \
       RT1_LOG_CMD="tail -40 /tmp/host.log"
python3 ../spec/rt1/interop_host.py 127.0.0.1 50808
python3 ../spec/rt1/pairing_edges.py 127.0.0.1 50808
python3 ../spec/rt1/probation_probe.py 127.0.0.1 50808
```

All of this passes in the Lima VM described under `ci/`. The two
`probation_probe.py` checks about the previous incumbent being *evicted* describe
the macOS single-connection model and are expected to fail against this host,
which keeps paired connections independent.

## Validating the whole path on a real X server

`ci/validate-desktop-x11.sh` runs, in the VM, an Xorg server with the GPU-less
`dummy` video driver and the ordinary libinput input driver — it takes input
exactly as a desktop's X server does — configured for the Spanish layout, puts
a Tk text field on it, starts the host against that display, and types
`hola ñ;@é Ü` through the phone protocol (`ci/type_probe.py`: pairing, a sealed
RT1 session, key frames). The text field must receive exactly that string:
`@` through AltGr, `é` composed from the dead key, `Ü` from dead diaeresis
plus Shift. It does. (Xvfb cannot stand in for this: it never reads evdev.)

A real iPhone has been through this whole path against the host: pair with the
on-screen code, a sealed session, and typed text arriving in a desktop text
field. (That run also found a phone-side bug — the app sent `pair.cancel` on a
successful pair, which a correct host rejects on a sealed link; fixed in the
phone app.)

`ci/validate-desktop-full.sh` goes one step further, onto a **full desktop
session**: a real XFCE session (session manager, xfwm4 window manager, panel)
running a real GTK editor (Mousepad). It types a line through the phone protocol
into the focused editor, saves it with a `Ctrl+S` chord sent the same way, and
checks that the file on disk matches byte for byte; it also moves the pointer
and clicks through the protocol. Keyboard and trackpad both land where a user
would expect, in a real toolkit under a real window manager.

And `ci/validate-desktop-wayland.sh` proves the same on **Wayland**, with no X
server anywhere: a real sway (wlroots) session on a virtual-KMS display takes
our injected device through libinput exactly as any Wayland desktop does, and a
command typed through the phone protocol into a Wayland terminal runs and writes
a file that is checked byte for byte. (Getting there needs a seat — `seatd` —
and the DRM backend on the `vkms` kernel module, because the wlroots headless
backend provides outputs but no input; the script sets both up.)

**Still not covered:** a heavyweight GNOME/KDE Wayland session specifically —
sway exercises the same wlroots/libinput/xkb path a GNOME or KDE Wayland session
uses, so this is about desktop-specific integration (their own layout settings,
already read on X11 via gsettings/kxkbrc), not the input path itself.

## Validating the keymap

The ASCII→`KEY_*` and named-key tables were transcribed by hand, so they get
tested by loopback rather than by inspection: `keymap_linux_test.go` creates the
real uinput device, types every printable character and named key, reads the
events back off `/dev/input/eventN`, and decodes each keycode through an
*independent* copy of the kernel's US keymap. Validating a table against itself
would prove nothing, so the reference in the test is written from
`<linux/input-event-codes.h>` numbering and shares no code with the injector.

It needs `/dev/uinput`, and it skips cleanly when that is absent — so
`go test ./...` stays green on macOS. On a Mac with Docker Desktop, no Linux
machine is required:

```sh
GOOS=linux GOARCH=arm64 go test -c -o /tmp/keymap.test .
docker run --rm --privileged -v /tmp/keymap.test:/t:ro alpine /t -test.v
```

The container has no udev, so no `/dev/input/eventN` ever appears on its own.
The test handles that: it asks uinput for its sysfs name (`UI_GET_SYSNAME`),
reads the major/minor from `/sys/class/input/<input>/<event>/dev`, and `mknod`s
the node itself.

### Against a real kernel, udev and libinput

Docker proves the events round-trip, but its VM has no udev (the event node never
appears on its own) and no libinput, so it cannot answer the question that
matters: **does a compositor accept the device we create?**

`ci/validate-linux.sh` answers it in a Lima VM — boots if needed, builds, runs
the loopback tests, and watches the whole thing through `libinput debug-events`:

```sh
./ci/validate-linux.sh            # leaves the VM up for the next run
./ci/validate-linux.sh --clean    # deletes it afterwards and reclaims ~2.7 GB
```

It fails the run unless libinput both sees the device and reports it as
**keyboard AND pointer** (`cap:kp`). That check exists because a device that came
up keyboard-only would still pass every loopback test while the trackpad
silently did nothing under a real compositor.

Verified 2026-09-18 on Ubuntu 24.04 / kernel 6.8 (aarch64):

```
event3  DEVICE_ADDED  Remotype Virtual Input  seat0 default group4  cap:kp
        libinput reported 737 keyboard events
```

Since X11's libinput driver and every Wayland compositor sit on this same layer,
that is strong evidence both will accept it. The VM costs ~2.7 GB while it
exists; `--clean` removes it.

**Still not covered:** a full desktop session end to end.
