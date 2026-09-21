# Packaging the Linux host

`build-packages.sh` produces, for amd64 and arm64:

- `remotype-host-<version>-linux-<arch>.tar.gz` — the binary, this README, the
  udev rule and an `install.sh` that puts them in place.
- `remotype-host_<version>_<arch>.deb` — the same, as a package
  (`dpkg-deb` must be available: any Debian/Ubuntu machine, or `brew install
  dpkg` on macOS).

What gets installed:

| Path | Purpose |
|---|---|
| `/usr/bin/remotype-host` | the host |
| `/usr/lib/udev/rules.d/70-remotype-host.rules` | lets the logged-in user open `/dev/uinput` without root or group changes (logind `uaccess`) |
| `/etc/xdg/autostart/remotype-host.desktop` | starts the host with the desktop session, where it can see the keyboard layout and post notifications |

The package recommends `libxkbcommon-tools` (layout-aware typing) and
`libnotify-bin` (the pairing code as a desktop notification); without them the
host still runs, with the US table and the code in its log.
