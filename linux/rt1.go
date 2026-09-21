package main

// RT1 — the Remotype trust layer. See docs/RT1.md; that document is the source
// of truth and this file implements it. Conformance is proved against
// spec/rt1/vectors.json by rt1_selftest.go, which runs at startup.
//
// Portable on purpose: no build tags, no cgo, standard library only. The same
// file therefore compiles for the Windows host, and later for the Linux host,
// without a second implementation to keep in step.
//
// Three rules are load-bearing here, and each is a real bug in somebody's
// implementation of exactly this:
//
//  1. Every transcript input is length-prefixed. Raw concatenation lets two
//     different field sets produce the same transcript.
//  2. Public keys are SPKI DER, never raw X9.63 points.
//  3. The wire format is ciphertext ‖ tag, and Go's AEAD Seal appends the tag
//     to the ciphertext — which is what we want, but it means the tag is NOT a
//     separate field and must not be moved.

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/x509"
	"encoding/binary"
	"errors"
	"fmt"
	"strings"
)

const rt1Version = 1

var (
	errRT1BadKey     = errors.New("rt1: bad public key")
	errRT1Degenerate = errors.New("rt1: degenerate ECDH output")
	errRT1BadCode    = errors.New("rt1: bad pairing code")
	errRT1Decrypt    = errors.New("rt1: decrypt failed")
)

// ---------------------------------------------------------------- primitives

// lp implements LP(x) = u16be(len(x)) ‖ x.
func lp(b []byte) []byte {
	if len(b) > 0xFFFF {
		panic("rt1: transcript field too long")
	}
	out := make([]byte, 2, 2+len(b))
	binary.BigEndian.PutUint16(out, uint16(len(b)))
	return append(out, b...)
}

func lps(s string) []byte { return lp([]byte(s)) }

// hkdfExtract / hkdfExpand are hand-rolled from HMAC so all four
// implementations are byte-identical by construction. (crypto/hkdf would also
// force the module's go directive to 1.24.)
func hkdfExtract(salt, ikm []byte) []byte {
	m := hmac.New(sha256.New, salt)
	m.Write(ikm)
	return m.Sum(nil)
}

func hkdfExpand(prk, info []byte, length int) []byte {
	var out, t []byte
	for counter := byte(1); len(out) < length; counter++ {
		m := hmac.New(sha256.New, prk)
		m.Write(t)
		m.Write(info)
		m.Write([]byte{counter})
		t = m.Sum(nil)
		out = append(out, t...)
	}
	return out[:length]
}

func rt1HMAC(key, msg []byte) []byte {
	m := hmac.New(sha256.New, key)
	m.Write(msg)
	return m.Sum(nil)
}

// rt1ECDH rejects the all-zero shared secret: it means the peer sent a
// degenerate point, and deriving keys from it hands the attacker a key they
// already know.
func rt1ECDH(priv *ecdh.PrivateKey, pub *ecdh.PublicKey) ([]byte, error) {
	z, err := priv.ECDH(pub)
	if err != nil {
		return nil, errRT1BadKey
	}
	var any byte
	for _, b := range z {
		any |= b
	}
	if any == 0 {
		return nil, errRT1Degenerate
	}
	return z, nil
}

// rt1ParsePublic reads an SPKI DER public key and confirms it is P-256.
// x509 validates that the point is on the curve, so an off-curve key fails here.
func rt1ParsePublic(der []byte) (*ecdh.PublicKey, error) {
	pub, err := x509.ParsePKIXPublicKey(der)
	if err != nil {
		return nil, errRT1BadKey
	}
	// crypto/ecdh keys come back as *ecdh.PublicKey; crypto/elliptic ones as
	// *ecdsa.PublicKey. Accept either shape, but insist on P-256.
	switch k := pub.(type) {
	case *ecdh.PublicKey:
		if k.Curve() != ecdh.P256() {
			return nil, errRT1BadKey
		}
		return k, nil
	default:
		if conv, ok := pub.(interface {
			ECDH() (*ecdh.PublicKey, error)
		}); ok {
			k2, err := conv.ECDH()
			if err != nil {
				return nil, errRT1BadKey
			}
			if k2.Curve() != ecdh.P256() {
				return nil, errRT1BadKey
			}
			return k2, nil
		}
		return nil, errRT1BadKey
	}
}

func rt1MarshalPublic(pub *ecdh.PublicKey) ([]byte, error) {
	return x509.MarshalPKIXPublicKey(pub)
}

