# Multi-Computer Management (MCM) — Design

Status: **DESIGN / for review** · a reimplementation after an earlier attempt was reverted.

Goal: one phone drives **several computers**, with the cursor/keyboard flowing between
them (Logitech-Flow / Synergy style) plus an on-phone spatial map, a quick-switch strip,
edge-resistance feedback, and TV mirror that follows whichever computer has focus.

## 1. Model

- **Pool**: the phone holds **N live host connections** at once. Each is a full connection
  (own read pump, own `hi`/vitals/tv state, own dial-timeout) — not inert half-open
  sockets.
- **Active host**: exactly one host in the pool is *active* = receives keyboard + trackpad.
  Others are **warm standby** (connected, capabilities known, ready for instant switch).
- **Layout**: the user arranges hosts on a 2D grid (MCMView) matching their desk. Adjacency
  in that grid defines edge neighbors (host to the left/right/up/down).

## 2. Features (confirmed list)

1. Multi-host connect (pool) — bulk-connect discovered/paired hosts.
2. Active-host switch — pick who gets input (top strip tap, or edge-flow).
3. Top host strip — persistent row; active highlighted; per-host color/status; tap = switch.
4. MCMView spatial organizer — drag hosts into a grid; persisted; defines edge adjacency.
5. Edge-flow — cursor hits a screen edge on the active host → hand off to the neighbor.
6. Edge resistance/friction — configurable push before the switch commits.
7. Edge visual cues — on-phone overlay: target computer + push-progress + direction.
8. cancel_edge — abort a partial edge push.
9. TV-follow-active-host — TV mirror auto-switches source to whoever has focus.

## 3. Protocol (additions)

All newline-JSON, same channel. Host↔phone, per the active connection unless noted.

**Host → phone:**
```jsonc
{"t":"edge","side":"left|right|top|bottom","y":0.42}   // active host: real cursor hit an
                                                        // edge; y = normalized pos along it
{"t":"edge.cancel"}                                     // cursor left the edge before commit
```
**Phone → host:**
```jsonc
{"t":"edge.arm","sides":["left","right"]}   // tell host which edges have a neighbor (so it
                                            // only reports edges that lead somewhere)
{"t":"edge.release","to":"left","y":0.42}   // COMMITTED: host must (a) stop input capture,
                                            // (b) park its own cursor off that edge
{"t":"edge.enter","from":"right","y":0.42}  // to the NEW active host: warp cursor onto the
                                            // opposite edge at y, resume input
```
Reuses existing input opcodes (`mm`/`key`/…) — they simply route to whichever connection is
active. No change to the hot input path (no per-send dictionary lookup on the hot path).

## 4. Edge-flow mechanics (the core)

**Host-side edge detection** (the Flow/Synergy model — real cursor, not a trackpad gesture):
- On `edge.arm`, the host polls its cursor (~30–60Hz, only while armed) — `GetCursorPos`
  (Windows) / `CGEvent.location` + `CGDisplayBounds` (Mac). Report only *armed* edges.
- Coalesced + only-on-change (no per-tick spam). Timer runs ONLY while armed + a neighbor
  exists (no always-on 20 Hz timer).

**Phone-side resistance + commit:**
- On `edge`, phone enters *edge-pending*: shows the overlay (target host name + a progress
  bar). The user keeps pushing the trackpad in that direction; accumulated push vs the
  configured friction fills the bar. Below threshold + cursor leaves edge → `edge.cancel`.
- At threshold → **commit**: `edge.release` to old host (park cursor, stop input) →
  switch active host → `edge.enter` to new host (warp cursor to opposite edge at same y,
  resume) → TV-follow re-subscribes (if TV on). Haptic + brief overlay confirm.

**Cursor parking / warping** needs the host to set its cursor: `SetCursorPos` (Windows,
already used by ovl.cursor) / `CGWarpMouseCursorPosition` (Mac).

## 5. TV-follow-active-host
- One TV subscription, always to the **active** host. On switch: `tv.unsub` old → `tv.sub`
  new (same w/h/zoom/follow). A "TV follows focus" toggle (default on) in TV menu; off =
  pin TV to a chosen host.

## 6. Per-platform work

- **Phone (iOS Controller / Android NetworkSink)**: connection **pool** (Map<serviceName,
  Conn>), `activeService`, route input to active, per-conn read pump + timeout + teardown
  (everything a bulk connect has to cover). Pool teardown on disconnect.
- **Phone UI (both)**: MCMView (grid, drag, persist), TopHostStrip, edge overlay, TV-follow toggle.
- **Mac host (Server.swift)**: `edge.arm`/detection/`edge.release`/`edge.enter`, cursor warp.
  Per-connection, torn down on disconnect (NOT the leaked global timer).
- **Windows host (main.go)**: same, via GetCursorPos/SetCursorPos + screen metrics.

## 7. Security
- MCM routes keyboard across machines → **proper TLS pinning** (Phase 2, separate reviewed
  change): SHA-256 SPKI pin, Keychain/Keystore-stored key, both clients speak it, both hosts
  offer it, graceful downgrade. not a hashValue-based TOFU.

## 8. Sequencing (feature-first, then TLS-harden — keeps the app working + testable)
1. **A — pool + active-switch + TopHostStrip** (multi-host, tap-to-switch; no edge yet).
2. **B — MCMView spatial grid** (layout + adjacency + persist).
3. **C — host-side edge-flow** (detection + resistance + cues + warp + cancel + clipboard-follow).
4. **D — TV-follow-active-host.**
5. **E — TLS hardening** (§7) applied to both transports last, so it never blocks feature
   validation and the app stays working at every commit.
Each step compiles + device-validated (S21/Pixel vs Mac+Windows) before the next.

## 9. Decisions (confirmed)
- **Edge trigger**: HOST-SIDE real cursor (Flow/Synergy). Host polls its cursor only while
  armed; reports edge hits; warps cursor on switch.
- **Keyboard follows the cursor** on switch (standard; no split).
- **Clipboard-follow: YES** — on commit, push the held clipboard to the computer flowed into
  (reuse existing clip.set plumbing).
- **Adjacency: by MCMView position** — neighbor = nearest computer in the pushed direction.
