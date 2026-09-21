package main

import (
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"time"
)

// Per-connection RT1 state: the pairing ceremony, the session handshake, and
// the sealed-line codec once the handshake completes.
//
// The security property this type exists to enforce is simple and absolute:
// **open is false until a paired device has proved possession of its static
// key.** dispatch refuses to act on anything except the handful of handshake
// messages while it is false, so a peer on the Wi-Fi can no longer type, read
// the clipboard, pull a file, or evict a live session.
//
// It is per-connection, never global: counters and keys belong to one socket,
// and a stale frame from a previous connection must never decrypt against the
// new one's key schedule.
type rt1State struct {
	phase rt1Phase

	device *pairedDevice

	ephemeral   *ecdh.PrivateKey
	expectedMAC []byte
	replyMAC    []byte
	pending     *pairedDevice

	keyIn      []byte
	keyOut     []byte
	counterIn  uint64
	counterOut uint64
}

type rt1Phase int

const (
	rt1PhaseFresh rt1Phase = iota
	rt1PhasePairing
	rt1PhaseAwaiting
	rt1PhaseOpen
	rt1PhaseLegacy
)

// GCM with a 64-bit counter is safe far past this, but a counter that has run
// away means something is wrong. Refuse rather than wrap.
const rt1CounterLimit uint64 = 1 << 32

var errRT1Closed = errors.New("rt1: connection is not open")

func (s *rt1State) isOpen() bool { return s.phase == rt1PhaseOpen }

// isPairing reports whether this connection has begun a pairing ceremony that
// has not yet finished — the state a pair.cancel, or a dropped socket, ends.
func (s *rt1State) isPairing() bool { return s.phase == rt1PhasePairing }

// cancelPairing handles pair.cancel: the phone abandoned the ceremony it began
// on this connection. Back to fresh, so that a later drop of this socket is not
// mistaken for a phone vanishing mid-ceremony — by then another phone may have
// minted a new code, and this socket must not be the one that retires it.
func (s *rt1State) cancelPairing() {
	if s.phase != rt1PhasePairing {
		return
	}
	s.phase = rt1PhaseFresh
	s.pending = nil
	s.ephemeral = nil
	s.expectedMAC, s.replyMAC = nil, nil
}

// ------------------------------------------------------------------ pairing

// beginPairing handles pair.begin and returns the reply to send.
func (s *rt1State) beginPairing(dev, spkPhoneB64, epkPhoneB64, name, platform, code, hostName string) map[string]any {
	if code == "" {
		// No code showing. The host raises its pairing window; the phone
		// retries when the user taps. Not an error — the ordinary first run is
		// the phone asking before anyone has opened the window.
		return map[string]any{"t": "pair.no", "why": "nocode"}
	}
	code8, err := rt1CodeBytes(code)
	if err != nil {
		return map[string]any{"t": "pair.no", "why": "nocode"}
	}
	// A REPEAT pair.begin restarts the ceremony rather than being refused. The
	// phone sends one to raise the window, and another when the user has
	// finished typing — and a host that answers the second with "busy" tells
	// the user another phone is pairing when the truth is that they took a few
	// seconds to read a code. The later phases are different: those belong to a
	// session that is already proving itself.
	if s.phase != rt1PhaseFresh && s.phase != rt1PhasePairing {
		return map[string]any{"t": "pair.no", "why": "busy"}
	}

	spkPhone, err1 := base64.StdEncoding.DecodeString(spkPhoneB64)
	epkPhoneDER, err2 := base64.StdEncoding.DecodeString(epkPhoneB64)
	if err1 != nil || err2 != nil {
		return map[string]any{"t": "pair.no", "why": "mac"}
	}
	epkPhone, err := rt1ParsePublic(epkPhoneDER)
	if err != nil {
		return map[string]any{"t": "pair.no", "why": "mac"}
	}

	e, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		return map[string]any{"t": "pair.no", "why": "mac"}
	}
	z, err := rt1ECDH(e, epkPhone)
	if err != nil {
		return map[string]any{"t": "pair.no", "why": "mac"}
	}
	epkHost, err := rt1MarshalPublic(e.PublicKey())
	if err != nil {
		return map[string]any{"t": "pair.no", "why": "mac"}
	}

	s.ephemeral = e
	result := rt1Pairing(dev, identity.hostID, spkPhone, identity.spki,
		epkPhoneDER, epkHost, name, hostName, z, code8)
	s.expectedMAC = result.MACPhone
	s.replyMAC = result.MACHost
	s.pending = &pairedDevice{
		Dev: dev, SPK: base64.StdEncoding.EncodeToString(spkPhone),
		Name: name, Platform: platform, PairedAt: time.Now(),
	}
	s.phase = rt1PhasePairing

	return map[string]any{
		"t": "pair.hi", "rt": rt1Version,
		"hid":  identity.hostID,
		"spk":  base64.StdEncoding.EncodeToString(identity.spki),
		"epk":  base64.StdEncoding.EncodeToString(epkHost),
		"name": hostName, "os": "windows",
	}
}

// confirmPairing handles pair.conf. On success the device is persisted and the
// connection continues straight into a session handshake on the same socket —
// no reconnect.
func (s *rt1State) confirmPairing(macB64 string) (map[string]any, *pairedDevice) {
	mac, err := base64.StdEncoding.DecodeString(macB64)
	if s.phase != rt1PhasePairing || s.pending == nil || err != nil {
		return map[string]any{"t": "pair.no", "why": "mac"}, nil
	}
	if !rt1ConstantTimeEqual(mac, s.expectedMAC) {
		s.phase = rt1PhaseFresh
		s.pending = nil
		return map[string]any{"t": "pair.no", "why": "mac"}, nil
	}
	d := *s.pending
	identity.remember(d)
	s.phase = rt1PhaseFresh // the session handshake follows on this socket
	s.pending = nil
	return map[string]any{"t": "pair.ok", "mac": base64.StdEncoding.EncodeToString(s.replyMAC)}, &d
}

