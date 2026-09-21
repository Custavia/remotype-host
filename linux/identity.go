package main

import (
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// The host's long-term identity, and the phones it has paired with.
//
// Stored as plain mode-0600 files under $XDG_CONFIG_HOME/remotype-host
// (~/.config/remotype-host), matching the macOS and Windows hosts' decision to
// use a private file rather than a platform keystore. The reasoning is the same
// on all three: a credential store keyed to the code signature loses every
// pairing on an update, and the threat model here is "a peer on your Wi-Fi",
// not "an attacker who can already read your files as you". A secret-service
// backend would add real protection against the second and nothing against the
// first — so it is a future refinement, not a prerequisite.
//
//	identity.bin   32-byte P-256 private scalar ‖ 16-byte host id
//	devices.json   the paired phones

type pairedDevice struct {
	Dev      string     `json:"dev"` // 32 hex, the phone's id
	SPK      string     `json:"spk"` // base64 SPKI of the phone's static key
	Name     string     `json:"name"`
	Platform string     `json:"platform"`
	PairedAt time.Time  `json:"pairedAt"`
	LastSeen *time.Time `json:"lastSeen,omitempty"`
}

type hostIdentity struct {
	mu      sync.Mutex
	priv    *ecdh.PrivateKey
	hostID  string
	spki    []byte
	devices []pairedDevice
}

// identity is loaded from main, after the log is set up: a package-level
// initializer would run first and its "generated a new host identity" line —
// the one a user most needs to see — would miss the log file.
var identity *hostIdentity

// identityDir is the XDG config directory: identity and pairings are
// configuration, not cache — a cache is something the desktop may wipe, and a
// wiped identity means every phone has to pair again.
func identityDir() string {
	base, err := os.UserConfigDir() // $XDG_CONFIG_HOME or ~/.config
	if err != nil || base == "" {
		base, _ = os.UserHomeDir()
	}
	dir := filepath.Join(base, "remotype-host")
	_ = os.MkdirAll(dir, 0o700)
	return dir
}

func loadIdentity() *hostIdentity {
	id := &hostIdentity{}
	file := filepath.Join(identityDir(), "identity.bin")

	if raw, err := os.ReadFile(file); err == nil && len(raw) == 48 {
		if priv, err := ecdh.P256().NewPrivateKey(raw[:32]); err == nil {
			id.priv = priv
			id.hostID = hex.EncodeToString(raw[32:])
		}
	}

	if id.priv == nil {
		// First run, or an unreadable file. A new identity means every phone
		// paired before now sees an unknown host and has to pair again — which
		// is exactly the alarm we want if the file was tampered with, and is
		// unavoidable if it was lost.
		priv, err := ecdh.P256().GenerateKey(rand.Reader)
		if err != nil {
			// Without an identity there is no RT1 and therefore no input at
			// all. Fail loudly rather than falling back to something open.
			logf("RT1: FATAL — could not generate a host identity: %v", err)
			panic("RT1: no host identity")
		}
		idBytes := make([]byte, 16)
		_, _ = rand.Read(idBytes)
		id.priv = priv
		id.hostID = hex.EncodeToString(idBytes)

		blob := append(append([]byte{}, priv.Bytes()...), idBytes...)
		writePrivate(file, blob)
		logf("RT1: generated a new host identity (%s…)", id.hostID[:8])
	}

	id.spki, _ = rt1MarshalPublic(id.priv.PublicKey())
	id.devices = id.loadDevices()
	return id
}

// writePrivate creates the file with owner-only permissions from the start.
// Writing and then chmod'ing leaves a window in which the private key is
// readable by everyone.
func writePrivate(path string, data []byte) {
	_ = os.Remove(path)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		logf("RT1: could not write %s: %v", filepath.Base(path), err)
	}
}

func (h *hostIdentity) devicesFile() string {
	return filepath.Join(identityDir(), "devices.json")
}

func (h *hostIdentity) loadDevices() []pairedDevice {
	raw, err := os.ReadFile(h.devicesFile())
	if err != nil {
		return nil
	}
	var list []pairedDevice
	if json.Unmarshal(raw, &list) != nil {
		return nil
	}
	return list
}

func (h *hostIdentity) saveLocked() {
	if data, err := json.Marshal(h.devices); err == nil {
		writePrivate(h.devicesFile(), data)
	}
}

// deviceMatching walks the stored devices computing the tag until one matches.
// A handful of SHA-256s, and it keeps a stable device identifier off the wire.
func (h *hostIdentity) deviceMatching(tag, nonce []byte) *pairedDevice {
	h.mu.Lock()
	defer h.mu.Unlock()
	for i := range h.devices {
		spk, err := base64.StdEncoding.DecodeString(h.devices[i].SPK)
		if err != nil {
			continue
		}
		if rt1ConstantTimeEqual(rt1DeviceTag(nonce, spk), tag) {
			d := h.devices[i]
			return &d
		}
	}
	return nil
}

func (h *hostIdentity) remember(d pairedDevice) {
	h.mu.Lock()
	kept := h.devices[:0]
	for _, existing := range h.devices {
		if existing.Dev != d.Dev { // re-pairing replaces
			kept = append(kept, existing)
		}
	}
	h.devices = append(kept, d)
	h.saveLocked()
	h.mu.Unlock()
	logf("RT1: paired with %s (%s)", d.Name, d.Platform)
}

func (h *hostIdentity) forget(dev string) {
	h.mu.Lock()
	name := ""
	kept := make([]pairedDevice, 0, len(h.devices))
	for _, d := range h.devices {
		if d.Dev == dev {
			name = d.Name
			continue
		}
		kept = append(kept, d)
	}
	h.devices = kept
	h.saveLocked()
	h.mu.Unlock()
	if name != "" {
		logf("RT1: removed paired device %s", name)
	}
}

func (h *hostIdentity) forgetAll() {
	h.mu.Lock()
	h.devices = nil
	h.saveLocked()
	h.mu.Unlock()
	logf("RT1: removed all paired devices")
}

func (h *hostIdentity) noteSeen(dev string) {
	h.mu.Lock()
	now := time.Now()
	for i := range h.devices {
		if h.devices[i].Dev == dev {
			h.devices[i].LastSeen = &now
			h.saveLocked()
			break
		}
	}
	h.mu.Unlock()
}

func (h *hostIdentity) list() []pairedDevice {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := make([]pairedDevice, len(h.devices))
	copy(out, h.devices)
	return out
}