func rt1ConstantTimeEqual(a, b []byte) bool {
	return subtle.ConstantTimeCompare(a, b) == 1
}

// ---------------------------------------------------------------- the code

// Crockford base32. I/L/O are absent by design and fold to 1/1/0 on input, so a
// misread character cannot cause a mismatch.
const rt1Crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

func rt1NormalizeCode(text string) string {
	var sb strings.Builder
	for _, r := range strings.ToUpper(text) {
		switch r {
		case 'I', 'L':
			r = '1'
		case 'O':
			r = '0'
		}
		if (r >= '0' && r <= '9') || (r >= 'A' && r <= 'Z') {
			sb.WriteRune(r)
		}
	}
	return sb.String()
}

// rt1CodeBytes returns CODE8 — the 60-bit code as 8 bytes big-endian. What is
// fed to the KDF is this, never the ASCII.
func rt1CodeBytes(text string) ([]byte, error) {
	norm := rt1NormalizeCode(text)
	if len(norm) != 12 {
		return nil, errRT1BadCode
	}
	var v uint64
	for _, r := range norm {
		idx := strings.IndexRune(rt1Crockford, r)
		if idx < 0 {
			return nil, errRT1BadCode
		}
		v = v<<5 | uint64(idx)
	}
	if v >= 1<<60 {
		return nil, errRT1BadCode
	}
	out := make([]byte, 8)
	binary.BigEndian.PutUint64(out, v)
	return out, nil
}

// rt1GenerateCode returns a fresh 60-bit code formatted XXXX-XXXX-XXXX.
//
// 60 bits is not decoration: the three-attempt rule is safe only because
// guessing is 3/2^60. A shorter code would make that rule meaningless and
// reintroduce an offline dictionary attack, because the code enters the KDF and
// a wrong guess is testable offline against the MAC. Do not shorten it.
func rt1GenerateCode() (string, error) {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	v := binary.BigEndian.Uint64(b[:]) & (1<<60 - 1)
	out := make([]byte, 12)
	for i := 11; i >= 0; i-- {
		out[i] = rt1Crockford[v&31]
		v >>= 5
	}
	return fmt.Sprintf("%s-%s-%s", out[0:4], out[4:8], out[8:12]), nil
}

// ---------------------------------------------------------------- pairing

type rt1PairResult struct {
	Transcript []byte
	MACPhone   []byte // expected from the phone, in pair.conf
	MACHost    []byte // sent to the phone, in pair.ok
}

// rt1Pairing derives the pairing MACs. The code goes into HKDF-Extract, not
// into a comparison: a wrong code produces entirely different keys, so a
// guessing peer gets neither authentication nor confidentiality.
func rt1Pairing(dev, hid string, spkPhone, spkHost, epkPhone, epkHost []byte,
	namePhone, nameHost string, z, code8 []byte) rt1PairResult {

	var th []byte
	th = append(th, lps("RT1-PAIR")...)
	th = append(th, lps(dev)...)
	th = append(th, lps(hid)...)
	th = append(th, lp(spkPhone)...)
	th = append(th, lp(spkHost)...)
	th = append(th, lp(epkPhone)...)
	th = append(th, lp(epkHost)...)
	th = append(th, lps(namePhone)...)
	th = append(th, lps(nameHost)...)
	sum := sha256.Sum256(th)

	ikm := append(append([]byte{}, z...), code8...)
	prk := hkdfExtract(sum[:], ikm)
	kp := hkdfExpand(prk, []byte("rt1 pair phone"), 32)
	kh := hkdfExpand(prk, []byte("rt1 pair host"), 32)
	return rt1PairResult{
		Transcript: sum[:],
		MACPhone:   rt1HMAC(kp, []byte{0x01}),
		MACHost:    rt1HMAC(kh, []byte{0x02}),
	}
}

// ---------------------------------------------------------------- session

type rt1SessionKeys struct {
	PhoneToHost []byte
	HostToPhone []byte
	MACPhone    []byte
	MACHost     []byte
}

// rt1DeviceTag = SHA256(LP("RT1-TAG") ‖ LP(n_p) ‖ LP(spk_p)) — lets the host
// find which paired device is calling without that identity crossing the wire.
func rt1DeviceTag(nonce, spkPhone []byte) []byte {
	var t []byte
	t = append(t, lps("RT1-TAG")...)
	t = append(t, lp(nonce)...)
	t = append(t, lp(spkPhone)...)
	sum := sha256.Sum256(t)
	return sum[:]
}

