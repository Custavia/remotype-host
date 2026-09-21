# Remotype — Screen Casting Specification

> **Status: LOCKED v2.0** (2026-07-03) — implementation-ready. This is the authoritative spec for the "Cast" feature. Companion to [`PROTOCOL.md`](PROTOCOL.md), the phone app's feature list, the phone app's feature list, the presenter-mode design (phone app). **MUST / MUST NOT / SHOULD / MAY** are normative (RFC 2119).
>
> **Owner note:** every design decision in this document is settled and MUST NOT be re-litigated during implementation. §18 now contains only *empirical calibration items* — measured values to fill in during development — not open design questions. If implementation uncovers a genuine contradiction, bring it to the owner; do not invent a resolution.
>
> v2.0 supersedes the v1 draft after a full adversarial review (51 verified findings). Appendix A summarizes what changed and why.

---

## 0. Scope

**In scope.** Casting the **computer's screen + the computer's audio** to a TV / display, with the **phone as the remote control**. The phone is the trigger and the couch/podium remote; it keeps driving the computer (all existing input modes) while the computer is on the big screen.

**Out of scope (explicitly NOT this feature).**
- Casting the **phone's own screen** to a TV. (The OS already does this; undifferentiated. MUST NOT build.)
- Casting **arbitrary media / a URL / a file** (the Chromecast/VLC model). We cast the live desktop, not a media item.
- Making a phone/PC a cast **receiver**.
- Extended-display ("TV as second monitor") — an explicit **non-goal** (owner sign-off, §18-E6). MUST NOT be scoped into any phase.

**North-star ("the magic").** In a room on one Wi-Fi it "just works" with zero config; the Cast affordance only *appears* when a castable target is actually reachable; and it degrades honestly (clear warnings, never a silent spinner) when the network can't deliver. Every failure path in this spec terminates in a named error code with user-facing copy and a next step (§13.8).

---

## 1. Vocabulary & roles

| Term | Meaning |
|---|---|
| **Source / Computer** | The machine whose screen+audio is cast. Runs the **Remotype Host**. |
| **Sink / Target / TV** | The display being cast to (Chromecast, AirPlay TV, Miracast display). A closed appliance. |
| **Controller** | The device that *discovers, selects, starts/stops* the cast. Can be the **phone** or the **host** (§2.1, §4). |
| **Streamer** | The device that *encodes+serves* the screen bytes to the sink. Always the **host**, except in **Bridge** mode where it is the **phone** relaying the host's stream (§7). |
| **Receiver app** | The web app running *on the Cast sink* that plays our stream (our Custom Receiver; the Default Media Receiver only in the dev-only Tier-0 spike). AirPlay/Miracast have no receiver app — the sink's firmware handles it. |
| **Remotype link** | The existing phone↔host TCP/JSON control connection (LAN or Tailscale). Fixed port **50808 on macOS today**; Windows/Linux hosts currently bind ephemeral ports — adopting fixed-port-with-fallback there is prerequisite **P1** (§15) for their remote-path phases. Carries `cast.*`. |
| **Media socket** | A second, binary-framed TCP connection used only for the BRIDGE host→phone H.264/audio leg (§7.4). Never carries control messages. |

**Sink LAN** = the physical L2 network the sink is on. **A device is "on the sink LAN" iff it can open a socket to the sink's IP.** This is the governing fact for **AirPlay and Google Cast** sinks. **Miracast is exempt** — it is Wi-Fi Direct peer-to-peer and has no sink IP before connection (§2.1); its reachability is a *host capability*, not a network location.

---

## 2. Two transport families

Casting is **not one protocol.** It is a union, and we implement both families:

- **Family A — native OS mirror.** The host's own OS mirrors its desktop to the sink using the platform's built-in stack. **Best quality, we write no codec.** Covers the user's office **Samsung TV**.
  - **macOS → AirPlay** (Apple TV + 2018+ Samsung/LG/Sony/Vizio).
  - **Windows → Miracast** (Samsung/most Android-TVs/dongles) — with the hardware caveat in §2.1.
- **Family B — our own stream, our own receiver.** The host encodes once and serves a stream that **a receiver we control** plays. Two receiver kinds:
  - **B-Browser — any web browser** (§2.2). The receiver is a plain web page; the target is *any* device with a modern browser — a laptop, a second computer, a tablet, a smart-TV browser. **No sink discovery, no Cast SDK, no vendor.** This is the widest-reach, cheapest-to-ship Family-B target and ships FIRST (§15).
  - **B-Cast — Google Cast** (Chromecast, Google/Android TV, Nest — **NOT most Samsungs**, which omit Chromecast). Same encoded stream, launched onto the sink via the Cast SDK; device floor + legacy policy in §6.5.

### 2.1 Miracast reality (normative — this is NOT a LAN protocol)

Standard Miracast — which is what Samsung TVs implement as "Smart View" — is **Wi-Fi Direct peer-to-peer**: the sink is discovered via Wi-Fi Direct probes, **has no IP address on any LAN before connection**, and the stream never touches the infrastructure network. Consequences, all normative:

- The **Windows sender MUST have a Wi-Fi adapter + driver supporting Wi-Fi Direct**. An Ethernet-only desktop **has no Miracast at all** (Windows reports "This device doesn't support Miracast"; Win+K shows nothing). The host MUST detect this (§9.3) and MUST NOT advertise Miracast targets from such a machine; the phone surfaces the §13.8 `unsupported` copy if the user asks why.
- Miracast targets are **exempt from the §3 sink-LAN rule and the §4 Step-2 probe**. Their `cast.targets` entries omit `addr`/`port` (§5.4). "Reachable" for Miracast means: the host's adapter supports Wi-Fi Direct **and** the OS's wireless-display enumeration currently lists the sink.
- **Miracast-over-Infrastructure (MS-MICE) is NOT assumed.** It still requires Wi-Fi enabled on the sender for the Wi-Fi Direct discovery phase, and consumer Samsung TVs are not established MS-MICE receivers. Treat every Miracast session as pure Wi-Fi Direct; if MS-MICE happens to engage, it's a transparent bonus.

### 2.2 The Browser receiver (normative — a receiver we fully control)

The rest of this spec is organized around **discovering closed sink appliances** (§1 defines a sink as "a closed appliance"). The browser is the opposite: **a receiver we own, that the user *pairs* rather than the phone *discovers*.** Three consequences that make it the best first target:

- **It is a virtual, always-available target — not discovered.** There is no mDNS browse, no reachability probe, no progressive-disclosure gating. Whenever the phone is connected to a **browser-capable host**, the "Cast to a browser / another screen" affordance is offered unconditionally (it works in an empty room, anywhere the phone reaches the host — the sink-LAN rule §3 only constrains where the *viewing browser* must be, per the reach row below).
- **It reuses the codec we already ship.** The on-device TV mode already produces **motion-JPEG**. A browser renders MJPEG over plain HTTP with **no WebRTC, no HTTPS/secure-context requirement, no cloud signaling, no codec license, no vendor SDK** — so Family-B-Browser ships on the *existing* pipeline. WebRTC is a later **latency upgrade** (tiers in §6.5), not a prerequisite.
- **Reach (normative):** for Tier B0 the *viewing browser* MUST be able to open a socket to the **host's** LAN address (it is on the host's LAN, exactly like a sink). Casting to a browser on a *remote* network is the WebRTC + hosted-receiver + cloud-signaling tier (B1) and is out of scope for the first ship.

**Reach & who-can-do-what (normative):**

| | Discover | Control | Stream |
|---|---|---|---|
| **AirPlay sink** | phone *and* host (mDNS `_airplay._tcp`) | **host only** (OS mirror is not app-startable from a phone) | host, native |
| **Miracast sink** | host (Windows wireless-display enumeration) | **host only** | host, native (Wi-Fi Direct) |
| **Cast sink** | phone (Cast SDK) *and* host (CASTv2 client) | **phone or host** | host-direct **or** phone-bridge (§7) |
| **Browser** | *none — virtual target, always offered when host-capable* | **phone triggers, host serves** | host, HTTP/MJPEG (B0) → WebRTC (B1) |

> Consequence baked into the whole design: **AirPlay & Miracast are always host-controlled + host-native-streamed** (the phone can only *trigger* the host). **Cast** admits a phone controller or a phone bridge. **Browser** is host-served and phone-triggered — the phone shows the pairing URL/QR and never enters the media path.

---

## 3. Network topology & the one hard rule

**HARD RULE (Family B + AirPlay):** the **Streamer and the Sink MUST be on the same LAN.** A sink is a closed appliance with no VPN client, and mDNS does not traverse Tailscale. **No VPN can put a TV on the tunnel.** Tailscale's *only* role in casting is extending the phone↔host **control** link. (Miracast is exempt per §2.1 — its "locality" is Wi-Fi Direct radio range + adapter capability.)

Three legal scenarios (derive everything from which device is on the sink LAN):

| Scenario | Host on sink LAN? | Phone on sink LAN? | Path | Notes |
|---|---|---|---|---|
| **Same-room** | ✅ | ✅ | **Direct** (host streams) | phone free to leave after start |
| **Remote-trigger** | ✅ | ❌ (Tailscale) | **Remote-trigger** (host streams, host controls) | "start my office setup from the road" — Cast, previously-paired AirPlay (§7.1), and Miracast (§2.1: host capability; phone location irrelevant) |
| **Bridge** | ❌ (Tailscale) | ✅ | **Bridge** (phone relays host stream to local sink) | "my remote PC on the TV in front of me" — Cast only |
| *(illegal)* | ❌ | ❌ | **impossible** | nobody on the sink LAN; surface `cast.err unreachable` |

AirPlay exists **only** in the Same-room / Remote-trigger rows (host must be on the sink LAN). Miracast exists in Same-room and Remote-trigger rows subject to §2.1 (Wi-Fi Direct range is inherently "same room" for the *host*; the phone's location is irrelevant). Neither has a bridge (the phone can't be an AirPlay/Miracast *screen sender*).

**Remote-trigger onto a locked/asleep host is expected, not an error**: the session starts in `PAUSED(locked)` with an idle card on the TV (§10.4).

---

## 4. THE ROUTING MATRIX (the brains)

When the user taps a target, the system MUST resolve `(controller, streamer, path)` **deterministically** by this procedure. No ad-hoc logic elsewhere.

**Step 1 — infer locations from discovery source** (who *saw* the sink ⇒ who is on its LAN):
- phone-discovered ⇒ `phoneOnSinkLan = true` (candidate).
- host-discovered ⇒ `hostOnSinkLan = true` (candidate).
- both ⇒ both true (candidates).
- Miracast targets skip Steps 1–2 entirely (§2.1): they are host-capability targets.

