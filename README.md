# Remotype Host

The computer side of [Remotype](https://remotype.custavia.com) — the small program
that lets the Remotype phone app act as your computer's keyboard, trackpad,
presenter remote and, when you turn it on, show your screen on the phone.

This repository holds the complete source of every host we ship:

| Host | Language | Directory | Status |
|---|---|---|---|
| macOS | Swift (+ a Go helper for casting) | [`macos/`](macos/) | shipping |
| Windows | Go | [`windows/`](windows/) | shipping |
| Linux | Go | [`linux/`](linux/) | shipping |

The phone apps (iOS and Android) are separate, closed-source products. The host
is open because a program that types on your computer should be inspectable by
the people who run it.

## What the host does — and does not — do

- **Works entirely on your local network.** The phone finds the host with
  Bonjour/mDNS and connects over TCP on the LAN (or a VPN you set up yourself).
- **Never connects to the internet.** No telemetry, no analytics, no update
  checks, no crash reporting. The host's only sockets are the LAN listener and
  the phones and TVs you connect. Verify it yourself: run the host and look at
  `lsof -i` / the Windows firewall log.
- **Refuses everything until you pair.** A phone must be paired at the computer
  with a code shown on the computer's screen. After that, every message is
  authenticated and every frame is encrypted (AES-256-GCM) — see
  [`docs/RT1.md`](docs/RT1.md) for the full protocol and threat model.
- **Asks for exactly the permissions it needs, and explains each one.** On macOS:
  Accessibility (to type and move the mouse for you — it never reads the screen)
  and Screen Recording (only while you stream the screen to the phone; nothing is
  recorded or saved). Both are revocable at any time.
- **Uninstalls cleanly.** Each host's uninstall removes its identity, paired
  phones, preferences and logs.

## How it works

```
phone ──(Bonjour discovery)──▶ host advertises _hsbtk._tcp on the LAN
phone ──(TCP :50808)─────────▶ RT1 handshake: pair once with a code, then a
                                sealed session (X25519 + HKDF + AES-256-GCM)
phone ──▶ newline-delimited JSON events (keys, pointer, clipboard, …) ──▶ host
                                injects them with the OS input APIs
```

Two documents are normative; if code disagrees with them, the code is wrong:

- [`docs/RT1.md`](docs/RT1.md) — the trust layer: pairing, session keys, framing,
  the guard. Every implementation self-tests at launch against
  [`spec/rt1/vectors.json`](spec/rt1/vectors.json), and
  [`spec/rt1/`](spec/rt1/) holds an independent Python implementation that
  exercises a real host over a real socket.
- [`docs/PROTOCOL.md`](docs/PROTOCOL.md) — the message vocabulary above RT1.

`_hsbtk._tcp` is the project's original working name, kept on the wire for
compatibility.

## Building

**macOS** — Xcode, [xcodegen](https://github.com/yonaskolb/XcodeGen), Go 1.23+.

```sh
cd macos && xcodegen generate
xcodebuild -project RemotypeHost.xcodeproj -scheme RemotypeHost -configuration Debug build
```

Debug builds are ad-hoc signed and build on any Mac. See
[`macos/README.md`](macos/README.md) for permissions and local installs.

**Windows** — Go 1.23+, from any OS:

```sh
cd windows
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags "-H windowsgui -s -w" -o remotype-host.exe .
```

The installer is an [Inno Setup](https://jrsoftware.org/isinfo.php) script in
[`windows/installer/`](windows/installer/).

**Linux** — Go 1.23+; injection goes through `uinput`, so it works under X11 and
Wayland alike. See [`linux/README.md`](linux/README.md).

```sh
cd linux && go build -o remotype-host-linux .
./packaging/build-packages.sh <version>     # tarballs + .deb for amd64 and arm64
```

## Verifying a download

Published builds are listed with their SHA-256 in [`CHECKSUMS.md`](CHECKSUMS.md),
and every release on the Releases page carries the same files with a combined
`SHA256SUMS`, so the hashes live somewhere other than the download server.
macOS builds are signed with a Developer ID and notarized by Apple; Windows and
Linux builds are not yet code-signed, so SmartScreen warns on first run and the
Linux packages are verified by checksum alone.

We do not yet have reproducible builds. A source review therefore proves the
design and the behaviour of the code, not that a given download is byte-for-byte
this source; the checksums prove that the download is the one we published.

## Security

Please report vulnerabilities privately — see [`SECURITY.md`](SECURITY.md).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Changes to the protocol or the trust
layer start with the spec, not the code.

## License

Apache License 2.0 — see [`LICENSE`](LICENSE). Third-party components and their
licenses are listed in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
"Remotype" and "Custavia" are names of the project's maintainers; the license
does not grant rights to use them for other software.