// rt1Session performs the triple-DH derivation: Zee gives forward secrecy, Zes
// proves the host holds its static key, Zse proves the phone holds its own.
func rt1Session(dev, hid string, spkPhone, spkHost, epkPhone, epkHost,
	noncePhone, nonceHost, zee, zes, zse []byte) rt1SessionKeys {

	var th []byte
	th = append(th, lps("RT1-SESS")...)
	th = append(th, lps(dev)...)
	th = append(th, lps(hid)...)
	th = append(th, lp(spkPhone)...)
	th = append(th, lp(spkHost)...)
	th = append(th, lp(epkPhone)...)
	th = append(th, lp(epkHost)...)
	th = append(th, lp(noncePhone)...)
	th = append(th, lp(nonceHost)...)
	sum := sha256.Sum256(th)

	ikm := make([]byte, 0, len(zee)+len(zes)+len(zse))
	ikm = append(append(append(ikm, zee...), zes...), zse...)
	prk := hkdfExtract(sum[:], ikm)

	return rt1SessionKeys{
		PhoneToHost: hkdfExpand(prk, []byte("rt1 c2h key"), 32),
		HostToPhone: hkdfExpand(prk, []byte("rt1 h2c key"), 32),
		MACPhone:    rt1HMAC(hkdfExpand(prk, []byte("rt1 c2h mac"), 32), []byte{0x01}),
		MACHost:     rt1HMAC(hkdfExpand(prk, []byte("rt1 h2c mac"), 32), []byte{0x02}),
	}
}

// ---------------------------------------------------------------- sealed lines

var (
	rt1PrefixPhoneToHost = []byte("RTCH")
	rt1PrefixHostToPhone = []byte("RTHC")
)

func rt1Nonce(prefix []byte, counter uint64) []byte {
	n := make([]byte, 12)
	copy(n, prefix)
	binary.BigEndian.PutUint64(n[4:], counter)
	return n
}

// rt1Seal builds u16be(jsonLen) ‖ json ‖ zero-pad-to-64, seals it, and returns
// ciphertext ‖ tag. The padding hides a one-character key frame from a mod
// frame; it cannot be added later without a version bump, so it ships in v1.
func rt1Seal(jsonBytes, key, prefix []byte, counter uint64) ([]byte, error) {
	// u32, not u16. A 16-bit length caps a frame at 64 KB and a TV frame is a
	// base64 JPEG of the whole screen — around 80 KB, sometimes more.
	if len(jsonBytes) > 0xFFFFFFFF {
		return nil, errors.New("rt1: frame too long")
	}
	plain := make([]byte, 4, 4+len(jsonBytes)+64)
	binary.BigEndian.PutUint32(plain, uint32(len(jsonBytes)))
	plain = append(plain, jsonBytes...)
	if pad := (64 - len(plain)%64) % 64; pad > 0 {
		plain = append(plain, make([]byte, pad)...)
	}

	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	// Seal appends the tag to the ciphertext, which is exactly the wire format.
	return gcm.Seal(nil, rt1Nonce(prefix, counter), plain, nil), nil
}

func rt1Open(sealed, key, prefix []byte, counter uint64) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	plain, err := gcm.Open(nil, rt1Nonce(prefix, counter), sealed, nil)
	if err != nil {
		// No distinguishable error goes back on the wire: that would be a
		// decryption oracle. The caller closes the connection.
		return nil, errRT1Decrypt
	}
	if len(plain) < 4 {
		return nil, errRT1Decrypt
	}
	n := int(binary.BigEndian.Uint32(plain[:4]))
	if n < 0 || 4+n > len(plain) {
		return nil, errRT1Decrypt
	}
	return plain[4 : 4+n], nil
}

// rt1PrivFromHex loads a fixed test scalar. Used only by the self-test; real
// identities are generated with crypto/rand.
func rt1PrivFromHex(h string) (*ecdh.PrivateKey, error) {
	raw := make([]byte, len(h)/2)
	for i := 0; i < len(raw); i++ {
		var b int
		if _, err := fmt.Sscanf(h[i*2:i*2+2], "%02x", &b); err != nil {
			return nil, err
		}
		raw[i] = byte(b)
	}
	return ecdh.P256().NewPrivateKey(raw)
}