**Step 2 — reachability probe (confirm, never assume).** Discovery ≠ reachability (guest VLAN, client isolation, iOS AWDL/peer-to-peer results that aren't infrastructure-LAN). Before committing:

| Sink type | Probe | Port | Success criterion | Timeout |
|---|---|---|---|---|
| Cast | plain TCP connect | mDNS SRV-advertised (`8009` default) | TCP handshake completes (no TLS/protocol exchange needed) | 1 500 ms |
| AirPlay | plain TCP connect | mDNS SRV-advertised (`7000` default) | TCP handshake completes | 1 500 ms |
| Miracast | *(none — capability check per §2.1)* | — | — | — |

- Probes MUST target the port from the sink's mDNS SRV record (the §5.4 target object's `port`), falling back to the well-known default only when discovery supplied none.
- If `phoneOnSinkLan` candidate: the **phone** opens the probe.
- If `hostOnSinkLan` candidate: phone sends `cast.reach {addr,port,rid}`; host probes and replies `cast.reach.res {rid,ok}` (host-side timeout 1 500 ms; phone gives up on the *message* after 3 s and treats it as failure).
- Probes for both candidates run **in parallel**. A candidate that fails its probe is treated as **not** on the sink LAN.
- Probe results are **cached for 30 s** per (device, sink) pair. The phone SHOULD pre-fire the probe for the remembered last-used target when the picker opens or the one-tap entry point is shown (§13.3), so tap→STARTING is near-instant.

**Step 3 — resolve by target type:**

```
if target.type == miracast:
    require host reports miracast capability      # else -> cast.err unsupported
    controller = HOST                             # native OS mirror, host-triggered
    streamer   = HOST (native, Wi-Fi Direct)
    path       = NATIVE

elif target.type == airplay:
    require hostOnSinkLan                         # else -> cast.err unreachable
    controller = HOST
    streamer   = HOST (native)
    path       = NATIVE

elif target.type == cast:
    if hostOnSinkLan and phoneOnSinkLan:
        controller = PHONE           # official Cast SDK (LOCKED; was §18-Q1)
        streamer   = HOST (direct)   # phone NOT in media path -> phone may leave
        path       = DIRECT
    elif hostOnSinkLan and not phoneOnSinkLan:
        controller = HOST            # host CASTv2 client; phone just triggered
        streamer   = HOST (direct)
        path       = REMOTE_TRIGGER
    elif phoneOnSinkLan and not hostOnSinkLan:
        controller = PHONE           # Cast SDK
        streamer   = PHONE (bridge)  # relays host's H.264 over media socket -> local sink
        path       = BRIDGE
    else:
        -> cast.err unreachable
```

**Preference override:** the "Cast controller = Force host" preference (§12) forces `controller = HOST` for **Cast targets in the DIRECT case only** (both on sink LAN). It has no effect on REMOTE_TRIGGER (already host) or BRIDGE (host *cannot* control — the preference is silently inapplicable there, and the Settings row says so: "applies when your computer can reach the TV"). If the host's own probe of the target fails while the phone's succeeded, the override is ignored for that session and the phone controls (this is the only "fallback"; it never applies in any other direction).