// ------------------------------------------------------------------ session

// beginSession handles an RT1 hello: finds the paired device by tag, derives
// the session keys, and returns the fields to merge into `hi`. A nil map means
// the second return value is the failure to send instead.
func (s *rt1State) beginSession(tagB64, nonceB64, epkB64 string) (map[string]any, map[string]any) {
	unknown := map[string]any{"t": "rt.no", "why": "unknown"}

	tag, err1 := base64.StdEncoding.DecodeString(tagB64)
	nonceP, err2 := base64.StdEncoding.DecodeString(nonceB64)
	epkPhoneDER, err3 := base64.StdEncoding.DecodeString(epkB64)
	if err1 != nil || err2 != nil || err3 != nil {
		return nil, unknown
	}
	epkPhone, err := rt1ParsePublic(epkPhoneDER)
	if err != nil {
		return nil, unknown
	}

	dev := identity.deviceMatching(tag, nonceP)
	if dev == nil {
		// Not a device we know. Say so plainly — the phone shows "this
		// computer doesn't recognise this phone" and offers to pair.
		return nil, unknown
	}
	spkPhoneDER, err := base64.StdEncoding.DecodeString(dev.SPK)
	if err != nil {
		return nil, unknown
	}
	spkPhone, err := rt1ParsePublic(spkPhoneDER)
	if err != nil {
		return nil, unknown
	}

	e, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		return nil, unknown
	}
	epkHost, err := rt1MarshalPublic(e.PublicKey())
	if err != nil {
		return nil, unknown
	}
	nonceH := make([]byte, 16)
	if _, err := rand.Read(nonceH); err != nil {
		return nil, unknown
	}

	zee, e1 := rt1ECDH(e, epkPhone)
	zes, e2 := rt1ECDH(identity.priv, epkPhone)
	zse, e3 := rt1ECDH(e, spkPhone)
	if e1 != nil || e2 != nil || e3 != nil {
		return nil, unknown
	}

	keys := rt1Session(dev.Dev, identity.hostID, spkPhoneDER, identity.spki,
		epkPhoneDER, epkHost, nonceP, nonceH, zee, zes, zse)

	s.ephemeral = e
	s.expectedMAC = keys.MACPhone
	s.replyMAC = keys.MACHost
	s.keyIn = keys.PhoneToHost
	s.keyOut = keys.HostToPhone
	s.counterIn = 0
	s.counterOut = 0
	s.device = dev
	s.phase = rt1PhaseAwaiting

	return map[string]any{
		"rt": rt1Version, "hid": identity.hostID,
		"n":   base64.StdEncoding.EncodeToString(nonceH),
		"epk": base64.StdEncoding.EncodeToString(epkHost),
	}, nil
}

// confirmSession handles rt.conf — the phone's last plaintext line. The reply,
// rt.ok, is ours, and must also go out in the clear (RT1 §3).
func (s *rt1State) confirmSession(macB64 string) map[string]any {
	mac, err := base64.StdEncoding.DecodeString(macB64)
	if s.phase != rt1PhaseAwaiting || err != nil || !rt1ConstantTimeEqual(mac, s.expectedMAC) {
		s.phase = rt1PhaseFresh
		s.device = nil
		return map[string]any{"t": "rt.no", "why": "mac"}
	}
	s.phase = rt1PhaseOpen
	if s.device != nil {
		identity.noteSeen(s.device.Dev)
	}
	return map[string]any{"t": "rt.ok", "mac": base64.StdEncoding.EncodeToString(s.replyMAC)}
}

func (s *rt1State) markLegacy() { s.phase = rt1PhaseLegacy }

// -------------------------------------------------------------- sealed lines

// open decrypts one received line. Any failure is fatal for the connection: a
// distinguishable error would be a decryption oracle, so the caller closes
// rather than replying.
func (s *rt1State) open(line []byte) ([]byte, error) {
	if s.phase != rt1PhaseOpen {
		return nil, errRT1Closed
	}
	if s.counterIn >= rt1CounterLimit {
		return nil, errors.New("rt1: counter exhausted")
	}
	sealed, err := base64.StdEncoding.DecodeString(string(line))
	if err != nil {
		return nil, errors.New("rt1: decrypt failed")
	}
	plain, err := rt1Open(sealed, s.keyIn, rt1PrefixPhoneToHost, s.counterIn)
	if err != nil {
		return nil, err
	}
	s.counterIn++
	return plain, nil
}

// seal encrypts one line for sending. The caller MUST hold the connection's
// write lock: the counter is sequential, and two goroutines sealing at once
// would put records on the wire out of order and break the phone's decryption
// for the rest of the connection — not just for those frames.
func (s *rt1State) seal(jsonBytes []byte) ([]byte, error) {
	if s.phase != rt1PhaseOpen {
		return nil, errRT1Closed
	}
	if s.counterOut >= rt1CounterLimit {
		return nil, errors.New("rt1: counter exhausted")
	}
	sealed, err := rt1Seal(jsonBytes, s.keyOut, rt1PrefixHostToPhone, s.counterOut)
	if err != nil {
		return nil, err
	}
	s.counterOut++
	return []byte(base64.StdEncoding.EncodeToString(sealed)), nil
}
