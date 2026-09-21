# RT1 — the Remotype trust layer

> **Status: FROZEN SPEC.** Written before any implementation, on purpose. Four
> hand-written implementations across Swift, Go and Kotlin only agree if they are
> all writing down the same thing — so this document, and the test vectors in
> `spec/rt1/vectors.json`, are the source of truth. If an implementation
> disagrees with this file, the implementation is wrong.
>
> Derived from an internal design review that weighed three candidate schemes
> against three adversarial critiques; this is the one that survived.

## Why this exists

Before RT1, the Wi-Fi transport had no authentication and no encryption. The
`hello` was a version handshake, and the survey that preceded this spec found it
was weaker even than documented:

- **Input injection bypassed the gate entirely.** `key`, `text`, `mm`, `mc` and
  the rest never appear in either switch and fall through to the injection tail.
  Only the macOS Accessibility grant stood between a LAN peer and typing into
  someone's computer.
- **`clip.file.pull` was reachable before the gate** — a peer could pull a file
  off the machine.
- **`tv.pan` and `ovl.timer` were accidentally omitted** from the v2 case lists.
- **Any peer could evict a live session** by opening a socket
  (`Server.swift:474`).

The fix is not a bigger gate. It is a guard at the one chokepoint every message
passes through, and a transport that is authenticated and encrypted end to end.

## Scope

- Applies to the **Wi-Fi transport only**. Android's Bluetooth HID path is
  already link-encrypted by Bluetooth pairing and is unchanged.
- No server, no account, no internet. Everything below happens on the LAN.

---

## 2. Wire protocol

Written to drop into `PROTOCOL.md` in its existing voice.

### 2.0 Primitives

| Role | Choice | macOS/iOS | Windows (Go) | Android |
|---|---|---|---|---|
| Key agreement | **ECDH P-256** | `CryptoKit.P256.KeyAgreement` | `crypto/ecdh.P256()` | `KeyAgreement("ECDH")` + `ECGenParameterSpec("secp256r1")` |
| Hash | SHA-256 | `CryptoKit.SHA256` | `crypto/sha256` | `MessageDigest` |
| MAC | HMAC-SHA-256 | `CryptoKit.HMAC<SHA256>` | `crypto/hmac` | `Mac("HmacSHA256")` |
| KDF | HKDF-SHA-256, **hand-rolled from HMAC in all four** | — | — | — |
| AEAD | AES-256-GCM | `CryptoKit.AES.GCM` | `crypto/aes`+`crypto/cipher` | `Cipher("AES/GCM/NoPadding")` |
| CSPRNG | platform | `SystemRandomNumberGenerator` | `crypto/rand` | `SecureRandom` |
| Const-time compare | — | `HMAC.isValidAuthenticationCode` | `crypto/subtle` | `MessageDigest.isEqual` |

P-256, not X25519: `java/security/spec/NamedParameterSpec` is `since="33"` and `minSdk = 28` (verified, `the Android client's build configuration`). HKDF is hand-rolled everywhere so the Go module never needs the `go 1.24` directive bump for `crypto/hkdf`, and so all four are byte-identical by construction rather than by three different vendors' interpretations. Test against RFC 5869 vectors in each codebase.

Zero new dependencies in any codebase. `GOOS=windows CGO_ENABLED=0` stays clean.

**Encodings — these are the interop landmines, state them once and never deviate:**