**Target identity authority:** for host-controlled paths, the host resolves the sink by `target.id` against **its own** discovery cache; the `addr`/`port` in `cast.start` are advisory and used only if the host has no record (possible when the phone discovered a sink the host's browse missed — in that case the host MUST re-probe before connecting).

---

## 5. Discovery (federated, deduped, progressive)

### 5.1 Sources

The picker merges two live sources:
1. **Phone-side:** Google Cast SDK (`_googlecast._tcp`) + AirPlay Bonjour browse (`_airplay._tcp`, display-only) on the phone's LAN.
2. **Host-side:** host browses its LAN and streams the list over the Remotype link (`cast.scan.sub` → repeated `cast.targets`), covering Cast + AirPlay + **Miracast** (which the phone cannot see). This is all-new host code: the Mac host adds an `NWBrowser`; the Go hosts already vendor a zeroconf library that supports browsing; Windows additionally enumerates wireless displays via the OS.

**Platform gating (normative):**
- **Android:** the Cast-SDK source requires Google Play services. On GMS-less devices (de-Googled/AOSP — where BT-HID currently works) the phone-side Cast source is silently absent; host-side discovery still populates the picker. The Cast entry point therefore still works on such devices for host-reachable sinks. Never crash or nag about GMS.
- **iOS:** `Info.plist` gains `NSBonjourServices` entries `_googlecast._tcp`, `_<CAST-APP-ID>._googlecast._tcp`, `_airplay._tcp`, and the `NSLocalNetworkUsageDescription` copy is updated to mention finding TVs (current copy mentions only keyboard/trackpad — misleading in a cast context). **No new runtime prompt results**: the local-network permission was already granted for `_hsbtk._tcp` host discovery; iOS prompts once per app. Cast SDK guest mode is gone as of 2026 SDK versions, so **no Bluetooth permission is involved**.

### 5.2 Scan lifecycle (normative)

- **Ambient browse** (drives entry-point visibility): runs while the app is **foregrounded AND a host link is connected**, at the SDK/OS default duty cycle. Never in background. The host-side scan subscription (`cast.scan.sub`) follows the same lifecycle: subscribe on foreground+link, unsubscribe on background.
- **Active scan** (full-rate): only while the picker or Settings → Casting is open.
- **Entry-point hysteresis:** the Cast affordance appears within 1 s of the first confirmed target and disappears only after the *last* target has been absent for **10 s** (mDNS flapping MUST NOT flicker the button). Inside an open picker, a vanished row grays out ("not seen — checking…") for the same 10 s before removal.

### 5.3 Dedup (normative)

A sink reachable by both sides appears once. Dedup key priority: (a) Cast `deviceId` / AirPlay `deviceid` (TXT record), else (b) normalized `IP` + service-type. On merge, retain **both** location flags (drives Step-1 inference). Stale entries evict on mDNS goodbye/TTL + the 10 s hysteresis. A sink whose IP changed but whose `deviceId` matches is the same sink (update `addr`, keep identity + remembered-sink status per §14.3).

### 5.4 Target object (host→phone `cast.targets` element)

```json
{ "id":"stable-id", "name":"Living Room TV", "type":"cast|airplay|miracast",
  "addr":"192.168.1.50", "port":8009, "model":"Chromecast|…",
  "deviceId":"<cast/airplay device id if known>", "seenBy":"host" }
```
`addr`/`port` are **absent for `miracast`** (§2.1). `cast.targets` is a **full snapshot** (not a delta), resent whenever the host's view changes. A host-seen target inside its §5.2 disappearance window carries `"stale":true` (phones render it grayed **and disabled**); **phones MUST NOT re-apply their own disappearance hysteresis to host-seen entries** — the host already applied §5.2, and stacking the two doubles the specced 10 s. The phone tags its own discoveries `"seenBy":"phone"` and merges.

**Audio-only Cast devices are not targets.** Speakers, screenless hubs, and cast *groups* answer `_googlecast._tcp` but cannot show a screen — every discovery source (host and phone) MUST exclude devices whose Cast TXT `ca` capability bitmask lacks the video-out bit (bit 0), and group entries. Likewise a computer is never its own sink: each side excludes the local machine's / connected host's own AirPlay advertisement by name.

### 5.5 Progressive disclosure (the magic) — with a permanent doorway

The Cast entry point (button/row) **MUST be hidden entirely** until `mergedTargets.length ≥ 1` (subject to §5.2 hysteresis). No dead "Cast" button in an empty room.

Because a hidden button on a broken network is a silently deleted feature, there MUST also be a **permanent doorway**: **Settings → Casting** (§12) is always visible and contains a live "Nearby TVs" list (active scan while open) plus a "Why can't I see my TV?" expander covering: same-Wi-Fi requirement, guest-network/VLAN isolation, "your computer must be on the TV's network for AirPlay", "Miracast needs Wi-Fi on the PC", and the TV-side AirPlay-off gotcha (§13.8, `nomirror` row).

---

## 6. Streaming pipeline

**Principle: keep mJPEG for the phone, add H.264 only for casting. Throw nothing away.**

### 6.1 Capture (new configuration, shared machinery)

- **Default (no cast):** on-device TV mode stays **motion-JPEG** — loss-tolerant, robust over lossy Tailscale, already shipped. Untouched.
- **The cast capture is a NEW `SCStream` configuration, not a reuse of TV mode's.** Today's TV mode renders into a small ~360×480 output — usually a magnified **crop** with zoom/caret-follow/pan (its whole-display mode is still downscaled into that same output). A cast is a **full-display mirror at native resolution** (scaled to the encode rung, §6.4). The capture *machinery* (ScreenCaptureKit, permission plumbing) is shared; the configuration is not.
- **While a cast session is active, the host suspends the mJPEG `tv.*` stream** and the phone's TV panel is replaced by the cast status card (§13.6). The magnifier semantics (zoom/follow/pan) are meaningless against a mirror feed; they are hidden during a cast and restored on teardown. **There is no live phone-side video view during a cast in v1/v1.5/v2** — this is a decision, not an accident. (A decoded-thumbnail view is a possible v3 nicety; neither client has any H.264 decode surface today, and building one is not justified for a status card.)
- The `aud.*` computer-audio monitor MAY continue to the phone during a cast (the tap is independent of local output and of the cast mux).
- **Host overlay windows (`ovl.*`, the presenter-mode design) MUST be included in the cast capture.** Phone-driven spotlight/annotation appearing on the TV is a flagship behavior (§13.7); if the cast SCStream ever uses window exclusions (e.g. to hide host UI), the overlay window MUST be explicitly exempted from exclusion.
- **Which display (multi-monitor):** default = the display under the cursor at `cast.start`, else the main display (matches TV-mode convention). `cast.start` MAY carry a `display` id. While casting, `cast.ready`/`cast.state` carry the host's display list; if >1, the phone shows a display switcher which sends `cast.display {sid,id}` — the host re-points the capture **without tearing down the session** (encoder flushes with an IDR frame). Audio capture follows the same selected display's `SCContentFilter`.
- **Display-config changes mid-cast** (hotplug, resolution change): the host handles the reconfiguration callback by re-initializing capture on the same display id if still present, else the main display, emits an IDR frame, and sends `cast.notice {code:"display_changed"}`. Never terminal.

### 6.2 Audio — and the double-audio rule

- The computer audio is captured via the existing ScreenCaptureKit audio tap (48 kHz; the cast path taps **stereo before** the phone-monitor mono downmix) and encoded as **Opus 96 kbps stereo** for WebRTC (AAC-LC for the dev-only HLS spike), muxed/synced with video.
- **Local-speaker rule (normative — this protects the aha moment):** during a **Family-B** cast with audio, the host MUST mute the computer's local audio output on session start and restore the prior volume on **every** teardown path (§10.6). Otherwise the room hears the Mac's speakers plus the TV ~150–300 ms later — an echo at the exact first-impression moment. The SCK tap is independent of output volume, so the stream is unaffected. Controlled by the §12 "Mute computer speakers while casting" pref (default On). **Family A needs no handling** — the OS routes audio to the sink itself.
- Casting with audio no longer claims any iOS background entitlement — see §11.2.

### 6.3 A/V clock discipline

Video and audio timestamps MUST derive from a single monotonic capture clock (mach_absolute_time on macOS), carried as RTP timestamps; WebRTC's built-in lip-sync then holds. Requirement: A/V skew ≤ 80 ms sustained over a multi-hour cast (test axis in §16).

### 6.4 Encoder & adaptive bitrate (normative — "Auto" is a ladder, not a preset)

H.264 (VideoToolbox on macOS; Media Foundation on Windows when Family-B lands there, §15). The encoder MUST implement **congestion-driven adaptation** wired to WebRTC bandwidth estimation (transport-cc/REMB):

| Rung | Resolution | fps | Target bitrate |
|---|---|---|---|
| R5 (top) | 1080p | 30 | 6 Mbps |
| R4 | 1080p | 24 | 4 Mbps |
| R3 | 720p | 30 | 3 Mbps |
| R2 | 720p | 24 | 2 Mbps |
| R1 | 540p | 24 | 1.2 Mbps |
| R0 (floor) | 360p | 15 | 600 kbps |

- **Auto** = full ladder. **Low-latency** = fps floor at 24 (sacrifice resolution first). **High-quality** = resolution floor at 1080p (sacrifice fps first).
- Keyframe (IDR) interval: 2 s on DIRECT/REMOTE_TRIGGER; **1 s + FEC/RTP-retransmit on the BRIDGE host→phone leg** (H.264 P-frames mean one lost packet corrupts until the next keyframe; lossy Tailscale makes this a real requirement, not a nice-to-have; parameters are calibration item §18-E5).
- Sitting at R0 for **>10 s** ⇒ `cast.err net_too_slow` (applies on **any** path, not just bridge — same-LAN 2.4 GHz congestion is the common case). Current rung is reported in `cast.status.rung` so the §13 status chip can show "reduced quality" (`cast.notice {code:"quality_reduced"}` on first downshift below R3).

### 6.5 Delivery tiers & the device floor

**Browser receiver tiers (§2.2) — these ship first:**

- **Tier B0 — MJPEG over LAN HTTP (the first Family-B ship; §15).** The host runs a small HTTP server on its sink-reachable LAN interface (§6.7) and serves, at a per-session token path, (a) the receiver page and (b) a `multipart/x-mixed-replace` MJPEG stream of the **full-display** capture (§6.1). The browser renders it in an `<img>`/`<canvas>`; **no WebRTC, no HTTPS, no secure context, no cloud, no vendor SDK** — because `<img>`-MJPEG and `ws://`-on-LAN have no secure-context requirement (unlike `RTCPeerConnection`). Reuses the existing SCK capture + `CIContext` JPEG encoder (the only new server code is the HTTP framing). Frame pacing/quality obey §6.4 (`quality` pref maps MJPEG fps + JPEG-Q, not the H.264 rung). **Audio:** video-first for the initial ship; computer audio streams as a parallel PCM-over-WebSocket track fed to WebAudio (§6.2), gated by the include-audio pref — deliverable but MAY land a beat after video. Latency target ≤ 400 ms same-LAN. This is *not* the dead Tier-0 HLS spike — MJPEG is same-origin (host serves its own page), low-latency, and our proven codec.
- **Tier B1 — WebRTC to a hosted browser receiver (latency + remote reach; later).** The receiver becomes the hosted HTTPS page (below) opened by a **pairing code** brokered through a small cloud signaling rendezvous; media is H.264/Opus WebRTC peer-to-peer host↔browser (so an HTTPS page can still reach a LAN host — media isn't mixed-content). Unlocks casting to a browser on a *remote* network and sub-300 ms latency. Requires the encoder ladder (§6.4) + a signaling service; **NOT needed for the first ship.**

**Google Cast receiver tiers:**

- **Tier 0 — HLS spike (dev-only; MUST NOT ship to users).** Host serves live HLS; controller `LOAD`s the `.m3u8` into the Default Media Receiver (`CC1AD845`). Exists behind a debug flag purely to validate capture→encode→mux before the receiver app exists. Latency 5–15 s. Modern Cast firmware increasingly blocks plain-HTTP media (mixed content); if it's blocked on the test device, **skip the spike entirely and validate on Tier 1** — nothing user-facing depends on it (this closes the v1 draft's open HLS/mixed-content question: it cannot matter). If built, the spike's HLS server MUST send `Access-Control-Allow-Origin: *` on the playlist and segments — receiver fetches are cross-origin. *(Superseded as a validation vehicle by Tier B0, which both validates the capture pipeline AND ships.)*
- **Tier 1 — WebRTC + Custom Receiver (the shipping path).** Our Custom Receiver web app (hosted at `https://custavia.com/remotype/cast-receiver/`, App ID from the $5 Cast console) opens a WebRTC peer connection to the Streamer and plays the track via a raw `<video>` element + `RTCPeerConnection`. **Note:** this bypasses CAF's `cast-media-player`/media-pipeline entirely — Cast `LOAD`/media-status semantics do **not** apply; all transport control rides our custom namespace + DataChannel (§6.6). Media is peer-to-peer → not mixed-content-blocked. Target **<300 ms** on the supported floor.
- **Supported device floor (normative):** Tier 1 is supported on **Chromecast with Google TV, Google TV Streamer, Nest Hub / Hub Max**. (Chromecast with Google TV and Nest smart displays are the classes Google's CameraStream docs name as WebRTC-capable; the Google TV Streamer is a newer, more powerful successor — expected-capable, confirm at Tier-1 bring-up. WebRTC in a custom Web Receiver is not an officially documented Cast feature — it works because the receiver runs a Chromium-based browser — so each supported class MUST be empirically validated per §16.) **Legacy Chromecast gen 1–3/Ultra** (discontinued, frozen firmware) are **best-effort**: entry rung capped at R3 (720p30), no latency promise, and `codec`/`unsupported` failures degrade gracefully with honest copy ("this older Chromecast may not keep up"). §16 tests the two classes as separate rows.

### 6.6 Signaling (normative — the phone must be droppable)

- **Bootstrap signaling is relayed by the Controller, never fetched by the receiver directly** (an HTTPS receiver fetching from an HTTP LAN host would be mixed-content-blocked). Flow: `Receiver ⇄ (Cast custom namespace) ⇄ Controller ⇄ (Remotype link, cast.sig) ⇄ Streamer`. Only the SDP offer/answer + ICE candidates cross this bridge — never per-frame data.
- **After the peer connection is up, ALL subsequent signaling MUST move to a WebRTC DataChannel** (`rtctl`) between Receiver and Streamer: renegotiation, ICE restarts, quality/rung changes, keepalive, stats. The Cast-namespace relay is bootstrap-only. Without this, DIRECT's "phone may leave" is a lie — the first ICE restart after the phone backgrounds would kill the cast with no recovery path.
- **Additionally, in DIRECT and REMOTE_TRIGGER the host MUST maintain its own CASTv2 sender connection to the sink** (it needs that client for REMOTE_TRIGGER anyway, §9.2): this provides receiver-liveness heartbeat (§10.5), sink-volume relay (`cast.volume`, §8.6), and a phone-independent stop path.
- Every signaling message is authenticated by the per-session token (§14.2).

### 6.7 Host LAN-IP selection & server binding (normative)

The host currently binds wildcard and never enumerates interfaces — this is **new code**: enumerate interfaces, **exclude** `utun*`/Tailscale/loopback/link-local/VPN ranges; among remaining candidates prefer the one on the sink's subnet. The WebRTC ICE candidates the host advertises MUST be filtered to this set, and the (spike-only) HLS server MUST **bind to that specific interface, not wildcard**. The main Remotype-link listener keeps binding wildcard (Tailscale connect-by-IP depends on it) — only cast media/serving is interface-restricted.

The **Tier-B0 browser HTTP server (§6.5) uses this same chosen LAN address** — it is the `addr` embedded in the `cast.ready` `url`/QR, so the phone shows the user a URL the *viewing browser* can actually reach. If no non-VPN LAN interface exists (host only on Tailscale), browser B0 `cast.start` fails `unreachable` with copy "Your computer isn't on a local network a browser can reach — connect it to Wi-Fi/Ethernet."

---

## 7. Path mechanics (exact, per path)

### 7.0 BROWSER (host serves MJPEG/WebRTC to any browser — the first Family-B ship)

Phone sends `cast.start {target.type:"browser", path:"browser"}` (no addr/port — it's virtual). Host: pick the LAN address (§6.7) → start the **full-display** capture (§6.1) → start the token-scoped HTTP server (§6.5 Tier B0) → answer `cast.ready {url, code, token}` within 2 s. The phone renders the URL as a **QR code + tappable link + the short pairing code** (§13.6-browser) and the session sits in `waiting_viewer` until a browser opens the URL; then `casting {viewers:N}`. **The phone is never in the media path** ⇒ it MAY background/leave; the browser keeps rendering. Multiple browsers MAY view the same URL. `cast.stop` (or the menu-bar Stop, or link-independent teardown) closes the server, invalidates the token, and every open browser shows "Cast ended". Because this needs no sink, no discovery, and no vendor SDK, it is the **v1.5 first Family-B deliverable** (§15) and the validation vehicle for the whole capture→serve pipeline.

### 7.1 NATIVE (AirPlay/Miracast)

Host triggers its OS mirror to `target`. No Remotype stream. Trigger mechanics + PIN flow in §9.2/§9.3; success detection + externally-stopped detection in §10.5.
- Remote-trigger NATIVE is **allowed but honest**: AirPlay first-connect requires reading a PIN **off the TV screen** (§9.2), which a remote user cannot do. Remote **AirPlay** therefore works only for sinks previously paired same-room (TV set to "First Time Only"); Miracast has no pairing constraint (§2.1). `cast.start` for an unpaired sink from a remote phone fails fast with copy: "First AirPlay connection must be done near the TV."

### 7.2 DIRECT (Cast, host streams)

Host: start H.264 encode → serve WebRTC. Phone `LAUNCH`es the receiver with the session token in `customData`, relays bootstrap signaling via `cast.sig`, then hands off to the DataChannel (§6.6). Host holds its own CASTv2 connection for heartbeat/stop/volume. **Phone is not in the media path** ⇒ phone MAY background/leave; cast continues and survives ICE restarts without the phone.

### 7.3 REMOTE_TRIGGER (Cast, host controls)

Same as DIRECT but the **host** performs LAUNCH + namespace signaling over its CASTv2 connection (no phone on the sink LAN). Phone only sent `cast.start` and receives status over the (Tailscale) Remotype link.

### 7.4 BRIDGE (Cast, phone relays) — v2

Host encodes H.264/Opus and sends it to the phone over a dedicated **media socket** — a second TCP connection the phone opens to the host on the port given in `cast.ready.stream.mediaPort` — **not** the JSON control link. Framing: length-prefixed binary frames `{u32 len, u8 kind(video|audio), u64 pts_us, payload}`. Rationale (locked): base64-in-JSON on the shared control socket would add ~33 % overhead and head-of-line-block input/clipboard behind video bytes.
- The host→phone leg MUST apply the repo's realtime-send backpressure discipline (one-in-flight, newest-wins, keyframe-aware dropping) — never fire-and-forget.
- The phone runs the local WebRTC endpoint on the sink LAN, `LAUNCH`es the receiver, and re-serves the relayed stream (re-packetization only — the phone never decodes). **LL-HLS is removed as a bridge option**: the receiver fetching HTTP segments from a phone is mixed-content-dead by §6.6's own logic; WebRTC is the only bridge transport.
- **Phone is in the media path** ⇒ backgrounding rules §11 apply; battery/heat warning §13.4.
- **Phone network change mid-bridge:** if the phone leaves the sink's LAN (roams to another AP/network), the receiver leg dies — surface as `sink_lost` with the copy "You left the TV's Wi-Fi — casting stopped." If only the *host* leg moves to a metered path (cellular Tailscale), show a persistent "Using cellular data for casting" banner with a Stop action — never silently burn data (§12's warning pref covers the pre-start case; this covers mid-session).
- **Phone thermal rule:** at OS-reported *serious* thermal state the phone sends `cast.quality` with `maxRung:"R2"` (§8.6) to cap the ladder; at *critical* it stops the cast with honest copy ("Your phone got too hot to keep casting.").

---

## 8. The `cast.*` wire protocol (over the Remotype link)

Compact JSON, one object per line, `t` = type. Unknown `t` = safe no-op both directions (forward-compatible), per PROTOCOL.md.

### 8.1 Capability & the no-silent-spinner contract (normative)

- The host's `hi` gains a cast capability field: `{"t":"hi","v":2,"cast":1}` (`cast` = cast-protocol version; this spec is `1`). **Absence of the field = host predates casting**: the phone MUST hide every host-dependent cast affordance (host-side scan, NATIVE targets, REMOTE_TRIGGER, BRIDGE) and, if the user reaches a host-dependent action anyway, show the existing "update Remotype Host" guidance. Phone-side-only DIRECT is **not** attempted either (the streamer is the host). Old host ⇒ no casting, said plainly.
- `cast.start` carries a client-generated `rid`. The host MUST answer within **2 s** with either `cast.status {state:"starting", rid, sid, stage}` or `cast.err {rid, …}`. The phone arms a **3 s** timeout; on expiry it fails the attempt with the update-host/unreachable copy. A late response bearing a stale `rid` MUST NOT resolve a newer attempt (same pattern as the `clip.get` id).
- `cast.scan.sub` is acknowledged by the first `cast.targets` snapshot (possibly empty `items:[]`) within 2 s — an empty room answers with an empty list, never silence.

### 8.2 Discovery

```json
phone→host  {"t":"cast.scan.sub"}
host→phone  {"t":"cast.targets","items":[ {target-obj §5.4} , … ]}     // full snapshot, resent on change
phone→host  {"t":"cast.scan.unsub"}
```

### 8.3 Reachability probe

```json
phone→host  {"t":"cast.reach","addr":"192.168.1.50","port":8009,"rid":"r1"}
host→phone  {"t":"cast.reach.res","rid":"r1","ok":true}
```

### 8.4 Session start / ready / state

```json
phone→host  {"t":"cast.start","rid":"q1",
             "target":{"id":"…","type":"cast|airplay|miracast|browser","addr":"…","port":0},
             "path":"native|direct|remote_trigger|bridge|browser",
             "audio":true, "quality":"auto|low_latency|high_quality",
             "display":"<display-id, optional>"}

host→phone  {"t":"cast.ready","sid":"s1","rid":"q1","path":"…",
             "token":"<base64url 256-bit>",
             "displays":[{"id":"69734","name":"Built-in Display","primary":true}],
             "stream":{"kind":"webrtc|hls|native|browser",
                       "url":"http://192.168.1.20:50809/c/<token>",  // browser (B0) + hls spike: the page/stream URL
                       "code":"7431",                // browser: short human pairing code (also encoded in url + QR)
                       "mediaPort":50811,            // bridge only: host media socket
                       "sigChannel":"cast.sig"}}     // webrtc: bootstrap relay
```

`cast.ready` per **path**: **BROWSER** → `token`+`url` (the LAN receiver URL the phone renders as a tappable link **and a QR code**) + `code` (a short human-typable pairing code for TV browsers where scanning is awkward); the phone is NOT in the media path. **DIRECT** → `token`+`sigChannel` (phone relays bootstrap signaling); **BRIDGE** → `token`+`mediaPort`, no `sigChannel` (the receiver signals the phone directly over the Cast namespace — no Remotype-link relay leg exists); **REMOTE_TRIGGER** → informational only (host self-signals; the phone uses neither `token` nor `sigChannel`); **NATIVE** → `token` omitted (there is no Remotype stream); `hls` spike → `token`+`url` (token embedded in the URL path).

**Browser session lifecycle (normative):** `browser` `cast.start` is answered ≤2 s with `cast.ready` (URL/code ready **before** any viewer connects — the phone shows the QR immediately). `cast.status` stays `state:"starting", stage:"waiting_viewer"` until the first browser fetches the stream, then flips to `casting` with a `viewers` count; drops to `starting/waiting_viewer` when the last viewer leaves (a cast with no viewer is not an error — the URL stays live). `viewers>1` is allowed (multiple browsers, same URL). The host MUST bind the server to the sink-reachable LAN interface only and embed the per-session `token` in every path (§14.2); teardown invalidates the token and closes the server (§10.6).

**Session snapshot (re-attach, normative):** while any session exists, the host MUST push
```json
host→phone  {"t":"cast.state","sid":"s1","state":"casting","path":"direct",
             "target":{"id":"…","name":"Living Room TV","type":"cast"},
             "display":"69734",
             "displays":[{"id":"69734","name":"Built-in Display","primary":true}],
             "startedAt":1751500000,"audio":true,"quality":"auto"}
```
**unsolicited, immediately after every completed hello** — a reconnecting or freshly connecting phone restores the casting bar from it (the walk-away re-arm-on-hi pattern *inverted*: there the **phone** re-sends `prox.arm` when it receives `hi`; here the **host** pushes state after the hello — new host code, no existing host-push precedent). Any hello-completed connection MAY control the session (send `cast.stop`, `cast.quality`, …) — single-user product; the control-plane trust boundary is stated honestly in §14.5.

### 8.5 WebRTC signaling relay (bootstrap only, token-authenticated)

```json
both  {"t":"cast.sig","sid":"s1","token":"…","kind":"offer|answer|ice","data":{…SDP/ICE…}}
```

### 8.6 In-session control

```json
phone→host  {"t":"cast.quality","sid":"s1","quality":"auto|low_latency|high_quality",
             "maxRung":"R2"}                                                             // maxRung optional (bridge thermal cap, §7.4); applies without renegotiation where possible
phone→host  {"t":"cast.volume","sid":"s1","level":0.65}                                  // sink volume 0.0–1.0; host relays via CASTv2 SET_VOLUME on host-controlled paths (§6.6). When the phone is the controller it sets volume via the Cast SDK directly and never sends this
phone→host  {"t":"cast.display","sid":"s1","id":"<display-id>"}                          // §6.1; IDR on switch
phone→host  {"t":"cast.pin","sid":"s1","code":"1234"}                                    // AirPlay PIN, §9.2
phone→host  {"t":"cast.stop","sid":"s1"}
```

### 8.7 Status, notices, errors

```json
host→phone  {"t":"cast.status","sid":"s1","rid":"q1",
             "state":"starting|casting|paused|stopped|error",                                 // rid present only on the first status answering a cast.start (§8.1)
             "stage":"resolving|probing|launching|waking|pin_required|connecting|buffering|guided|waiting_viewer",  // while starting
             "reason":"locked|link_lost|sink_lost|user|background",                            // while paused/stopped
             "fps":30,"kbps":6000,"latencyMs":180,"rung":"R5","viewers":1,
             "target":"Living Room TV","display":"69734","err":null}     // ~1 s while active; NATIVE sends state/target only; BROWSER sends state/stage/viewers/fps

host→phone  {"t":"cast.notice","sid":"s1","code":"drm|quality_reduced|display_changed|sig_rejected","msg":"…"}   // non-fatal, never changes state

host→phone  {"t":"cast.err","sid":"s1","rid":"q1",
             "code":"unreachable|noperm|unsupported|busy|sink_lost|codec|nomirror|net_too_slow",
             "relaunch":false,"msg":"…"}
```

**Error codes (normative meanings; user copy in §13.8):**
- `unreachable` — no device on the sink LAN / probe failed.
- `noperm` — Screen Recording not granted (macOS). `relaunch:true` = grant exists but the host must relaunch for it to take effect (TCC quirk); see §9.1.
- `unsupported` — OS/version/hardware can't cast (incl. Windows without a Wi-Fi-Direct adapter, legacy Chromecast rejection).
- `busy` — a session is already active and the new `cast.start` names a *different* target (§10.1). (Re-`cast.start` of the *same* target is idempotent: answered with the current `cast.state`.)
- `sink_lost` — sink stopped responding mid-session (§10.5).
- `codec` — sink rejected the codec/profile. Host MUST auto-retry once at R3 before surfacing.
- `nomirror` — native AirPlay/Miracast trigger failed. **Same-room:** not terminal — the session stays in `STARTING(stage:"guided")` for the §8.8 guided window: the host keeps its display-topology watcher armed, auto-detects the user completing the mirror manually, and transitions to CASTING; `cast.stop` or window expiry tears down (`state:"stopped", reason:"user"`). **Remote** (phone not on the sink LAN): terminal — the user can't act on Mac-side guidance; remote copy in §13.8.
- `net_too_slow` — ladder at R0 >10 s, any path (§6.4).

`drm` is a **notice, not an error** (§14.4): protected content shows black on the TV but MUST NOT kill the session.

**Terminal-state rule (normative):** `state:"error"` is emitted only when a start attempt fails before CASTING was ever reached (paired with the `rid`-bearing `cast.err`). Teardown of an *established* session always reports `state:"stopped"` — `reason` carries the cause where the enum has one (`user`, `sink_lost`, or the timed-out PAUSED reason); for other fatal causes (`net_too_slow`, `codec`) the `err` field echoes the `cast.err` code and `reason` is omitted.

### 8.8 Normative timing constants

| Constant | Value |
|---|---|
| `cast.start` → first host response | ≤ 2 s (phone timeout 3 s) |
| Probe timeout / cache | 1 500 ms / 30 s |
| `cast.status` cadence while active | 1 s |
| Entry-point appear / disappear hysteresis | ≤ 1 s / 10 s |
| Sink heartbeat (CASTv2 PING or DataChannel) / `sink_lost` | 5 s / after 10 s unresponsive (or ICE `disconnected` > 10 s) |
| BRIDGE PAUSED grace, `link_lost` or `background` (PAUSED → stop) | 60 s |
| PAUSED(locked) ceiling (then stop, free the sink) | 15 min |
| Guided-fallback window after same-room `nomirror` (`stage:"guided"`) | 120 s |
| Time-to-first-frame budget, DIRECT p50 / honest-slow copy | ≤ 6 s / at 10 s |
| NATIVE trigger success timeout (excl. `pin_required` waits) | 30 s → `nomirror` |

---

## 9. Per-device responsibilities

### 9.1 Onboarding & permission choreography (normative)

The first cast MUST NOT stack surprise dialogs. The full worst-case inventory is:
- **Phone: zero new prompts.** iOS local-network permission was already granted for host discovery (§5.1); no Bluetooth (guest mode gone); Android Cast SDK needs no runtime permission.
- **macOS host:** Screen Recording is already granted for TV mode. **TCC gotcha (normative):** a *fresh* grant only takes effect after the host app relaunches. `cast.err noperm` carries `relaunch:true` for this case; the phone shows "Permission granted — Remotype Host needs a quick relaunch" with a **[Relaunch Host]** action: the existing `perm.fix` flow is extended with `{"relaunch":true}`, on which the host relaunches itself (spawn-self-and-exit). Family A (native mirror) needs no TCC beyond what the OS itself prompts.
- **Windows host:** native Miracast uses OS UI (no consent surface of ours). Family B on Windows (Slice 4.5, §15) will introduce a Graphics Capture consent — its UX is specced with that phase, not here.
- **TV side:** AirPlay PIN (§9.2) — handled in-flow, never a dead end.

### 9.2 Host — macOS (Swift, menu-bar)

- **Family A: trigger AirPlay mirror.** No public API to *start* AirPlay screen mirroring. v1 approach: **UI-script Control Center → Screen Mirroring → select target** via the Accessibility grant the host already holds. Two hard truths, both handled:
  - This is **greenfield AX-scripting** (the host's current AX use is read-only caret geometry); budget for per-macOS-version fragility (calibration §18-E1) and keep the manual fallback forever: on failure → `cast.err nomirror` → phone shows "Pick <TV> in the Mac's Screen-Mirroring menu — we opened it for you" (host opens the menu even when it can't complete the selection).
  - **The AirPlay PIN is part of the happy path, not an edge case.** Samsung/LG/Sony/Vizio TVs default to requiring a code on first connect (many are set to "Every Time"): the TV shows 4 digits and macOS pops a modal passcode field **on the Mac**. The host MUST detect that dialog via AX, report `cast.status stage:"pin_required"`, and the phone shows "Enter the code on your TV." The user types it on the **phone**; the host injects it into the dialog via its existing input-injection path. The success-detector MUST NOT count PIN-wait time toward the 30 s `nomirror` timeout.
- **Native success / external-stop detection:** mirror start is detected via display-topology observation (`CGDisplayRegisterReconfigurationCallback` + mirror-set membership); a user stopping the mirror from Control Center is detected the same way → `cast.status state:"stopped", reason:"user"`. NATIVE `cast.status` carries state/target only (no fps/kbps/latency — the OS gives us none).
- **Family B:** H.264 (VideoToolbox) off a new full-display SCStream (§6.1); WebRTC serve + DataChannel; CASTv2 sender client for DIRECT-heartbeat/REMOTE_TRIGGER — **locked implementation choice:** the Mac host bundles a small helper binary built from the same Go CASTv2 module the Go hosts use (one CASTv2 implementation across all hosts, `go-chromecast`-derived, with §14.3's device-auth requirement).
- Enumerate LAN targets (Cast via CASTv2 mDNS + AirPlay via `NWBrowser`) for `cast.targets`; interface enumeration + LAN-IP selection (§6.7) — both new modules.
- **Menu-bar UI (normative):** while a session is active the menu shows **"Casting to <TV> — Stop"**. This is the only stop affordance that survives a dead phone; it MUST exist from v1.
- Power assertions + lock handling per §10.4; local-audio mute/restore per §6.2.

### 9.3 Host — Windows (Go, tray)

- **Family A: trigger Miracast.** Capability first: report Miracast support (Wi-Fi Direct-capable adapter present, per OS query) and never advertise Miracast targets without it (§2.1). v1 approach: **script the Win+K "Connect" flow**; success/external-stop detection via display-topology change; on failure → `cast.err nomirror` + manual instruction. (A supported API path — `CastingConnection` family — is calibration §18-E3.)
- **Family B: Slice 4.5, not slice 1** (§15). The Windows host today has **no capture, no encoder, no media stack** — Family B there is from-scratch (Windows Graphics Capture → browser-B0 MJPEG first, then Media Foundation H.264 + the shared WebRTC/CASTv2 stack). Until then, Windows ships Family A only.
- Prerequisite **P1** (fixed port 50808 + connect-by-IP) applies before Windows remote-path phases.
- Tray UI: same "Casting to <TV> — Stop" rule as macOS. Power: `SetThreadExecutionState(ES_DISPLAY_REQUIRED|ES_CONTINUOUS)` while casting.

### 9.4 Host — Linux (Go)

- **Family A: none** (no native AirPlay/Miracast sender). **Family B is Linux's only cast path** — v3, and it depends on the Linux host first gaining the shared control-message layer (it currently handles input events plus a bare v2 hello/hi reply, with `ovl.*` parsed as no-ops; there is no hello-gating of control messages and no subscription/reply plumbing to hang `cast.*` off — that groundwork is part of the Linux-host roadmap item, not this spec's scope).

### 9.5 Phone (iOS + Android — **parity is mandatory**, per the repo rule)

- Integrate **Google Cast sender SDK** (Android `play-services-cast-framework`; iOS `google-cast-sdk`). Cast discovery, session, LAUNCH with token `customData`, custom-namespace bootstrap relay.
  - **Android specifics:** GMS becomes a runtime *optional* dependency (§5.1 gating); MainActivity is already a `FragmentActivity` (SDK requirement met); the Cast button is custom Compose UI driving `CastContext`/`MediaRouter` directly (no AppCompat `MediaRouteButton`).
  - **iOS specifics:** SDK floor iOS 15+ (fine); **no SPM** — the SDK is vendored as an XCFramework declared in `project.yml` so it survives xcodegen regeneration. Accept the app-size hit.
  - **Prerequisite P2 (Android):** the Wi-Fi control socket is currently Activity-scoped (dies in `onDestroy`). Before any cast phase ships, re-home the link into a foreground-service/app-singleton owner so `cast.status`/`cast.state` survive backgrounding — DIRECT's casting bar depends on it, not just BRIDGE.
- Browse AirPlay (`_airplay._tcp`) for display only; add the §5.1 Info.plist entries.
- Federated merge + dedup + hysteresis + progressive disclosure + permanent doorway (§5).
- Run the routing procedure (§4), incl. probes and probe pre-warming.
- **DIRECT:** LAUNCH + bootstrap relay; then free to background/leave (§6.6 guarantees the cast outlives the phone).
- **BRIDGE:** open the media socket, run the local WebRTC endpoint, hold the media path (§7.4, §11).
- **NATIVE / REMOTE_TRIGGER:** send `cast.start`, then render stages/status; the host does the work. PIN entry UI for `pin_required`.
- **While any session is active** (learned via `cast.state` on hello if reconnecting): show the casting bar (§13.6). Clients MUST auto-retry the Remotype link while a cast they started is active (overriding the current opt-in single-attempt reconnect behavior) — "remote control returns on reconnect" must actually happen without the user digging.
- Casting controls: start/stop, target switch, **sink volume** (§13.6), display switcher, quality toggle.

### 9.6 Custom Receiver (ours, HTML)

- **UI is part of the product, not plumbing:** on launch, immediately render a branded splash — "**Remotype** — connecting to <computer name>" (name passed in LAUNCH `customData`) — then fade to the stream on first frame. On stream loss: "Reconnecting to <computer>…" card, never a freeze/black. On session end: brief "Cast ended" then idle→self-close.
- **Hardening:** the receiver binds to the **first sender presenting the valid session token** and ignores all signaling without it; if no valid token arrives within 10 s of launch it self-closes (a rogue LAUNCH of our public App ID gets a dead receiver, §14.2).
- **Keep-alive:** with no CAF media ever loaded, the platform sees an "idle" app — the receiver MUST start CAF with idle reaping disabled (`context.start({disableIdleTimeout: true})`), and the host's CASTv2 connection (§6.6) keeps a sender attached. Both are required; do not rely on either alone.
- **Versioning & deployment:** the receiver MUST stay backward-compatible with **every shipped sender version** (protocol additive-only; unknown fields ignored — same forward-compat rule as the Remotype link); namespace hello carries `{"rv":1}`. Cast devices cache receiver assets aggressively — the entry URL MUST be served with `Cache-Control: no-cache` and all sub-assets content-hashed, so a hotfix lands on the next launch. **Two App IDs:** a published production ID + an unpublished dev ID (unpublished IDs stay usable on registered test serials after launch; senders select via debug flag). Receiver source lives in this repo (`cast-receiver/`) and deploys to custavia.com alongside the site.

### 9.6-browser Browser receiver page (§2.2 / Tier B0 — ships first, hosted BY the host)

A single self-contained HTML page **served by the host itself** (not custavia.com) at the token path (`/c/<token>`), so it is same-origin with the MJPEG stream and needs no HTTPS/CORS.

**Two ways in (normative):** (a) **QR** → the full `/c/<token>` URL (zero-step, the 256-bit token authorizes). (b) **Typed** → the "or open `<host:port>`" line a user can hand-type; the token is untypeable, so the **bare root `/` MUST serve a 4-digit code-entry page** (`GET /?code=NNNN` → the receiver on match; the wrong/absent code → the entry page; `410`/"Cast ended" once invalidated). The code is the human auth for the typed path. Without this, typing the host:port hits `/` and 404s.

Requirements:
- **Self-contained**: inline CSS/JS, no external fetches (works with zero internet on the LAN). Renders the MJPEG stream full-bleed, letterboxed, dark background; a small idle→fade "Remotype — <computer name>" title.
- **Robustness**: on stream stall, show "Reconnecting to <computer>…" and retry the `<img>`/WS; on `410 Gone` (token invalidated at teardown) show "**Cast ended**". Never a raw broken-image icon.
- **Wake-lock + no-sleep**: request a `screen.wakeLock` (best-effort) so a laptop/TV browser doesn't dim mid-view.
- **Audio (when it lands)**: an unobtrusive "🔊 Enable sound" tap target (browsers block autoplay audio until a user gesture) that starts the WebAudio PCM track.
- **B1 upgrade path**: the same page, when served from the hosted HTTPS origin with a `?webrtc` capability, negotiates WebRTC instead of `<img>`-MJPEG — one page, two transports.

---

## 10. Session lifecycle / state machine

```
IDLE ──cast.start──▶ RESOLVING ──(routing+probe ok)──▶ STARTING ──(sink playing)──▶ CASTING

Transitions (exhaustive):
  RESOLVING | STARTING ── fail (terminal cast.err — excl. same-room nomirror, next row) ──▶ ERROR
  STARTING  ── nomirror, same-room (stage:"guided", §8.7/§8.8 window) ──▶ STARTING (guided) ──▶ CASTING | STOPPED
  STARTING  ── host locked (§10.4) ─────────────────────────────────────▶ PAUSED(locked)
  CASTING   ⇄  PAUSED (§10.3 causes; resume always automatic)
  CASTING | PAUSED ── cast.stop · host-menu Stop · external stop (§9.2)
                      · sink_lost · fatal err · grace/ceiling expiry ───▶ STOPPED
```

**Wire note:** RESOLVING and STARTING both report `state:"starting"` on the wire — the `stage` field distinguishes them (`resolving|probing` vs `launching|waking|pin_required|connecting|buffering|guided`). Terminal-state rule in §8.7.

### 10.1 Concurrency (normative)

**One cast session per host, globally.** `cast.start` while a session is active: same target ⇒ idempotent (reply = current `cast.state`); different target ⇒ `cast.err busy`. **Target switch** is phone-orchestrated: the picker shows "Switch to <TV>?" and issues `cast.stop` + `cast.start` as one gesture. Any hello-completed connection may send `cast.stop` for the active `sid` (§8.4).

### 10.2 Link-drop rules

- **Direct/Remote-trigger:** a phone↔host Remotype-link drop does **NOT** stop the cast (host↔sink is independent) — it only removes the remote control until reconnect. **The session also survives host-side connection replacement** (the Mac host's accept() convention is newest-client-replaces-and-tears-down; cast state MUST be exempted from that teardown — copy the proximity-monitor precedent, *not* the TV/audio teardown pattern). Re-attach on reconnect via the §8.4 `cast.state` push.
- **Bridge:** a link (or media-socket) drop **pauses** (`reason:"link_lost"`; host stops encoding into the void); resume on reconnect within the **60 s** grace, else STOPPED. Phone death mid-bridge: the receiver's "Reconnecting…" card shows until the receiver self-times-out; the host times out via the dead media socket.
- **Native:** host owns the OS mirror; `cast.stop` scripts the teardown; external stop detected per §9.2.

### 10.3 PAUSED (fully defined)

| Cause (`reason`) | Entry | TV shows | Resume | Ceiling |
|---|---|---|---|---|
| `link_lost` (BRIDGE only) | link/media-socket drop | receiver "Reconnecting…" card | automatic on reconnect | 60 s → STOPPED |
| `locked` | host lock/login screen engages (or `cast.start` on a locked host) | receiver idle card "**<Computer> is locked**" — the lock screen itself is NEVER streamed (§10.4) | automatic on unlock | 15 min → STOPPED |
| `background` (iOS BRIDGE only) | app left foreground (§11.2) | receiver "Reconnecting…" card | automatic on foreground | 60 s → STOPPED (clock starts at PAUSED entry, i.e. after the §11.2 background-task grace expires) |

Resume emits an IDR frame. No `cast.resume` message exists — resumption is always automatic on cause clearing.

### 10.4 Power & lock (normative, new host code — nothing like this exists in the repo)

- While `state == CASTING`, the host MUST hold a no-display-sleep power assertion (macOS `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep)`; Windows `SetThreadExecutionState`) and MUST release it on **every** teardown path. Without this, the flagship "cast a movie, put the phone down" ends at a black TV in ~10 minutes.
- **Lock-screen policy:** if the host session locks mid-cast, the host detects it, sends `cast.status state:"paused", reason:"locked"`, and the receiver shows the idle card — the lock/login screen MUST NOT be streamed. `cast.start` on an already-locked host (the remote-trigger norm) succeeds into `PAUSED(locked)` with phone copy "Unlock <Mac> to start casting." The Remotype input path stays live while paused — on macOS, injected keyboard events are accepted at the login window with the Accessibility grant, so the user can type their password from the phone (verify per §18-E2; if a macOS version rejects login-window injection, the copy drops the suggestion — the pause behavior is unchanged).

### 10.5 Sink liveness

DIRECT/REMOTE_TRIGGER: host CASTv2 PING every 5 s (§6.6) + ICE state; BRIDGE: phone SDK session callbacks + DataChannel keepalive; NATIVE: display-topology observation (§9.2). Sink unresponsive 10 s (TV powered off, receiver killed) ⇒ `cast.err sink_lost` + full teardown. Phone copy in §13.8. **A transport-responsive sink keeps the session alive even if the TV's input is switched elsewhere** — input selection is invisible to the protocol; `sink_lost` fires only on transport unresponsiveness, never as a guess.

### 10.6 Teardown checklist (every path, every cause — all six, always)

1. Stop the H.264/Opus encoder and capture stream.
2. Close server/peer/DataChannel + **invalidate the session token**.
3. Release the sink (CASTv2 STOP receiver / scripted mirror-off / media-socket close).
4. **Restore local audio output** to its pre-cast level (§6.2).
5. **Release the power assertion** (§10.4).
6. Re-enable the mJPEG `tv.*` path and notify the phone (`cast.status state:"stopped"`), which restores the TV panel + magnifier controls (§6.1).

---

## 11. Backgrounding (per platform, per mode)

**Only BRIDGE mode puts the phone in the media path**; DIRECT/REMOTE_TRIGGER/NATIVE let the phone background or leave freely (guaranteed by §6.6's phone-independent signaling — not just asserted).

### 11.1 Android (bridge) — supported, robust

Extend the (P2-re-homed, §9.5) **foreground service** with type **`connectedDevice`** and a persistent "Casting to <TV>" notification with a Stop action — the `FOREGROUND_SERVICE_CONNECTED_DEVICE` permission and a `connectedDevice`-typed service already exist for BT-HID (`HidService`); P2 either reuses that service or mirrors its declaration for the Wi-Fi link. Rationale (locked): `dataSync` is capped (~6 h/day) on targetSdk 35 and is therefore wrong for "runs screen-off indefinitely"; `connectedDevice` matches the semantics (relay to an external device) and has no such cap. The phone relays network→network (no MediaProjection — we never capture the phone's screen). Battery/thermal is the only limit.

### 11.2 iOS (bridge) — foreground-only, honestly

**Locked decision: no background-entitlement games.** The `audio` background mode only keeps an app alive while it is *actively rendering audio on this device* — a bridge phone plays nothing locally, so the entitlement keeps nothing alive; the workaround (silent audio loop) is a canonical App Review rejection (Guideline 2.5.4). Therefore:
- iOS BRIDGE is **foreground-only**. On backgrounding, a standard `beginBackgroundTask` grace (~30 s) covers accidental swipes: within it, returning to foreground resumes seamlessly; beyond it → `PAUSED(background)` per §10.3, auto-resume on foreground.
- UI copy: "Keep Remotype open while casting from a remote computer." Guided Access is suggested in the §13.4 warning sheet for podium use.
- The former "casting with audio earns the background-audio entitlement" rationale is deleted everywhere; §12's iOS row is an explainer, not a toggle. (What *is* achievable screen-off is calibration §18-E4 — measure, then promise the floor, not the hope.)

---

## 12. Preferences (Settings → **Casting** — the permanent doorway, always visible)

Defaults chosen so casting works **before anyone opens Settings** (magic = zero-config). The screen also hosts the live "Nearby TVs" list + "Why can't I see my TV?" expander (§5.5).

| Setting | Default | Platform | Effect |
|---|---|---|---|
| **Cast quality / latency** | Auto | all | Auto (full ladder) · Low-latency (fps floor 24) · High-quality (res floor 1080p) — §6.4; changeable mid-cast |
| **Cast controller** | Auto | all | Auto (routing matrix) · Force host — applies only when the computer can reach the TV (§4) |
| **Mute computer speakers while casting** | On | all hosts | §6.2 double-audio rule (Family B only; row hidden for NATIVE-only sessions) |
| **Keep casting in background** | On | Android | `connectedDevice` foreground-service relay for bridge mode (§11.1) |
| *(iOS)* "Bridge casting needs the app open" | — (info row) | iOS | non-toggle explainer (§11.2) |
| **Warn before remote / cellular casting** | On | all | shows the §13.4 battery+heat+data sheet before Bridge/metered |
| **Include computer audio when casting** | On | all | mux audio; off = video-only (and skips the §6.2 speaker mute) |

Remembered sinks (for §13.3 one-tap and §14.3 identity) persist **phone-side** in existing client prefs, keyed by host + sink `deviceId`. The host stays stateless across sessions (all cast state is in-memory).

---

## 13. UX & progressive disclosure

### 13.1 Entry point

**Normative home: adjacent to the existing TV-mode control** on both clients (the mental model is "the computer's screen, but bigger"); exact placement per the phone app's design system. Visibility: the entry point appears when `castCapable && (mergedTargets ≥ 1 || castSession != nil || browserCapable)` — i.e. as soon as a real sink is discovered **or** the host supports the browser receiver (§2.2, which needs no discovery), so the affordance is available even in an empty room. One **unified picker**, sorted (recently-used → same-room → others; ties alphabetical), each row: name, type glyph (Cast/AirPlay/Miracast/Browser), and a location hint ("on this Wi-Fi" / "via your computer").

**The Browser row is always the first row** when the host is browser-capable: **"Cast to a browser / another screen"** with a globe/monitor glyph and the subtitle "open a link on any laptop or TV — no setup". Tapping it starts a `browser` cast (§7.0) and shows the QR/URL sheet (§13.6-browser). This is the row that works with zero sinks in the room — often the user's first successful cast.

### 13.2 Teaching the mental model (the hardest concept in the feature)

Every user's prior is *phone*-casting; Remotype's model is **the computer casts, the phone is the remote**. Normative teaching surfaces:
- Picker header: "**Your computer casts to these**"; row subtitles name the path: "via your Mac · AirPlay", "on this Wi-Fi · Chromecast".
- First-ever picker open: a one-time 2-line explainer card with a computer→TV arrow and phone-as-remote glyph.
- Error copy reinforces it (§13.8's `unreachable` line explains *why* the computer's network matters).

### 13.3 One-tap recast (the daily loop)

Remember the last successful target per host. When it is currently discovered, the entry point itself becomes **"Cast to <Living Room TV>"** (single tap = start; long-press or chevron = full picker). Probes pre-fire for the remembered target on entry-point display (§4 Step 2), so the daily tap starts in ≤1 s perceived.

### 13.4 Pre-cast confirmations (each shown once per condition, with "Cast anyway")

In order, merged into one sheet when multiple apply: first-time-sink identity confirmation (§14.3) → Bridge battery/heat + "keep the app open" (iOS) → metered-link data warning.

### 13.5 STARTING — the positive feedback (never a bare spinner, in success too)

The phone renders the `stage` field (§8.7) as a step narrative, not a spinner: "Waking Living Room TV… → Starting Remotype on the TV… → Connecting to your Mac… → First frame ✓". The TV shows the receiver splash from the first second (§9.6) — visible proof the tap worked. At 10 s without first frame: honest copy ("Still connecting — your network is being slow"). `pin_required` swaps the narrative for the PIN entry field (§9.2). **Browser** (`waiting_viewer`): no spinner at all — the phone shows the QR sheet (§13.6-browser) immediately, with "Waiting for a browser to open the link…".

### 13.6-browser The browser QR sheet (normative)

When a `browser` cast is active the phone shows, in place of the generic casting bar's status chip: a **large QR code** of the `cast.ready` URL, the **URL as tappable text** ("or open **192.168.1.20:50809** in any browser"), and the **short pairing code** ("or enter code **7431**") for TV browsers where scanning is awkward. Copy above: "**Open this on the screen you want to cast to** — your computer streams there; your phone stays the remote." Once `viewers ≥ 1` the QR collapses to a compact "**On 1 screen · Stop**" chip (tap to re-expand the QR to add another screen); `waiting_viewer` re-expands it. **Stop** ends the session for all viewers. Everything else in §13.6 (the live input deck, silent bar-restore on reconnect, the host menu-bar Stop) applies unchanged.

### 13.6 While casting

A persistent **"Casting to <TV>"** bar with **Stop**, a status chip (latency/quality rung; "reduced quality" on `quality_reduced`), the **display switcher** when >1 display (§6.1), and the live input deck still active (you drive the computer). The TV panel is replaced by the cast status card; magnifier controls hidden (§6.1).

**Volume (normative):** the bar's volume control targets the **sink** where the path exposes it — Cast paths: an absolute-volume slider labeled "TV volume" (set via the Cast SDK when the phone is the controller; via `cast.volume` relay §8.6 when the host is); NATIVE: computer-volume steps labeled "TV volume (via <computer>)" (the OS routes output to the sink). Computer-mute stays in the deck as today. (The existing PC-volume path is step-only; it is never presented as a slider.)

The bar reappears automatically on reconnect/re-open via the `cast.state` hello push (§8.4) — silently, no re-confirmation. The **host's menu-bar/tray** shows "Casting to <TV> — Stop" throughout (§9.2/§9.3).

### 13.7 Presenter synergy (flagship demo)

When the host overlay ships (the presenter-mode design), it appears on the TV for free (§6.1 capture-inclusion rule). The in-cast deck surfaces big-screen quick actions: pointer/spotlight toggle (when available), media keys, TV volume. The promo scene is phone-drives-a-spotlight-on-the-TV (rig note §16).

### 13.8 Error copy (normative table — every code ships with copy and an action)

| Code | User line | Action button(s) |
|---|---|---|
| `unreachable` | "Your computer and <TV> aren't on the same network. Casting streams **from your computer**, so both need to be on the same Wi-Fi." | [How casting works] |
| `noperm` | "Remotype Host needs Screen Recording permission on your Mac." | [Fix on Mac] (perm.fix) |
| `noperm` + `relaunch` | "Permission granted — Remotype Host just needs a quick relaunch." | [Relaunch Host] (§9.1) |
| `unsupported` (Win, no Wi-Fi Direct) | "This PC's network adapter doesn't support wireless display (Miracast needs Wi-Fi on the PC). You can still cast to Chromecast devices." | [Learn more] |
| `unsupported` (legacy sink) | "This older Chromecast may not keep up. Trying reduced quality…" (auto), then: "It couldn't keep up." | [Stop] |
| `busy` | "Already casting to <TV A>." | [Switch to <TV B>] [Stop] |
| `sink_lost` | "<TV> stopped responding — it may be off or on another input." | [Retry] |
| `codec` | "<TV> couldn't play the stream. We retried at lower quality and it still failed." | [Stop] |
| `nomirror` (same-room) | A **guided sheet** (first-class UX, not a toast — owner sign-off R1/R2): "Almost there — one quick step on your computer:" then numbered steps with the target name filled in (macOS: **1** Open Control Center — we did this for you · **2** Click Screen Mirroring · **3** Pick **<TV>**. Windows: **1** Press **Win+K** · **2** Pick **<TV>**), footer "We'll take it from there." (host auto-detects the manual pick for the §8.8 guided window; help expander adds the Samsung TV-side fix: TV Settings → Apple AirPlay settings → AirPlay **On**) | [Stop] |
| `nomirror` (remote) | "Couldn't start Screen Mirroring on <computer>, and you're not nearby to do it by hand. Try a Chromecast target, or cast when you're near it." | [Stop] |
| `net_too_slow` | "Your Wi-Fi can't keep up with casting right now. Moving the computer or TV to 5 GHz usually fixes this." | [Keep trying] [Stop] |
| *(phone-local)* `cast.start` 3 s timeout (§8.1) | "Your computer didn't respond. Check that Remotype Host is running, then try again." (a host that advertised `cast` capability but answers nothing is unresponsive, not outdated — reserve the update-host copy for missing capability) | [Try again] |
| notice `drm` | "That app blocks screen capture, so it shows black on the TV. Everything else casts fine." | (dismiss) |

### 13.9 Launch & education (the feature must be discoverable to be magic)

- One-time **what's-new card** on first launch after the Cast release: "New: put your computer on the TV — your phone is the remote", deep-linking to Settings → Casting.
- The **first time the entry point ever appears**, pulse/badge it once with a one-line tooltip ("<TV> found — cast your Mac to it"); never again after first open.
- Promo video scene per the existing playbook (`store-assets/promo-src/PROMO_VIDEO_PLAYBOOK.md`): tap → TV splash → desktop on TV → phone as remote (→ spotlight on TV when presenter ships).

---

## 14. Security & privacy

### 14.1 Exposure model

Casting **exposes the desktop on the LAN.** The stream server/ICE candidates MUST be restricted to the sink-reachable LAN interface (§6.7), and teardown MUST be complete (§10.6).

### 14.2 Session token protocol (normative — WebRTC has no "URL" to put a token in)

- `cast.ready` carries `token` on every streamed path (omitted for NATIVE, §8.4): 256-bit random, base64url, generated per session by the **host**; the WebRTC endpoint facing the receiver (the host — or the phone in BRIDGE) validates it on every signaling message.
- **Every** `cast.sig` message and **every** receiver-namespace signaling message MUST carry the token; the streamer MUST drop (silently) any offer/answer/ICE without a valid token (constant-time compare). The controller passes the token to the receiver in LAUNCH `customData`; the receiver echoes it in all namespace messages and DataChannel hellos.
- The streamer MUST answer **at most one** offer arriving via the bootstrap relay (`cast.sig` / Cast namespace) and MUST pin the DTLS fingerprint from that first verified offer. Renegotiation/ICE-restart offers arriving over the established, token-authenticated **DataChannel** under the pinned fingerprint are legitimate (§6.6 mandates them). An offer on the bootstrap relay *after* bootstrap, or any fingerprint change, is a hostile signal: drop it and emit `cast.notice {code:"sig_rejected"}`. (DTLS-SRTP encrypts; only the token+pin *authenticates* — SDP rides plaintext relays.)
- Token is single-session and invalidated at teardown step 2 (§10.6). For the dev-only HLS spike, the token is a URL path segment; plain-HTTP exposure is accepted **because the spike never ships** (§6.5).
- Receiver-side: §9.6 hardening (bind-to-first-valid-token, 10 s self-close). Our App ID is public and enumerable — a rogue LAUNCH gets a splash that self-closes, never a stream.

### 14.3 Sink identity (mDNS names are forgeable)

First cast to a never-before-used sink shows a confirmation naming sink + network: "Cast this computer's screen to **'Living Room TV'** on **<SSID>**?" Sinks are remembered by **`deviceId`, never by name** (§12); a new `deviceId` reusing a remembered name, or a renamed device, re-triggers the confirmation. Host-controlled CASTv2 connections MUST perform CASTv2 **device authentication** (verify the Google-signed device certificate) — the bundled Go CASTv2 client must be audited/extended for this (stock `go-chromecast`-style clients typically skip cert verification).

### 14.4 DRM (detect honestly, never false-kill)

ScreenCaptureKit can't see protected surfaces → DRM'd video shows **black** on the TV. Detection MUST be corroborated, not luminance-only: prefer SCK's protected-content signal where available; the black-frame heuristic requires **>5 s sustained full-black AND a known DRM-video app frontmost**. Surface as non-fatal `cast.notice drm` (§13.8) — dark movie scenes, dark IDE themes, and idle displays MUST NOT kill a cast with a wrong "protected content" error.

### 14.5 Control plane — stated honestly

`cast.*` is v2-hello-gated like all control messages — and per PROTOCOL.md the hello gate is a **version handshake, not a security boundary** (the Remotype link is plaintext, unauthenticated TCP; raw input injection is already ungated). Gating `cast.*` "identically" therefore means: any peer that can open the control port can start/stop a cast. This is **accepted** for this feature (it adds no capability an attacker with input injection lacks — they could already open a browser and exfiltrate), but it MUST be documented in the threat model, and the eventual link-pairing/authentication work (out of scope here) closes it for input and casting together. The session token (§14.2) protects the **media** plane regardless.

### 14.6 Logging

Content-free logging rule applies: no tokens, no SDP bodies (they contain interface IPs), no sink names in host logs — log codes, states, and counts only.

---

## 15. Phased rollout (what ships when — normative)

**Prerequisites (tracked work items, not casting code):**
- **P1** — Windows/Linux hosts adopt fixed port 50808 + connect-by-IP (needed for their remote-path phases; macOS already has it).
- **P2** — Android: re-home the Wi-Fi control socket from Activity scope into a service/app-singleton (needed for the casting bar to survive backgrounding, all paths).

> **Slicing note (2026-07-04):** the spec's original "v1" bundled Family-A NATIVE and Family-B Cast DIRECT together. Implementation split them, and the discovery that the **browser receiver ships on the existing MJPEG pipeline** (§2.2) reordered Family B: **browser comes before Chromecast.** The phases below reflect the real ship order.

- **Slice 1 — "same room, native" (SHIPPED).** Family A: macOS→AirPlay native trigger (AX-scripted, **incl. the PIN flow §9.2**) + Windows→Miracast native trigger (Win+K script + capability gate §9.3). Federated discovery + routing matrix + progressive disclosure + permanent doorway + picker + one-tap recast + power assertions + lock policy + session re-attach + host stop menu + error-copy table. No host media stream yet.
- **Slice 2 — "cast to any browser" (NEXT — the first Family-B ship).** *Widest reach, no vendor, no Cast console, no WebRTC.*
  - macOS host: **full-display capture (§6.1) + Tier-B0 MJPEG-over-LAN-HTTP server (§6.5) + BROWSER path (§7.0)**; local-audio-mute (§6.2) applies once audio lands.
  - Both phones: the always-available **Browser row** (§13.1), the **QR/URL/code sheet** (§13.6-browser), `browser` `cast.start`/`ready`/`status`/`stop`, `waiting_viewer`/`viewers` handling, casting bar + host menu-bar Stop.
  - Validation needs no external accounts — open the URL in any laptop/TV browser. Audio (PCM-over-WebSocket → WebAudio) MAY land a beat after video.
- **Slice 3 — Cast DIRECT (Chromecast).** **Cast DIRECT via Tier 1** (WebRTC + Custom Receiver, device floor §6.5), controller = phone, **incl. the host's CASTv2 sender connection** (§6.6). Needs the H.264/Opus encoder ladder (§6.4), the WebRTC host stack, the hosted receiver, and the $5 Cast console App ID.
- **Slice 3.5 — REMOTE_TRIGGER + polish.** Host-as-*controller* CASTv2 path; remote NATIVE for previously-paired sinks (§7.1); quality switching + display switcher; WebRTC tuning toward <300 ms. Tier B1 (WebRTC browser + cloud signaling for remote-network browser cast) rides the same WebRTC stack.
- **Slice 4 — BRIDGE.** Media socket + framing + backpressure; Android `connectedDevice` service; iOS foreground bridge; IDR/FEC resilience (§18-E5); bridge warnings.
- **Slice 4.5 — Windows Family B.** Graphics Capture + Media Foundation encode + the shared MJPEG/WebRTC stack (Windows browser-B0 first, same reuse logic); Windows Graphics-Capture consent UX.
- **v3 — breadth.** Linux host cast (after its control-layer groundwork); legacy-sink quirk hardening; optional phone-side live thumbnail. *(Extended display is a non-goal, not a phase — §18-E6.)*

---

## 16. Device / QA test matrix (the empirical half — where the real time goes)

Every cell is a real test, not a checkbox:

| Sink | via | Same-room (Direct/Native) | Remote-trigger | Bridge |
|---|---|---|---|---|
| **Samsung TV (office)** | AirPlay (Mac) | ✅ must — **incl. first-connect PIN + "Require Code: Every Time"** | ✅ paired-only (§7.1) | n/a |
| **Samsung TV (office)** | Miracast (Win, Wi-Fi-Direct-capable laptop) | ✅ must | ✅ | n/a |
| **Ethernet-only desktop (Win)** | Miracast | ✅ must show `unsupported` copy, no Miracast rows | — | — |
| **Chromecast with Google TV** | Cast | ✅ must | ✅ | ✅ |
| **Legacy Chromecast (gen 3)** | Cast | ✅ best-effort R3 + honest degradation (§6.5) | ✅ | ✅ |
| **Nest Hub** | Cast | ✅ | ✅ | ✅ |
| **Apple TV** | AirPlay (Mac) | ✅ | ✅ paired-only | n/a |
| **Miracast dongle** | Miracast (Win) | ✅ | ✅ | n/a |

Cross-axes to vary in each: **audio on/off (double-audio mute verified by ear) · quality Auto/Low/High + mid-cast switch · DRM content (expect black + notice, session survives) · dark-content false-positive check (dark movie ≠ drm) · guest-VLAN isolation (expect `unreachable`) · Tailscale host · phone background AND phone power-off mid-cast (Android vs iOS, per path) · Remotype-link drop mid-cast (re-attach + casting-bar restore) · host-connection replacement mid-cast (cast survives) · display sleep >15 min (assertion holds) · host lock/unlock mid-cast (idle card, never the lock screen; phone-keyboard unlock per §18-E2) · multi-monitor (default display rule + switcher) · monitor hotplug mid-cast · 2.4 GHz congestion (ladder walks down, `net_too_slow` at floor) · sink power-off mid-cast (`sink_lost` ≤ 15 s) · TV input switched away mid-cast (session persists — no false `sink_lost`, §10.5) · TV-side "AirPlay: Off" (guided fallback) · manual-completion of a same-room `nomirror` (guided window auto-detects, §8.7) · GMS-less Android device (host-side sinks only) · old host version (capability gate: no cast UI, no silent spinner) · rogue-sink name spoof (identity confirmation fires) · multi-hour cast (A/V skew ≤ 80 ms).**

Rig note: reuse the promo-video capture rig (emulator + Mac host) for UI development, but casting must be validated on **real** sinks — phone-side Cast/mDNS discovery does not work on the emulator (NAT drops multicast), and no emulator exercises a real sink.

**Cast test-device notes (practical setup):**
- **First validation is free and needs no registration — do it on ANY Chromecast.** Point the **Default Media Receiver** (App ID `CC1AD845`) at a live-HLS URL from the host: it requires **no custom receiver and no test-device registration**, and plays on **every Cast device immediately** (any generation). Prove "host screen → TV, phone-triggered" here before building the WebRTC custom receiver.
- **WebRTC (custom receiver) requires a MODERN Cast device — pick by firmware, not model name.** Use a **Chromecast with Google TV / Google TV** (has a Bluetooth remote). **Do NOT use `eureka_info`'s `model_name` to judge generation — every generation reports the generic `"Eureka Dongle"`.** The real signals: **Cast firmware major version** (`cast_build_revision` `1.x` = old, HLS-only; **`3.x+` = modern, WebRTC-capable**) and the presence of a **BT/remote**. Legacy (gen-3 / `1.x`) devices are for the HLS/`CC1AD845` + R3-degradation rows only.
- **Finding a device's serial** (needed only to register an *unpublished* custom receiver): it is on the device's on-screen **Status** page (Settings → System → About) or its **physical label**. Google **removed it from the Home app**, and the local `eureka_info` endpoint does **NOT** expose it (only `ssdp_udn` UUID + MAC). After adding a serial in the console, **reboot the device** (~15 min propagate); **publishing the receiver removes the serial requirement entirely** (§17).

---

## 17. Dependencies & cost

- **Google Cast SDK** — free. Android: `play-services-cast-framework` (makes GMS an *optional* runtime dependency — §5.1 gating keeps de-Googled devices working). iOS: binary **XCFramework, vendored via `project.yml`** (no SPM; survives xcodegen); floor iOS 15+; accounts for app-size.
- **CASTv2 host client** — one Go implementation (derived from `go-chromecast`, audited for §14.3 device-auth), used by the Go hosts natively and bundled as a helper binary with the Mac host. `pychromecast` as the prototype/reference oracle.
- **Custom Receiver** — small static HTTPS web app we host at `custavia.com/remotype/cast-receiver/`; **$5 one-time** Google Cast Developer Console registration (+ register test-device serials during dev; publishing removes that limit). Back-compat contract §9.6.
- **VideoToolbox / Media Foundation** — H.264 encode on macOS/Windows (built-in). **Opus** encode via the WebRTC stack.
- **WebRTC stack (host)** — a Swift/Go-consumable libwebrtc (or Pion for the Go hosts; the Mac host MAY use the bundled-helper approach if libwebrtc-Swift proves heavy — same helper-binary pattern as CASTv2). This is the largest new dependency; there is **no streaming/HTTP/TLS/WebRTC code in the repo today** — budget accordingly.
- No paid SDK, no licensing wall.

---

## 18. Empirical calibration items (measure during development; NOT design questions)

Every design decision is locked above. These are values/verifications to fill in, with the spec'd fallback if measurement disappoints:

- **E1 — AirPlay AX-script robustness across macOS versions.** The Control-Center script + PIN-dialog detection (§9.2) must be validated per macOS release; the manual `nomirror` fallback is permanent regardless. (A private-CoreDisplay trigger MAY be spiked as a *more stable implementation* of the same locked behavior.)
- **E2 — Login-window keyboard injection** (§10.4): verify per macOS version; on failure, drop the "type your password from the phone" copy only.
- **E3 — Windows Miracast scripting** (§9.3): validate Win+K scripting per Windows build; spike `CastingConnection`/`Windows.Media.Casting` as a cleaner implementation of the same behavior.
- **E4 — iOS backgrounding floor** (§11.2): measure the real background-task grace; set the shipped grace window to the measured floor.
- **E5 — Bridge FEC/IDR parameters** (§6.4): tune keyframe cadence + FEC/retransmit for a real lossy ~30–60 ms Tailscale link; watchable = the bar.
- **E6 — (not a calibration item) Extended display: explicit NON-GOAL, owner sign-off.** "TV as a second monitor" (display-extension, not mirror) is not part of any phase and MUST NOT be scoped into one — it is OS-native display-extension and not app-triggerable anyway. Recorded here so nobody re-opens it.
- **E7 — Legacy Chromecast actual ceiling** (§6.5): measure what gen-3 hardware sustains; adjust the R3 entry cap and the honest-copy threshold to reality.

---

## Appendix A — What changed from v1 (review-driven, 2026-07-03)

**Owner §18 sign-off mapping (commit `f99fd4e`, honored here):** Q1 (phone controller when viable; host fallback) → §4 routing + Force-host pref — the sign-off's "thermally-limited bridge falls back to host control" example is impossible (in BRIDGE the host cannot reach the sink; that's why it's a bridge), so thermal degradation is handled by §7.4's `maxRung`/honest-stop rules instead. R1/R2 (programmatic-then-guided, first-class step-by-step, success auto-detected) → §9.2/§9.3 + `stage:"guided"` (§8.7/§8.8) + the §13.8 guided sheet. R3 (HTTP-HLS never ships) → §6.5 Tier 0 dev-only. R4 (no iOS background promise; friendly keep-open message) → §11.2, with one factual correction: the brief grace comes from `beginBackgroundTask`, not the `audio` entitlement (which keeps nothing alive without local playback). R5 (defer bridge tuning to post-v2 empirics) → §18-E5. Q2 (extended display non-goal) → §0 + §18-E6.

Fifty-one verified findings from a grounded adversarial review. The load-bearing changes:

1. **Miracast re-modeled** as a Wi-Fi Direct capability, exempt from the LAN/probe model; Wi-Fi-Direct adapter requirement added + MS-MICE claim removed (§2.1) — *was unimplementable as written*.
2. **Capability flag + ack/timeout contract** (`hi.cast`, `rid`, 2 s/3 s) so old hosts can never produce a silent spinner (§8.1).
3. **iOS bridge rewritten to foreground-only** — the audio-entitlement mechanism didn't work and its workaround is an App Review rejection (§11.2).
4. **Post-bootstrap signaling moved to a DataChannel + host-held CASTv2 connection** so DIRECT truly survives the phone leaving (§6.6).
5. **Tier-1 device floor declared**; legacy Chromecasts best-effort (§6.5).
6. **AirPlay PIN flow** (detect dialog, type code from the phone) — first-connect Samsung is the happy path, not an edge case (§9.2).
7. **Double-audio rule**: host mutes local speakers during Family-B casts (§6.2).
8. **Power assertion + lock-screen policy + PAUSED fully defined** (§10.3–10.4).
9. **Session re-attach** (`cast.state` on hello), cast survives host connection replacement, host menu-bar/tray Stop (§8.4, §9.2, §10.2).
10. **Token protocol made concrete for WebRTC** (per-message token, one-offer rule, DTLS pin) + receiver hardening + sink-identity confirmation with CASTv2 device-auth (§14.2–14.3).
11. **Adaptive-bitrate ladder is normative**; `net_too_slow` generalized beyond bridge (§6.4).
12. **Phone-view-rides-H.264 cut**; TV panel → status card, magnifier suspended during casts (the v1 draft's ride-along silently deleted TV-mode's magnifier semantics and required a phone H.264 decoder that doesn't exist) (§6.1).
13. **BRIDGE media leg gets its own binary-framed socket** with the repo's backpressure discipline (§7.4).
14. **Multi-display**: default rule + in-cast switcher + hotplug recovery (§6.1).
15. **UX build-out**: STARTING stage narrative + receiver splash, error-copy table, mental-model teaching, one-tap recast, permanent doorway, what's-new education, sink-volume control, presenter-overlay capture guarantee, discovery hysteresis (§13).
16. **DRM demoted to a corroborated non-fatal notice** (dark scenes must not kill casts) (§14.4).
17. **Phasing corrected to codebase reality**: Windows Family B → v2.5 (no capture stack exists there); prerequisites P1 (fixed ports) and P2 (Android socket re-homing) named; Linux control-layer gap acknowledged (§9, §15).
18. **Protocol hygiene**: `drm`→notice; `busy`/`sink_lost` added; `net_too_slow` spelling canonicalized (the v1 draft had a Unicode soft-hyphen inside the code name); `cast.targets` = full-snapshot semantics; probe ports/timeouts specified; quality semantics defined; target-addr authority rule (§4, §8).

*End of spec. Implementers: everything is decided; build to it. §18 items are measurements, not choices. Genuine contradictions go to the owner.*
