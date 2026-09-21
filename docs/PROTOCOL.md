# Remotype iOS ⇄ Host protocol

The iPhone can't be a Bluetooth HID peripheral, so on the Apple side Remotype is an
**iOS app** that sends input events over the local network to a small **host
companion** (macOS first) which injects them with `CGEventPost`.

- **Transport:** TCP over the LAN, discovered via Bonjour service `_hsbtk._tcp`.
  The host companion advertises; the iOS app browses and connects.
- **Framing:** newline-delimited JSON. One compact JSON object per line (`\n`),
  in **both** directions. Each side buffers bytes, splits complete lines on
  `\n`, JSON-parses each, skips unparseable lines, and keeps the trailing
  partial for the next read.
- **Direction:** two-way since protocol **v2**. Input events stay iOS → host
  and fire-and-forget; the host replies to the handshake (`hi`) and to
  clipboard requests (`clip`), pushes unsolicited `vitals` frames every
  1.5 s while a vitals subscription is active (see the PC vitals stream
  section), and answers a failed `open` with `openresult` (see the open-app
  section). Both sides treat an unknown `t` as a safe
  no-op (parse returns nil / the line is skipped), so vocabulary can grow
  without breaking older peers — a pre-v2 host silently ignores `clip.*`.

## Security note

**The LAN channel is authenticated and encrypted by RT1.** The spec is
[`RT1.md`](RT1.md); this section says what that means for everything
else in this document.

Every message described below — including plain input injection — is refused
until the connection has completed an RT1 session handshake proving that the
peer holds the static key of a device the user paired at the computer. After
that handshake, every line in both directions is an AES-256-GCM sealed blob
rather than JSON. The newline framing is unchanged, which is why the rest of
this document still reads the way it does; what changed is what a line
*contains* once a session is open.

Concretely, this closes the three limits the old gate could not:

1. **There is a secret now.** Pairing takes a 60-bit code, shown on the
   computer and typed on the phone, and folds it into the key derivation — so a
   wrong code produces different keys rather than a comparison that can be
   retried. Three wrong attempts retire the code.
2. **Injection is gated, first of all.** The guard sits above the dispatch
   switch on both hosts, so `key`/`text`/`mod`/`mm`/`mb`/`mc`/`sc`/`zoom`/`cc`
   are refused on the same terms as `clip.*`. This was the important one: the
   old gate protected the clipboard while leaving open the capability that
   trivially subsumes it.
3. **The asymmetry with Android is gone.** Bluetooth HID is protected by BT
   pairing; the LAN transport is now protected by RT1. Neither is a
   "trust-the-LAN" device any more.

What RT1 does **not** claim: it protects the link, not the computer. Anyone who
can already run code as you on either machine can read the identity files and
impersonate the device. It also does not defend the phone against a paired
computer or vice versa — pairing is a statement that these two devices may
drive each other, which is exactly what the product is for.

### The old gate

Protocol v2's `hello` gate — services offered only to a connection that had
sent `{"t":"hello","v":2}` — still exists in the code and is still described in
places below. It is now a **version** check and nothing else: it decides which
capabilities a peer understands, not whether it is allowed to use them. Do not
cite it as a security boundary; RT1 is the boundary.

### Compatibility

The handshake is designed so an old peer is never left hanging, and never
silently half-works:

| phone | host | what happens |
|---|---|---|
| RT1 | RT1, paired | Session opens on the `hello`. No extra round trip, no prompts. |
| RT1 | RT1, not paired | Host answers `rt.no`; the phone raises the pairing sheet and the host shows a code. One ceremony, then the session opens **on the same socket** — no reconnect. |
| RT1 | pre-RT1 | The `hi` carries no `rt`, so the phone marks the link unencrypted and works as before — **unless that same computer has spoken RT1 before**, in which case it refuses. Without that rule, impersonating a host would be as easy as leaving one field out of a reply. |
| pre-RT1 | RT1 | The host answers the `hello` (an unanswered one leaves the phone on its legacy timer) with `rt` and `hid` added, then drops everything that follows. The phone cannot be told why — a phone old enough to skip RT1 ignores any field explaining it — so **the host says it on the computer**: "<phone> is too old to pair — update Remotype on it". |