- **Public keys on the wire: SPKI DER, base64 (standard alphabet, padded).** `P256.KeyAgreement.PublicKey.derRepresentation` (macOS 11+/iOS 14+; floors are 13/16, fine) / `x509.MarshalPKIXPublicKey` / `PublicKey.getEncoded()` + `X509EncodedKeySpec`. **Not** X9.63 raw points — assembling those on Android needs manual 32-byte left-padding of `ECPoint` affine coordinates and `BigInteger.toByteArray()` emits a leading sign byte. That is the single most common bug in this exact task and SPKI dodges it entirely. All three APIs validate on-curve for free; additionally **reject an all-zero ECDH output**.
- **ID fields (`dev`, `hid`): 32 lowercase hex chars** = 16 random bytes.
- **Every transcript input is length-prefixed**: `LP(x) = u16be(len(x)) ‖ x`. Never concatenate raw. (pake's transcript is a canonicalization hazard without this.)
- **CryptoKit gotcha:** `AES.GCM.SealedBox.combined` prepends the nonce. Put `ciphertext ‖ tag` on the wire and construct the box explicitly. This will be your first interop failure if you forget it.

### 2.1 The pairing code

- **60 bits**, Crockford base32, **12 characters**, displayed as `XXXX-XXXX-XXXX`.
- Normalize before use: uppercase; `I`/`L` → `1`; `O` → `0`; strip everything non-alphanumeric.
- **What is fed to the KDF is the 60-bit integer as 8 bytes big-endian** (top 4 bits zero) — `CODE8`. Never the ASCII. Typing and display variance therefore cannot cause a mismatch.
- Single-use. Window **10 minutes** (we can afford a generous window precisely because it is 60 bits, and the walk-to-the-computer is the real clock). One code live at a time; one ceremony in flight at a time.
- **Three attempts against the same live code**, then it burns and the window closes. This is safe *only* because the code is 60 bits (3/2⁶⁰). **Shortening the code invalidates this rule and reintroduces pake's offline-dictionary break.** Write that comment in the source.
- Rate limit: 5 `pair.begin` per 10 min per source IP.

Why 60 bits is the number: the attack that matters is an on-path or host-impersonating peer that collects a password-derived MAC and brute-forces candidates *while the real window is still open*. Each candidate is ~4 SHA-256 compressions. A 100-GPU rig at ~10¹² tests/s covers ~2⁴⁷ in 120 s. 60 bits is 8,000× beyond that even with a 10-minute window; 20 bits (pake) is cracked in milliseconds; 20-bit SAS truncation (tls-psk, noise-or-box) falls to a ~2,000-keygen birthday meet-in-the-middle.

### 2.2 Pairing messages

Runs on the existing plaintext newline-JSON transport, immediately after the ordinary `hello`/`hi`.

```jsonc
// phone → host
{"t":"pair.begin","rt":1,"dev":"<32 hex>","spk":"<b64 SPKI>","epk":"<b64 SPKI>",
 "name":"Pratik’s iPhone","plat":"ios"}

// host → phone. A pair.begin ALWAYS gets the host to show a code: if none is live
// the host mints one and raises its pairing panel first, then answers this same
// begin with pair.hi — one tap on the phone, and the code is on the host's screen
// with the phone already asking for it. (Both hosts, since 2026-09-09; the Mac
// used to answer nocode and wait for a second tap.)
{"t":"pair.hi","rt":1,"hid":"<32 hex>","spk":"<b64 SPKI>","epk":"<b64 SPKI>",
 "name":"MacBook Pro","os":"mac"}
// host → phone  (the host could not show a code at all — nothing to type against;
//                phones treat it like a cancelled ceremony and let the user retry)
{"t":"pair.no","why":"nocode"}
{"t":"pair.no","why":"busy"}          // another ceremony in flight

// phone → host
{"t":"pair.conf","mac":"<b64 32B>"}
{"t":"pair.cancel"}                     // phone → host: the user cancelled on the phone. Host retires the
                                        // live code and shows "Pairing was cancelled on phone" where the
                                        // code was. A pairing socket that drops WITHOUT this is treated the
                                        // same way with gentler words ("disconnected before pairing finished").

// host → phone
{"t":"pair.ok","mac":"<b64 32B>"}
{"t":"pair.no","why":"mac"|"expired"|"limit"}
```

Both sides derive:

```
Z   = ECDH(e_self_priv, e_peer_pub)                       // 32 bytes; reject all-zero
TH  = SHA256( LP("RT1-PAIR") ‖ LP(dev) ‖ LP(hid) ‖ LP(spk_p) ‖ LP(spk_h)
              ‖ LP(epk_p) ‖ LP(epk_h) ‖ LP(name_p) ‖ LP(name_h) )
PRK = HKDF-Extract(salt = TH, ikm = Z ‖ CODE8)
Kp  = HKDF-Expand(PRK, "rt1 pair phone", 32)
Kh  = HKDF-Expand(PRK, "rt1 pair host",  32)
mac_p = HMAC(Kp, 0x01)      // phone → host, in pair.conf
mac_h = HMAC(Kh, 0x02)      // host  → phone, in pair.ok
```

The code enters `HKDF-Extract`, not just a MAC: a wrong code yields a *completely different* key, so a guessing attacker gets neither authentication nor confidentiality. Both static public keys are inside `TH`, so the code authenticates exactly the keys that will be pinned — that is the whole security argument in one line.

Host verifies `mac_p` in constant time, then burns the code, then persists `{dev, spk_p, name, plat, pairedAt, lastSeen}`, then sends `pair.ok`. Phone verifies `mac_h` **before** persisting `{hid, spk_h, name, os, pairedAt}`. Neither side stores anything on a failure.

After `pair.ok` the connection continues straight into a session handshake on the same socket — no reconnect, no re-dial.

### 2.3 Session messages (every connect, silent)

```jsonc
// phone → host — replaces today’s hello for RT1 phones
{"t":"hello","v":2,"rt":1,"tag":"<b64 32B>","n":"<b64 16B>","epk":"<b64 SPKI>"}

// host → phone — the existing hi, plus rt/hid/n/epk
{"t":"hi","v":2,"rt":1,"hid":"<32 hex>","n":"<b64 16B>","epk":"<b64 SPKI>",
 "name":"MacBook Pro","os":"mac","cast":2,"browser":1,"audio":1}

// host → phone — tag matched no paired device
{"t":"rt.no","why":"unknown"}

// phone → host
{"t":"rt.conf","mac":"<b64 32B>"}

// host → phone
{"t":"rt.ok","mac":"<b64 32B>"}
{"t":"rt.no","why":"mac"}
```

```
tag = SHA256( LP("RT1-TAG") ‖ LP(n_p) ‖ LP(spk_p) )
```
The host walks its ≤8 stored devices computing `tag` until one matches (8 SHA-256 — free). This keeps a stable device identifier off the wire; the phone's `name` also moves inside the encrypted channel (sent as `{"t":"rt.id","name":"…"}` as its first sealed line). Both are **cuttable under time pressure** — see §6.

```
Zee = ECDH(e_p, e_h)
Zes = ECDH(e_p, S_h)     // phone: e_p×S_h ; host: s_h×e_p
Zse = ECDH(S_p, e_h)     // phone: s_p×e_h ; host: e_h×S_p
TH  = SHA256( LP("RT1-SESS") ‖ LP(dev) ‖ LP(hid) ‖ LP(spk_p) ‖ LP(spk_h)
              ‖ LP(epk_p) ‖ LP(epk_h) ‖ LP(n_p) ‖ LP(n_h) )
PRK   = HKDF-Extract(salt = TH, ikm = Zee ‖ Zes ‖ Zse)
k_p2h = HKDF-Expand(PRK, "rt1 c2h key", 32)
k_h2p = HKDF-Expand(PRK, "rt1 h2c key", 32)
Mp    = HKDF-Expand(PRK, "rt1 c2h mac", 32)
Mh    = HKDF-Expand(PRK, "rt1 h2c mac", 32)
mac_p = HMAC(Mp, 0x01) ; mac_h = HMAC(Mh, 0x02)
```

Triple-DH: `Zee` gives forward secrecy, `Zes` proves the host holds `s_h`, `Zse` proves the phone holds `s_p`. Mutual authentication with one primitive and no signatures — deliberately avoiding the ECDSA DER-vs-raw encoding trap. Three P-256 ECDHs per connect, sub-millisecond on every target.

**Framing switchover, stated exactly:** `rt.conf` is the phone's last plaintext line; `rt.ok` is the host's last plaintext line. The phone sends nothing between `rt.conf` and receiving `rt.ok`. Everything after is sealed, both directions.

### 2.4 Sealed line format

```
plaintext = u32be(jsonLen) ‖ json ‖ zero-pad to the next multiple of 64
line      = base64std( AES-256-GCM_Seal(k_dir, nonce, aad = "", plaintext) ) ‖ "\n"
nonce     = dirPrefix(4B) ‖ counter(8B BE)
dirPrefix = "RTCH" (phone→host) | "RTHC" (host→phone)
counter   = 0, +1 per sealed line per direction; close the connection at 2^32

The length is **u32, not u16**. A 16-bit length caps a frame at 64 KB, and a TV
frame is a base64 JPEG of the whole screen — around 80 KB, sometimes more. The
first build shipped u16 and the macOS host died on a `precondition` the moment
screen mirroring started over a sealed link; the Kotlin and Go sides would have
failed quietly instead, which is worse. Nothing else about the frame changed.
```

The padding hides a 1-character `key` frame from a `mod` frame and costs 4 lines of code; it cannot be added later without a version bump, so it ships in v1. Any decrypt failure → immediate connection close, no error frame on the wire (no oracle).

Buffer caps grow by 4/3 + 88 bytes: Go's `sc.Buffer` max line 1 MiB → 2 MiB; `RX_BUFFER_CAP` and iOS's `clipboardByteCap * 2` likewise.

### 2.5 Discovery and negotiation

Bonjour TXT gains `rt=1` and `hid=<first 16 hex of hid>` beside the existing `os=`. **TXT is a hint for list rendering only** (badge a paired computer, show "Not secured" before dialing). It is attacker-controlled and is **never** used to decide whether encryption is required — that is decided in-band from `hi`, against local storage keyed by `hid`. This is what makes RT1 immune to the failure mode where a mesh Wi-Fi that mangles mDNS TXT records turns a working paired setup into a hard refusal.

**Anti-downgrade, absolute:**

1. Phone holds a trust record for `hi.hid` and `hi` lacks `rt:1` → **hard refuse**, no override.
2. Phone holds a trust record whose remembered service name matches this host and `hi` carries neither `rt` nor `hid` → **hard refuse**, same message. (Blocks name-impersonation of a paired host by a legacy-looking peer.)
3. No record at all → the legacy sheet in §4 with a one-shot, per-host, never-remembered override.
4. A forced re-pair gains an attacker nothing: the fresh code is 60 bits and is shown on the real machine's screen. This is a structural advantage of a typed code over any SAS scheme.

---
