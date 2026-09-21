# Remotype Host for macOS

The macOS half of Remotype: a menu-bar app that lets the Remotype phone app act
as this Mac's keyboard, trackpad, presenter remote and — when you turn it on —
show the screen on the phone. It talks only to devices on the local network,
after an explicit pairing (see [`../docs/RT1.md`](../docs/RT1.md)), and never
connects to the internet.

## Build

Requires Xcode, [xcodegen](https://github.com/yonaskolb/XcodeGen) and Go 1.23+
(the Cast helper under `sidecar/` is a Go program embedded in the app bundle).

```sh
cd macos
xcodegen generate
xcodebuild -project RemotypeHost.xcodeproj -scheme RemotypeHost -configuration Debug build
```

Debug builds are ad-hoc signed so they build on any Mac. macOS ties the
Accessibility and Screen Recording grants to the code signature, so an ad-hoc
build asks again after every rebuild; for a stable local install use
`./dev-install.sh` with `REMOTYPE_DEVELOPMENT_TEAM` set to your Apple Team ID.
Release builds are described in [`../docs/RELEASING.md`](../docs/RELEASING.md).

## Permissions

- **Accessibility** — needed to type and move the mouse for you. Never reads the screen.
- **Screen Recording** — only when you stream the screen to the phone; nothing is recorded or saved.

Both can be revoked at any time from the app's menu or in System Settings.

## Text injection and keyboard layouts

Typing goes out as a **Unicode payload** (`CGEvent.keyboardSetUnicodeString`),
not as virtual keycodes. That is what makes non-English typing work, and it also
fixes plain ASCII on a non-US Mac: a US keycode posted to an AZERTY layout types
the wrong letter.

Two things deliberately stay on the keycode path:

- **Return and Tab.** `U+000A` delivered as a text payload is ignored by most
  apps, so Enter would silently stop working. Note `"\r\n"` is a *single*
  `Character` in Swift, so it has its own entry — without it, every line break
  in pasted Windows text would vanish.
- **Shortcuts.** `Cmd+C` means "the key at C's position", so a chord needs the
  virtual keycode. Shift alone is not a shortcut; capitalisation rides along in
  the Unicode payload.

The planning logic lives in `Sources/TextPlan.swift` with no CGEvent in it, so
it can be tested without an Accessibility grant or a window server:

```sh
swiftc -parse-as-library -o /tmp/textplan Sources/TextPlan.swift Tests/TextPlanTests.swift
/tmp/textplan
```

That covers grapheme clusters never being split across events, oversized
clusters staying whole, Return/Tab routing, the per-event cap, and characters
that the old US-only table silently dropped. **It does not prove macOS renders
the payload** — that still needs the real host with Accessibility granted, typing
into a text field.

Remember `xcodegen generate` after adding a source file; the `.xcodeproj` is
generated and gitignored.
