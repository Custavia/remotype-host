# Releasing Remotype Host

How a shipped build is produced. Nothing here runs on hosted CI: every release
is built on a machine the maintainers control.

## macOS

Gatekeeper effectively requires **Developer ID signing + notarization** for
apps distributed outside the App Store.

One-time setup on the release Mac:

1. An Apple Developer Program membership and a "Developer ID Application"
   certificate in the login keychain (Xcode → Settings → Accounts → Manage
   Certificates).
2. Notary credentials stored once, from an app-specific password:
   ```sh
   xcrun notarytool store-credentials remotype \
     --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
   ```
3. `brew install xcodegen create-dmg`.

Every release:

```sh
cd macos
REMOTYPE_DEVELOPMENT_TEAM=<team-id> ./scripts/release-mac.sh   # version from project.yml
```

The script builds a universal Release binary with the hardened runtime, verifies
the signature, notarizes and staples the app, packages a drag-to-Applications DMG,
notarizes and staples that too, and prints the SHA-256 for `CHECKSUMS.md`.
The team id is passed on the command line and never committed.

The host has no auto-updater. Users get new versions from the download page.

## Windows

```sh
cd windows
for arch in amd64 arm64; do
  GOOS=windows GOARCH=$arch CGO_ENABLED=0 go build -trimpath \
    -ldflags "-H windowsgui -s -w -X main.appVersion=<version>" \
    -o dist/remotype-host-$arch.exe .
done
```

Then, on a Windows machine with [Inno Setup 6](https://jrsoftware.org/isinfo.php)
installed, from the `windows/` directory:

```
"C:\Program Files (x86)\Inno Setup 6\ISCC.exe" /DMyAppVersion=<version> installer\remotype-host.iss
```

The installer is written to `dist\RemotypeHost-<version>-setup.exe`. Windows
builds are not yet code-signed; SmartScreen shows "Windows protected your PC"
until a signing certificate is in place.

## Linux

```sh
cd linux && ./packaging/build-packages.sh <version>
```

Produces `dist/remotype-host-<version>-linux-{amd64,arm64}.tar.gz` and, where
`dpkg-deb` is available (Debian/Ubuntu, or `brew install dpkg` on macOS),
`dist/remotype-host_<version>_{amd64,arm64}.deb`, plus a `SHA256SUMS` file.
Before publishing, install the `.deb` on a real machine or the Lima VM and run
`remotype-host -version`, then remove it and confirm nothing is left.

## After building

- Record each artifact's SHA-256 in `CHECKSUMS.md` and publish the artifact
  next to its `.sha256` file.
- Attach the artifacts and a combined `SHA256SUMS` to a GitHub Release tagged
  `v<version>`, created from the release machine (`gh release create v<version>
  <files>`), so the hashes are published somewhere other than the download server.
- Add the release to `CHANGELOG.md`.
