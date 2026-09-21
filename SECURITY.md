# Security

## Reporting a vulnerability

Email **support.remotype@custavia.com** with "security" in the subject. Please
include the host platform and version, what you observed, and how to reproduce
it. You will get an acknowledgement within a few days. Please do not open a
public issue for anything that could put users at risk before a fix ships.

## What the host promises

- **LAN only.** The host listens on the local network and makes no outbound
  internet connections of its own — no telemetry, no update checks.
- **Nothing acts before pairing.** Every message, including keystrokes and
  pointer events, is refused until the connection proves it holds the key of a
  device you paired at the computer with an on-screen code.
- **Sealed sessions.** After the handshake every frame in both directions is
  AES-256-GCM encrypted with per-session keys.
- **Explicit, revocable OS permissions.** The host asks only for what a feature
  needs and explains why.

## What it does not promise

RT1 protects the *link*, not the *computer*. Anyone who can already run code as
your user on either device can read the stored identity and impersonate it.
Pairing is a statement that these two devices may drive each other — which is
exactly what the product is for. The full threat model and the reasoning behind
each choice are in [`docs/RT1.md`](docs/RT1.md).

## Verifying what you run

- Published builds and their SHA-256 checksums: [`CHECKSUMS.md`](CHECKSUMS.md).
- macOS builds are Developer ID signed and notarized; check with
  `spctl -a -vv "/Applications/Remotype Host.app"`.
- The RT1 conformance vectors in [`spec/rt1/vectors.json`](spec/rt1/vectors.json)
  are reproduced by every host at launch; `spec/rt1/verify_vectors.py` checks
  the vectors themselves against published RFC test values.
