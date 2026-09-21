# Third-party notices

Remotype Host is licensed under the Apache License 2.0 (see `LICENSE`). It builds
on the third-party components below, each under its own license. Every one of them
is a permissive licence (Apache-2.0, MIT, BSD or ISC); none is copyleft, and
nothing here obliges a user of Remotype Host to publish their own source.

## Vendored in this repository

| Component | Location | License |
|---|---|---|
| go-chromecast (modified fork of v0.3.4) | `macos/sidecar/third_party/go-chromecast/` | Apache-2.0 — see its `LICENSE` |
| libopus (headers + universal static library) | `macos/sidecar/third_party/opus/` | BSD-3-Clause — see its `COPYING` |

**Modifications to go-chromecast**, as required by Apache-2.0 section 4(b): one
file, `cast/connection.go`, is changed. Upstream discards an incoming Cast message
that carries no Google `"type"` key; our receiver's CUSTOM-namespace replies have
no such key, so they were dropped and every cast hung. The patched build forwards
them to the receive channel instead. The change is marked in place with a
`PATCH (Remotype)` comment, and recorded in that directory's `MODIFICATIONS.md`.
Every other file is byte-identical to upstream v0.3.4.

## Go modules linked into the shipped binaries

Fetched at build time and resolved by each `go.mod` / `go.sum`; their source is not
redistributed in this repository, but they are compiled into the binaries we publish.

| Module | Used by | License |
|---|---|---|
| fyne.io/systray | Windows host, Linux host | Apache-2.0 |
| github.com/vishen/go-chromecast | macOS cast helper (the vendored fork above) | Apache-2.0 |
| github.com/pion/webrtc/v4 and the pion/* family (datachannel, dtls, ice, interceptor, logging, mdns, randutil, rtcp, rtp, sctp, sdp, srtp, stun, transport, turn) | macOS cast helper | MIT |
| github.com/asticode/go-astits, github.com/asticode/go-astikit | macOS cast helper | MIT |
| github.com/buger/jsonparser | macOS cast helper | MIT |
| github.com/sirupsen/logrus | macOS cast helper | MIT |
| github.com/cenkalti/backoff | Windows host, Linux host | MIT |
| github.com/grandcat/zeroconf | Windows host, Linux host | MIT |
| github.com/gogo/protobuf | macOS cast helper | BSD-3-Clause |
| github.com/google/uuid | macOS cast helper | BSD-3-Clause |
| github.com/wlynxg/anet | macOS cast helper | BSD-3-Clause |
| github.com/miekg/dns | Windows host, Linux host | BSD-3-Clause |
| github.com/pkg/errors | macOS cast helper | BSD-2-Clause |
| github.com/godbus/dbus/v5 | Windows host, Linux host (via systray) | BSD-2-Clause |
| golang.org/x/crypto, x/net, x/sys, x/text, x/time | all hosts | BSD-3-Clause |

Neither go-chromecast nor fyne.io/systray ships a `NOTICE` file upstream, so there
is none to reproduce here.

## Platform components

The Go standard library (BSD-3-Clause) and the Swift standard library, Apple SDKs
and frameworks are used under their own licenses. All cryptography in the RT1 trust
layer comes from the Go standard library (`crypto/*`) and Apple's CryptoKit; no
third-party or hand-rolled cryptographic implementation is included.

Inno Setup, used to build the Windows installer, is not distributed with this
repository.