The `hi` a pre-RT1 phone receives no longer carries the permission list or a
cast-session snapshot. Those describe the machine, and they were being
volunteered to a peer that had proved nothing; they now wait for `rt.conf`.

## Modifier mask (`mods`)
Bitmask, same idea as the Android build:

| bit | 1 | 2 | 4 | 8 |
|-----|---|---|---|---|
| mod | Ctrl | Shift | Alt/Option | GUI (Cmd/Win) |

## Handshake (v2)

```jsonc
{"t":"hello","v":2,"name":"Pratik’s iPhone"}     // phone → host, on connect
{"t":"hi","v":2,"name":"Pratik’s MacBook"}       // host → phone, the reply
```

- The phone sends `hello` (now carrying `v`) the moment the socket is ready.
- A v2+ host answers `hi` with its protocol version and its human-readable
  name (used in the clipboard menu items).
- **2 s legacy window:** if no `hi` arrives within 2 s of connecting, the
  phone marks the host *legacy* (pre-v2) and replaces the clipboard actions
  with an "update Remotype Host" notice. A pre-v2 host parses `hello` fine
  (extra keys are ignored) and simply never replies — nothing breaks.
  While the window is still open the phone *defers* any `clip.set` (flushed
  on `hi`, failed with the update-host guidance on the legacy verdict) so
  "Sent." is never shown for a clip a legacy host silently dropped.

## Clipboard bridge (v2)

```jsonc
{"t":"clip.set","s":"text"}                      // phone → host: put s on the host clipboard
{"t":"clip.get","id":7}                           // phone → host: request the host clipboard
{"t":"clip","s":"text","id":7}                    // host → phone: the reply (id echoed)
{"t":"clip","err":"empty","id":7}                 //   …or: host clipboard has no text
{"t":"clip","err":"toolarge","id":7}              //   …or: host clipboard exceeds the cap
```

- **Hello-gated:** the host only services `clip.*` on a connection that has
  completed a v2 `hello` on that same connection (a version check — the
  security boundary is RT1, see the security note);
  otherwise the message is silently ignored.
- **64 KB cap (UTF-8 bytes), both directions:** the phone refuses to send a
  `clip.set` over the cap; the host answers `clip.get` with `err:"toolarge"`
  instead of an oversized reply (and defensively drops oversized inbound
  `clip.set`). The phone applies the same defensive check to inbound `clip`
  text — refuse, never truncate.
- **Correlation `id`:** the phone tags each `clip.get` with a monotonically
  increasing `id`; the host echoes it in the `clip` reply. The phone drops
  replies whose `id` doesn't match the in-flight fetch, so a slow reply to a
  timed-out request can't resolve a newer one with stale text. The `id` is
  optional on the wire — a host that receives a `clip.get` without one just
  omits it from the reply (unknown extra keys are ignored as usual).
- **3 s reply timeout:** the phone arms a 3 s timeout per `clip.get`; if no
  `clip` reply lands (e.g. a legacy host dropped the request on the floor),
  the fetch fails with a "host didn't respond" status. One fetch is in
  flight at a time — a newer request supersedes the old one (the superseded
  fetch is dropped silently: the user replaced their own request, so no
  error status is shown for it).
- Pre-v2 hosts ignore `clip.*` entirely: `InputEvent.parse` returns nil for
  unknown `t` and the host's line-drain loop skips nil parses.
- Clipboard contents are **never logged or displayed** on either side — the
  host's last-event line and log say only "clipboard".
- Security: like every event, clipboard text crosses the LAN inside an RT1
  sealed frame (see the security note above), and only on a connection that has
  proved it belongs to a paired device.

