# Remotype Host for Windows

Lets the Remotype phone app drive a **Windows PC** — keyboard, trackpad, scroll,
pan, zoom, media keys, the Spotlight overlay, clipboard bridge, a CPU/RAM vitals
stream and open-app — over the LAN. Same protocol as the Mac companion
(see [`../docs/PROTOCOL.md`](../docs/PROTOCOL.md)); injection uses the Win32 `SendInput`
API. The phone app is unchanged: it discovers this host via Bonjour just like
the Mac one.

## Feature parity vs the Mac host
| Capability | Windows | Notes |
|---|---|---|
| Keyboard / modifiers / text | ✅ | incl. the keypad cluster (Numpad mode) |
| Trackpad: move / buttons / scroll / zoom | ✅ | zoom = Ctrl+scroll |
| Media keys | ⚠️ | play/pause/next/prev/mute/vol ✅; **brightness + scrub have no standard Windows VK** → ignored |
| Spotlight overlay (4 sub-modes) | ✅ | layered click-through window (software rasterizer) |
| v2 hello-gating | ✅ | clip/vitals/open/overlay require a v2 hello on the connection |
| Clipboard bridge (`clip.get`/`clip.set`) | ✅ | 64 KB cap, never logged |
| Vitals stream | ⚠️ | **CPU + RAM real**; `vol` reports -1 and `np` (now-playing) omitted — WASAPI volume + SMTC now-playing are TODO |
| Open app (`open`) | ✅ | ShellExecute("open") — resolves via App Paths + associations |
| Walk-away / proximity lock | ❌ | **Mac + iOS only.** Needs a BLE central + RSSI ranging; WinRT Bluetooth-LE is incompatible with the Go console host (would require a C#/C++ rewrite). Not planned for the Go host. |

## Build
From any OS with Go (cross-compiles):
```bash
cd windows-companion
GOOS=windows GOARCH=amd64 go build -o remotype-host.exe .
```
Or on the Windows machine itself: `go build -o remotype-host.exe .`

## Run
1. Double-click **remotype-host.exe**. It runs in the **system tray** (notification
   area) — no console window. Right-click the tray icon for **Re-advertise on
   network** (re-announce if the phone can't find this PC), **About**, and **Quit**.
2. When **Windows Firewall** prompts, **Allow access** on your **Private**
   network (needed for the phone to connect and for mDNS discovery on UDP 5353).
3. On the phone (same Wi-Fi), open **Remotype** and pick this computer from the
   list. Type / trackpad away.

Logs are written to `%APPDATA%\RemotypeHost\host.log` (connections, clipboard /
vitals / open-app activity — clipboard contents are never logged).

Build the tray (no-console) binary with the GUI subsystem flag:
```bash
GOOS=windows GOARCH=amd64 go build -ldflags "-H windowsgui" -o remotype-host.exe .
```

## Notes & limits
- **No special permission needed** to inject input (unlike macOS) — `SendInput`
  just works. One exception: it can't send into apps running **as Administrator**
  unless the host is also run as Administrator (Windows UIPI). Run the exe as
  admin if you need to control elevated windows.
- The **⌘/Win modifier** maps to the Windows key. The app switcher on Windows is
  **Alt+Tab** — hold **Alt** on the strip, tap **Tab**, release Alt to commit.
- **Zoom** (pinch) is synthesized as **Ctrl+scroll** (zooms most apps).
- **Brightness** keys are not injected (Windows has no standard brightness
  virtual key); volume / play-pause / next / prev / mute do work.
- Plain typing uses Unicode injection (layout-independent); shortcuts use virtual
  keys via `VkKeyScan` so Ctrl/Alt/Win combos hit the right keys for your layout.

## Status
Ships for x64 and ARM64 and is validated on real Windows 11 (x64) — input
injection, the Spotlight overlay, the clipboard / vitals / open-app events, the
pairing window and the installer's install / upgrade / uninstall paths. ARM64
builds have had less on-device time. Report anything that misbehaves.
