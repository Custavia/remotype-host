# Changelog

## 1.1.1 — 2026-09-20

First-run fixes on all three hosts. Nothing else changed, and nothing on the
wire moved — a 1.1.0 phone pairs with a 1.1.1 host and the reverse.

- **macOS: the permission wizard could sit at "waiting for the switch" forever.**
  Both of the in-process ways to read a TCC grant — `AXIsProcessTrusted()` and
  `CGPreflightPostEventAccess()` — cache their answer for the life of the
  process on current macOS, so a host that was already running when the user
  flipped the switch never saw it arrive. The wizard now asks a short-lived
  child process (`RemotypeHost --tcc-probe`), which is born after the grant and
  reads it honestly, and it distinguishes "allowed" from "allowed and usable in
  this process": the second case says so and offers the restart that applies
  it, resuming the flow on the other side.
- **macOS: the wizard did not appear on a reinstall.** It was gated on a
  preference that outlives the app bundle, so reinstalling over a cleared grant
  produced a silent menu-bar icon that could not type. It is now gated on the
  grant itself.
- **Windows: the setup wizard recorded that it was shown, not that setup
  worked.** Closing it early, or answering the firewall dialog wrong, meant no
  later launch ever explained the firewall again. It now returns each launch
  until a phone has actually reached the host once.
- **Linux: launching from the desktop without `/dev/uinput` access looked like
  nothing happened** — the host printed to a console the user did not have and
  exited. With a tray available it now stays up, says why in the tray and a
  notification, and retries, so the udev fix takes effect without relaunching.

## 1.1.0 — 2026-09-19

The first public release line.

- **RT1 trust layer** on every host: pairing with an on-screen code, sealed
  AES-256-GCM sessions, and a guard that refuses every message — including
  input — until the peer has proven it is a paired device. Conformance vectors
  and an independent interop client live in `spec/rt1/`.
- **No internet, by construction.** The macOS host's auto-updater was removed;
  "Check for updates…" opens the download page in the browser.
- **Permissions explained** wherever a permission appears, with a plain
  statement of what each one is for and what it never touches.
- **Uninstall leaves nothing behind** on macOS and Windows.
- macOS: text is injected as Unicode rather than US key positions, so
  non-English layouts and non-US keyboards type correctly.
- macOS: an unpaired connection can no longer evict the paired phone.
- Windows: the firewall rule covers every network profile, Public included;
  the pairing window comes to the front when a phone asks.

- **Linux host: a system-tray UI.** On a desktop the host now shows a tray icon
  and menu — the same shape, wording and icon as the macOS menu bar and the
  Windows tray, on the same `fyne.io/systray` library: listening port, the
  Wi-Fi-only promise, Pair a phone, a Paired phones submenu (remove one or all),
  About, and Quit. It is a StatusNotifierItem (KDE, XFCE, sway+waybar; GNOME via
  the AppIndicator extension). Headless machines stay a background process and
  log the pairing code; `-tray` / `-no-tray` force the choice.

- **Linux host: the RT1 trust layer.** Pairing with an on-screen code (in the
  terminal, and as a desktop notification where libnotify exists), sealed
  sessions, and the guard that refuses every message until the phone has
  proved it is paired — the same code as the Windows host, file for file. The
  1.1.0 phone apps can now pair with a Linux computer. Identity and pairings
  live in `~/.config/remotype-host/`; `-devices` and `-forget-all` manage them.
  Listens on the well-known port 50808 and re-advertises on network changes,
  like the other hosts.
- **Linux host: keyboard layouts.** Characters are translated under the
  desktop's active layout through xkbcommon instead of a fixed US table, with
  Shift and AltGr as the layout requires; the layout is detected from X11,
  GNOME or KDE, or given with `-layout`. Proven on the real uinput device under
  the Spanish layout, including dead-key composition (é, É, ü). The device now
  declares the whole keyboard range, so no layout-specific key is dropped by
  the kernel.
- **Linux host: packages.** `packaging/build-packages.sh` produces a tarball and
  a `.deb` for amd64 and arm64 with a udev rule (logind `uaccess`, no groups or
  root) and an XDG autostart entry; removal leaves nothing behind.
- **Linux host: validated on a real X server, and with a real phone.**
  `ci/validate-desktop-x11.sh` types through the phone protocol into a text
  field on an Xorg server with the Spanish layout and gets back exactly what
  was sent; a real iPhone has paired, held a sealed session, and typed onto a
  Linux desktop; and `ci/validate-desktop-full.sh` drives a full XFCE session —
  typing (with a Ctrl+S save checked against the file on disk) and a trackpad
  move-and-click — into a real Mousepad editor. `ci/validate-desktop-wayland.sh`
  does the equivalent on a real **Wayland** session (sway on virtual KMS, via
  seatd + libinput, no X server): a command typed through the phone protocol
  into a Wayland terminal runs and writes a file that matches byte for byte.
- **Linux host: `sealed line failed to open` now says why.** The host logs,
  locally only, whether the rejected line was plaintext (a peer that sent an
  unsealed frame on an open session) or an undecryptable sealed blob (diverged
  keys), which is what pinned down the phone-side pairing bug above.