## PC vitals stream (v2)

```jsonc
{"t":"vitals.sub"}                                // phone → host: start the stream
{"t":"vitals.unsub"}                              // phone → host: stop it
{"t":"vitals","cpu":23,"ram":61,"vol":40,"np":"Artist — Title"}   // host → phone
```

- **Cadence:** one `vitals` frame every **1.5 s** while subscribed. The sub
  itself seeds the host's CPU tick baseline (and kicks off the async
  now-playing fetch), so the first frame arrives ~1.5 s later with a real
  CPU delta — there is no immediate frame.
- **Hello-gated like clip.\*:** the host only services `vitals.*` on a
  connection that has completed a v2 `hello` on that same connection — a raw
  socket doesn't get a telemetry stream of the Mac. A pre-v2 host ignores
  `vitals.*` entirely (unknown `t` parses to nil), so the phone never
  subscribes against a legacy verdict and shows "update Remotype Host"
  guidance in the tile instead.
- **Fields:** `cpu` and `ram` are percentages 0–100 (`ram` = active + wired
  + compressed over physical memory). **`vol` is -1** when there is no
  readable default output device (or the volume property errors) — the phone
  omits the volume readout instead of showing a number. **`np` is absent**
  (not null/empty) when nothing is playing or now-playing info is
  unavailable; when present it is `"Artist — Title"` capped at **120
  characters**. Now-playing content is **never logged** on either side — the
  host's last-event line and log say only "vitals".
- **macOS 15.4 caveat:** now-playing comes from the private MediaRemote
  framework (`MRMediaRemoteGetNowPlayingInfo`, resolved once via dlopen).
  macOS 15.4+ withholds now-playing data from processes without a MediaRemote
  entitlement, so on those systems `np` may be permanently absent — the
  vitals frame still carries CPU/RAM/volume.
- **Background-pause guarantee:** the phone sends `vitals.unsub` the moment
  the app leaves the foreground (before backgrounding completes) and
  re-subscribes on return — nothing streams to a backgrounded app. The host
  additionally stops the stream on `vitals.unsub`, on connection
  teardown/replacement, and on listener shutdown: the timer never outlives
  its subscriber, even if the unsub is lost with the link.

## Open app (v2, Macro deck)

```jsonc
{"t":"open","app":"Safari"}                       // phone → host: open an app by name
{"t":"openresult","ok":false,"app":"Safari"}      // host → phone: ONLY on failure
```

- **Hello-gated like clip.\*:** the host only services `open` on a connection
  that has completed a v2 `hello` on that same connection — a raw socket must
  not be able to launch apps on the Mac. A pre-v2 host ignores `open`
  entirely (unknown `t` parses to nil), so the phone shows the "update
  Remotype Host" guidance against a legacy verdict instead of sending.
- **Argument-array semantics:** the host spawns `/usr/bin/open` with the
  argument array `["-a", name]` — never a shell, never string interpolation
  into a command line. Quoting and shell metacharacters in the name can only
  ever be part of the literal app name handed to Launch Services.
- **64-char cap:** the host trims whitespace and drops empty or >64-char
  names (the phone's editor enforces the same 1–64 rule).
- **Failure-only reply:** success sends nothing (the launch is
  fire-and-forget, like input events). A spawn error or a non-zero `open`
  exit answers `openresult` with `ok:false` and the app name echoed; the
  phone shows a transient "Couldn't open <name>."
- App names are **less sensitive** than clipboard/now-playing, but an app name
  can occasionally be revealing, so the host shows `open <name>` only in its
  in-memory menu-bar last-event line and writes a content-free `open app`
  marker to the world-readable log file — the name never persists to /tmp.

## Walk-away lock (v2, Proximity auto-lock)

```jsonc
{"t":"prox.arm","tok":"a1b2c3d4e5f6","near":-78,"grace":30}  // phone → host: arm
{"t":"prox.disarm"}                                          // phone → host: disarm
{"t":"prox","state":"inRange","rssi":-61}                     // host → phone: status
```

The host locks the Mac when the phone walks out of range. The phone runs as a
tiny **BLE peripheral** (a "beacon"); the host is the **BLE central** that
scans for it, connects, and watches the connection's signal strength (RSSI)
with hysteresis + a grace timer. This path is **iOS + Mac only** — Android has
no host companion. It is also **device-untestable in CI**; the
RSSI decision logic lives in a pure, unit-tested state machine
(`ProximityEvaluator`) so it can be reviewed without hardware.

- **Hello-gated like clip.\*:** the host only services `prox.arm`/`prox.disarm`
  on a connection that has completed a v2 `hello` on that same connection — a
  raw socket must not be able to arm a screen-lock trigger on the Mac. A pre-v2
  host ignores them (unknown `t` parses to nil), so the phone shows the
  "update Remotype Host" guidance against a legacy verdict instead of sending.
- **`tok` (the rotating session token):** the privacy guard. The phone's BLE
  advertisement carries **only a fixed, public service UUID** — no device name,
  no MAC-stable identifier, nothing a passive sniffer could correlate across
  sessions. The single identifying datum is a **6-byte session token,
  regenerated every time the beacon (re)starts and NEVER advertised** — it is
  only readable by a central that has *connected* and reads the one GATT
  characteristic. `prox.arm` carries that token (lowercase hex) so the host
  arms against the exact value; the host connects, reads the characteristic,
  and only ranges the peripheral whose token **matches** (so it never locks off
  some *other* Remotype phone advertising the same public UUID). The token is a
  per-session secret: it is **never logged or displayed** on either side — the
  host's last-event line and log say only `proximity armed` / `proximity
  <state>`. (`rssi` is a plain number and may be shown on the host; the phone
  never displays it.)
- **`near` (dBm) + `grace` (s):** the phone's Sensitivity (Near −68 / Medium
  −78 / Far −88) and Delay (15/30/60) settings. `near` is the RSSI threshold;
  the smoothed signal staying below it for `grace` seconds (or signal loss
  lasting that long) triggers the lock. The host adds an **8 dB hysteresis
  margin** and **EMA smoothing** on top — three independent false-lock guards
  (smoothing rides out single noisy samples; grace requires *sustained*
  weakness; hysteresis stops flapping at the boundary).
- **`prox` frames (host → phone), emitted on each phase change / poll while
  armed (~1.5 s RSSI cadence):** `state` ∈ `searching` (armed, beacon not yet
  seen) · `inRange` · `leaving` (below threshold, grace counting) · `locked`
  (the Mac was locked). The phone mirrors
  this in its Settings status line; it owns no proximity logic of its own.
- **Persist-across-TCP-blip rule (differs from vitals):** arming is **NOT** torn
  down by a TCP drop — a brief link blip must not silently unlock the walk-away
  guard. The host's monitor keeps running (and keeps locking on walk-away)
  across a dropped connection; it is stopped **only** by `prox.disarm`, a
  replacing `prox.arm`, or the host app quitting. The **beacon likewise keeps
  advertising** the same token across a blip. On reconnect the phone re-sends
  `prox.arm` with the current token (on the `hi`), which harmlessly restarts the
  monitor. **Chosen behavior on client replacement:** when a *new* client
  connection is accepted, any running monitor is **kept** (not stopped) — the
  common case is the same phone reconnecting and re-arming; a different phone
  that hellos but never arms can't read the prior token characteristic
  (mismatch → the monitor just keeps scanning) so it doesn't inherit walk-away
  frames it never asked for.
- **scenePhase does NOT pause this (unlike vitals):** walking away happens
  precisely while the phone is backgrounded, so the beacon keeps advertising and
  the host keeps ranging when the app is not foreground. (Vitals, by contrast,
  unsubscribe the moment the app backgrounds.)
- **Device-validation caveats (open):** (1) whether a
  *backgrounded* iOS app's service-UUID advertisement is reliably received by a
  macOS central — iOS relocates the UUID into the BLE "overflow" area when
  backgrounded; Apple-platform centrals can still match it, but this needs
  real-hardware confirmation. (2) `SACLockScreenImmediate` (login.framework,
  resolved via dlopen/dlsym) is a private, undocumented symbol; its availability
  across macOS versions is unverified. The fallback is `pmset displaysleepnow`,
  which only locks if "require password after sleep" is enabled (the default).

## Spotlight overlay (v2)

Spotlight mode drives a click-through, full-screen overlay on the
host — the presenter's analog of a digital laser, visible to a screen-share
audience.

```jsonc
{"t":"ovl.mode","m":"spotlight","rf":0.12,"dim":68,"col":"3D5BFF"} // phone → host: activate
{"t":"ovl.move","x":0.42,"y":0.71}                                 // phone → host: pointer position
{"t":"ovl.ink","p":"down","x":0.42,"y":0.71}                       // phone → host: annotate stroke (down|move|up)
{"t":"ovl.clear"}                                                  // phone → host: wipe annotations
{"t":"ovl.cursor","x":0.42,"y":0.71}                               // phone → host: move the REAL cursor (aim phase)
{"t":"ovl.mode","m":"off"}                                         // phone → host: hide + reset
```

- **Sub-modes (`m`):** `spotlight` (dim the screen except a circular cutout that
  follows the pointer), `square` (rectangular cutout), `pointer` (a styled dot,
  no dim), `annotate` (freehand ink), `off` (hide + reset). Unknown values are a
  safe no-op on the host (the OverlayController ignores them).
- **Aim-first interaction:** Spotlight's pad has two phases. *Not engaged*, a
  drag sends `ovl.cursor` to move the REAL system cursor (so the presenter aims
  first); a **double-tap engages**, after which drags drive the highlight
  (`ovl.move`/`ovl.ink`) and it persists when the finger lifts. `ovl.cursor`
  warps the cursor via `CGWarpMouseCursorPosition` — no Accessibility, like the
  rest of `ovl.*`.
- **Coordinates:** `x`/`y` (ink/cursor `x`/`y` too) are **normalized 0–1, origin
  TOP-LEFT of the target screen, y downward**. The host maps them to the
  `NSScreen` under the cursor at `ovl.mode` time (single screen for v1, fallback
  `.main`), converting to AppKit's bottom-left space itself. Resolution- and
  display-independent.
- **Params:** `rf` = cutout/dot radius as a **fraction of the screen's shorter
  side** (host clamps 0.02–0.5); `dim` = backdrop dim 0–100 (spotlight/square);
  `col` = 6-hex RGB for the pointer dot / ink. The host applies only the params
  relevant to the active sub-mode.
- **Hello-gated like clip.\*:** the host services `ovl.*` only on a connection
  that has completed a v2 `hello` on that same connection — a raw socket doesn't
  get to draw a full-screen overlay on the Mac. A pre-v2 host ignores `ovl.*`
  entirely (`InputEvent.parse` returns nil → the line is skipped), so the phone
  shows an "update Remotype Host" notice in Spotlight mode against a legacy host.
- **NOT Accessibility-gated** (unlike input injection): an overlay is just a
  window, so it works the moment a v2 client asks, regardless of the
  Accessibility grant.
- **Per-connection + always cleaned up:** the overlay is reset (hidden, ink
  wiped) on `ovl.mode off`, on client replacement, and on every connection
  teardown — a phone that drops or backgrounds never leaves the Mac dimmed. The
  phone sends `ovl.mode off` on leaving Spotlight mode and on backgrounding.
- **`ovl.move`/`ovl.ink` are high-frequency** (~60/s) and deliberately not
  logged per-frame; the host coalesces updates in an action-disabled
  `CATransaction` for smooth, lag-free tracking.

## TV mode (v2, magnified screen feed)

A live, **magnified slice** of the Mac's screen streamed to the phone — a
Windows-Magnifier-style remote monitor. The host crops a SMALL
region around the focus point (the cursor for v1) and scales it to a fixed small
output on the GPU (ScreenCaptureKit `sourceRect`), so only the slice is ever
encoded — the phone never sees a full-screen frame.

```jsonc
{"t":"tv.sub","w":480,"h":300,"z":2,"f":"caret"}  // phone→host: subscribe; w/h = output px, z = magnification, f = follow mode
{"t":"tv.unsub"}                        // phone→host: stop
{"t":"tv.follow","f":"auto"}            // phone→host: what the lens follows ("auto"|"cursor"|"caret"|"full"|"manual"|"off"). "off" freezes the lens where it is and keeps it frozen through pointer moves and typing until a follow mode is picked again; "manual" is the same crop but the host's trackpad path may leave it (macOS re-follows the cursor on the next move).
{"t":"tv.zoom","z":3}                    // phone→host: change magnification live. z <= 0 is the 1:1 DETENT SENTINEL — "the zoom at which one captured pixel is one streamed pixel" — which only the host can compute; it resolves and reports the real number back in tv.state.z with nat:true.
{"t":"tv.pan","dx":-0.01,"dy":0.0}      // phone→host: manual steer (drag the view); dx/dy = normalized display-fraction deltas → enters "manual" follow. Coalesced realtime while dragging.
{"t":"tv.point","x":0.42,"y":0.71,"sq":184}  // phone→host: put the REAL cursor at a point INSIDE THE CURRENT LENS; x/y normalized 0-1 from the lens rect's top-left; s echoes the lens sequence the finger was touching. Coalesced realtime (newest wins), flushed ahead of the click.
{"t":"tv.frame","w":480,"h":300,"sq":184,"d":"<base64-jpeg>"}  // host→phone: one magnified frame; sq = the lens sequence this frame was cropped with
{"t":"tv.state","f":"caret","fr":"caret","z":2.6,"nat":false,"m":1.8,"sq":184,"cx":0.42,"cy":0.66}  // host→phone: the lens's own truth. m = panel pixels per captured pixel (outW / captured width in physical px); the phone samples nearest-neighbour from m >= 2 so magnified text reads as pixels rather than smear.
{"t":"tv.err","err":"noperm"}           // host→phone: can't capture ("noperm" | "unsupported" | "capture")
```

- **v2-gated** like every control event; a pre-v2 host parses neither and the
  phone shows its "update host" notice. Needs the Mac's **Screen Recording**
  grant (distinct from Accessibility — only the screen *pixels* need it; reading
  the cursor/caret/geometry needs nothing). Missing grant → the host answers
  `tv.err noperm` and the phone shows a "grant it on the Mac" empty state rather
  than a frozen blank; macOS < 12.3 → `tv.err unsupported`.
- **Per-connection + always cleaned up:** the capture is pinned to the
  subscribing connection (like vitals/prox), and stopped on `tv.unsub`, client
  replacement, and every teardown path. The phone also unsubscribes on
  backgrounding so a pocketed phone never keeps the Mac capturing (battery).
- **Frames are host→phone**, the OPPOSITE direction from input — TCP is
  full-duplex, so the feed never adds latency to keystrokes/clicks. They are
  "keep-latest, drop-stale": the phone decodes off-main and renders only the
  newest, so a slow link can't build a backlog (same rule as the pointer stream).
  v1 ships base64-JPEG on the existing line; a binary sub-channel is future work.
- **Focus follow:** v1 centers the crop on the cursor (the host already reads
  `CGEvent.location`); caret-follow while typing (via Accessibility) is future
  work and adds no new permission.
- **`tv.state` — the host's own truth, never inferred.** The phone cannot compute
  the effective magnification: the 1:1 detent is *requested* with the `z <= 0`
  sentinel and *resolved* host-side from the display's geometry, `full` ignores
  zoom entirely, and the host changes follow mode behind the phone's back (a
  `tv.pan` enters manual; a trackpad move leaves it). So the host pushes what is
  actually true: `f` the live follow mode, `fr` what "auto" resolved to this
  instant, `z` the REAL effective magnification (always > 0, never the sentinel),
  `nat` whether the detent produced it, `sq` the lens sequence, and `cx`/`cy` the
  cursor in the same normalized lens space as `tv.point`.
  Change-driven — on any change to the lens or the mode, cursor movement capped at
  10 Hz, plus a 1 s heartbeat so a client joining mid-stream converges. It goes out
  on the ordinary control send, NEVER the frame pump, which is newest-wins and
  would let a state push evict a pending frame.
  Following the `vitals` precedent, unavailability is ABSENCE, not a lie: `cx`/`cy`
  are omitted when the cursor is outside the lens or unreadable, and the phone
  hides its cursor puck rather than parking it in a corner.
  **A host that never sends `tv.state` costs the phone nothing** — unknown `t` is
  already a no-op on both sides — and every consumer is written as
  `state?.field ?: <what it did before>`, so absence degrades to today's behaviour
  and never to a wrong lens confidently drawn.

- **Absolute pointing (`tv.point`).** `tv.pan` moves the *view*; `tv.point` moves
  the *cursor*, to the exact place the finger is touching, so a tap clicks where it
  landed instead of somewhere a relative delta happened to arrive. x/y are
  normalized inside the CURRENT LENS RECT — not the display, not the JPEG — so in
  `full` follow the same formula gives true screen-absolute pointing with no
  special case. The host warps (the `ovl.cursor` family: no Accessibility needed
  for the warp itself, though the *click* that follows still is).
  **The lens sequence `s` is what makes it correct while the lens is moving.** In
  cursor/caret follow the lens re-centres on the cursor within one tick, so warping
  the cursor moves the lens under the finger. Every `tv.frame` and `tv.state`
  carries a monotonic `sq`, bumped only when the rect actually changes; the phone
  echoes the `sq` of the frame it was touching, and the host maps against the rect
  from its ring of recent sequences rather than re-deriving one from the cursor it
  is about to move. `tv.point` also pins the lens (manual), which stops the
  feedback loop at the source. An `sq` the host no longer holds falls back to the
  live lens; a point arriving before any lens exists is DROPPED, never warped to
  the origin.
  Realtime-coalesced newest-wins, like `mm`/`sc` but REPLACING rather than
  accumulating — an absolute position summed with another is meaningless. A drag
  emits 60-120 samples/s; on the ungated discrete path those are undroppable and a
  congested link builds an unbounded backlog, so the cursor would lag seconds
  behind the finger.

- **Manual steer (`tv.pan`):** a finger drag in the TV view sends normalized
  display-fraction deltas; the host switches to `manual` follow, captures the
  CURRENT lens centre first (no jump), then shifts it by the accumulated delta and
  clamps to the display. Pinch maps to `tv.zoom`. Re-picking any follow mode exits
  manual. Deltas coalesce (accumulate) on the realtime send path like `mm`/`sc`.

## Host permissions (warning badge + Fix)

The host reports which OS permissions it needs and whether they're granted, so the
phone can show a warning and a one-tap Fix.

```jsonc
// host→phone, on connect + whenever a grant flips + after a Fix:
{"t":"perms","items":[
  {"id":"accessibility","name":"Accessibility","granted":false,"required":true,"fixable":true,"detail":"Lets Remotype type and move the pointer on this Mac."},
  {"id":"screen","name":"Screen Recording","granted":true,"required":false,"fixable":true,"detail":"Needed for TV screen-mirror and computer audio."}
]}
// phone→host, when the user taps Fix on a missing item:
{"t":"perm.fix","id":"accessibility"}
```

- The phone shows a header warning while ANY reported item is `granted:false`, and a
  modal listing each with a **Fix** button (shown when `!granted && fixable`).
- `perm.fix` makes the host open the matching System Settings pane (macOS:
  `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` /
  `…?Privacy_ScreenCapture`) and fire the one-time system prompt, then re-`perms`
  after a beat so the badge clears live once granted.
- **Per-host:** only **macOS** has runtime-grantable gates (Accessibility, Screen
  Recording). Windows input injection needs no permission (sends no `perms` → no
  warning); the Linux host can't start at all without `/dev/uinput`, so once
  connected the permission is necessarily satisfied. Unknown `perm.fix` ids are no-ops.

## Messages

```jsonc
{"t":"hello","v":2,"name":"Pratik’s iPhone"}     // handshake on connect (see above)

// Keyboard — one of `c` (a single character) or `k` (a named key):
{"t":"key","c":"A","mods":8}                     // type 'A' with Cmd → Cmd+Shift+A (Shift inferred from the char)
{"t":"key","k":"left","mods":2}                  // named key Left + Shift (select-left)

// Swipe / bulk typing:
{"t":"text","s":"hello ","del":0}                // backspace `del` times, then type string s

// Held modifiers — the host presses/holds the REAL key (so Cmd+Tab etc. work):
{"t":"mod","b":8,"down":true}                    // press/hold; {"down":false} releases. b = a single mod bit
// Latched (quick-tap) modifiers travel as the `mods` flag on the next event instead.

// Mouse / trackpad (relative):
{"t":"mm","dx":4,"dy":-3,"mods":0}               // relative move (or drag if a button is held)
{"t":"mb","b":0,"down":true,"mods":0}            // button hold/release: b 0=left 1=right 2=middle
{"t":"mc","b":1,"mods":0}                         // discrete click
{"t":"sc","dx":1,"dy":2,"mods":0}                // scroll/pan, both axes (already signed for scroll-direction pref)
{"t":"zoom","d":3}                                // pinch zoom — host synthesizes Cmd+scroll

// Consumer / media:
{"t":"cc","u":"playpause"}                        // u ∈ playpause next prev mute volup voldown brightup brightdown rewind ffwd
```

### Host mapping notes
- `c` (character): host maps char → (virtual keycode, needsShift) on a US layout;
  final flags = `mods` ∪ (Shift if the char needs it). So the app sends the
  *final* character (uppercased / shifted symbol) and only Ctrl/Alt/Cmd in `mods`.
- `k` (named): `tab esc enter backspace fdel space left right up down home end f1..f12`,
  plus the keypad cluster `kp0..kp9 kpdot kpplus kpminus kpmul kpdiv kpenter`
  (Numpad mode). `mods` is applied verbatim (so Shift+Arrow etc. work).
  - `fdel` = **forward-delete** (deletes the character *after* the cursor — the
    Dictate mode mini edit keyboard's ⌦). The macOS host maps it to
    `kVK_ForwardDelete` (117); the Android HID transport uses Keyboard Delete
    Forward usage `0x4C`. An older host that doesn't know `fdel` no-ops it
    safely (table-lookup miss), like every other named-key addition.
- The `kp*` names map to **keypad** virtual keycodes on the host (macOS
  `kVK_ANSI_Keypad*`), not the number row — spreadsheets/accounting software
  see a genuine numpad.
- Named keys keep the platform-neutral wire format; each host companion owns its
  own keycode table (macOS now; Windows/Linux later). A host that doesn't know
  a name treats it as a no-op (table-lookup miss) — so older hosts safely
  ignore newer vocabulary like `kp*`.
- Consumer (`cc`) names work the same way: the host maps them to its media-key
  table (macOS NX media key codes) and unknown names are a no-op on older
  hosts. `rewind` / `ffwd` (Media mode's scrub caps) scan within the current
  track — NX_KEYTYPE_REWIND / NX_KEYTYPE_FAST on macOS.
