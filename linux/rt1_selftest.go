package main

// Proves this build's RT1 against spec/rt1/vectors.json, embedded at compile
// time. Runs at startup, not only under `go test`.
//
// The failure this guards against is not "the algorithm is wrong" — it is "the
// Go, Swift and Kotlin sides drifted apart", which in the field looks like a
// link that connects and then dies, on one platform only.

import (
	_ "embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
)

//go:embed rt1_vectors.json
var rt1VectorsJSON []byte

type rt1Vectors struct {
	FixedKeys map[string]string `json:"fixed_private_keys_hex"`

	HKDF []struct {
		Name    string `json:"name"`
		IKMHex  string `json:"ikm_hex"`
		SaltHex string `json:"salt_hex"`
		InfoHex string `json:"info_hex"`
		L       int    `json:"L"`
		PRKHex  string `json:"prk_hex"`
		OKMHex  string `json:"okm_hex"`
	} `json:"hkdf_rfc5869"`

	Pairing struct {
		Dev         string `json:"dev"`
		Hid         string `json:"hid"`
		NamePhone   string `json:"name_phone"`
		NameHost    string `json:"name_host"`
		CodeText    string `json:"code_text"`
		Code8Hex    string `json:"code8_hex"`
		SpkPhoneB64 string `json:"spk_phone_b64"`
		SpkHostB64  string `json:"spk_host_b64"`
		EpkPhoneB64 string `json:"epk_phone_b64"`
		EpkHostB64  string `json:"epk_host_b64"`
		ZHex        string `json:"Z_hex"`
		THHex       string `json:"TH_hex"`
		PRKHex      string `json:"PRK_hex"`
		MacPhoneB64 string `json:"mac_phone_b64"`
		MacHostB64  string `json:"mac_host_b64"`
	} `json:"pairing"`

	Session struct {
		NPhoneB64  string `json:"n_phone_b64"`
		NHostB64   string `json:"n_host_b64"`
		TagB64     string `json:"tag_b64"`
		ZeeHex     string `json:"Zee_hex"`
		ZesHex     string `json:"Zes_hex"`
		ZseHex     string `json:"Zse_hex"`
		THHex      string `json:"TH_hex"`
		KP2HHex    string `json:"k_phone_to_host_hex"`
		KH2PHex    string `json:"k_host_to_phone_hex"`
		MacHostB64 string `json:"mac_host_b64"`
	} `json:"session"`

	SealedLines []struct {
		Counter  int    `json:"counter"`
		JSON     string `json:"json"`
		NonceHex string `json:"nonce_hex"`
		LineB64  string `json:"line_b64"`
	} `json:"sealed_lines"`

	MustReject struct {
		InvalidPointSPKIB64 string `json:"invalid_point_spki_b64"`
	} `json:"must_reject"`
}

func rt1SelfTest() bool {
	var v rt1Vectors
	if err := json.Unmarshal(rt1VectorsJSON, &v); err != nil {
		logf("RT1 self-test FAILED — vectors unreadable: %v", err)
		return false
	}
	var fails []string
	check := func(label string, ok bool) {
		if !ok {
			fails = append(fails, label)
		}
	}
	dh := func(s string) []byte { b, _ := hex.DecodeString(s); return b }
	db := func(s string) []byte { b, _ := base64.StdEncoding.DecodeString(s); return b }
	eb := base64.StdEncoding.EncodeToString

	// 1 — HKDF against RFC 5869.
	for _, c := range v.HKDF {
		prk := hkdfExtract(dh(c.SaltHex), dh(c.IKMHex))
		check("HKDF PRK "+c.Name, hex.EncodeToString(prk) == c.PRKHex)
		check("HKDF OKM "+c.Name, hex.EncodeToString(hkdfExpand(prk, dh(c.InfoHex), c.L)) == c.OKMHex)
	}

	sPhone, err1 := rt1PrivFromHex(v.FixedKeys["s_phone"])
	sHost, err2 := rt1PrivFromHex(v.FixedKeys["s_host"])
	ePhone, err3 := rt1PrivFromHex(v.FixedKeys["e_phone"])
	eHost, err4 := rt1PrivFromHex(v.FixedKeys["e_host"])
	if err1 != nil || err2 != nil || err3 != nil || err4 != nil {
		logf("RT1 self-test FAILED — could not load the fixed test keys")
		return false
	}
	spkP, _ := rt1MarshalPublic(sPhone.PublicKey())
	spkH, _ := rt1MarshalPublic(sHost.PublicKey())
	epkP, _ := rt1MarshalPublic(ePhone.PublicKey())
	epkH, _ := rt1MarshalPublic(eHost.PublicKey())

	check("SPKI phone static", eb(spkP) == v.Pairing.SpkPhoneB64)
	check("SPKI host ephemeral", eb(epkH) == v.Pairing.EpkHostB64)

	// 2 — pairing.
	code8, err := rt1CodeBytes(v.Pairing.CodeText)
	check("CODE8 parses", err == nil)
	check("CODE8", hex.EncodeToString(code8) == v.Pairing.Code8Hex)
	alt, _ := rt1CodeBytes("h7k2 9qrt 4mxb")
	check("code normalization", hex.EncodeToString(alt) == v.Pairing.Code8Hex)

	z, err := rt1ECDH(ePhone, eHost.PublicKey())
	check("pairing Z", err == nil && hex.EncodeToString(z) == v.Pairing.ZHex)
	pr := rt1Pairing(v.Pairing.Dev, v.Pairing.Hid, spkP, spkH, epkP, epkH,
		v.Pairing.NamePhone, v.Pairing.NameHost, z, code8)
	check("pairing TH", hex.EncodeToString(pr.Transcript) == v.Pairing.THHex)
	check("pairing mac_p", eb(pr.MACPhone) == v.Pairing.MacPhoneB64)
	check("pairing mac_h", eb(pr.MACHost) == v.Pairing.MacHostB64)

	if bad, err := rt1CodeBytes("H7K2-9QRT-4MXC"); err == nil {
		wrong := rt1Pairing(v.Pairing.Dev, v.Pairing.Hid, spkP, spkH, epkP, epkH,
			v.Pairing.NamePhone, v.Pairing.NameHost, z, bad)
		check("a wrong code changes mac_p", !rt1ConstantTimeEqual(wrong.MACPhone, pr.MACPhone))
	}

	// 3 — session.
	nP, nH := db(v.Session.NPhoneB64), db(v.Session.NHostB64)
	check("device tag", eb(rt1DeviceTag(nP, spkP)) == v.Session.TagB64)

	zee, _ := rt1ECDH(ePhone, eHost.PublicKey())
	zes, _ := rt1ECDH(ePhone, sHost.PublicKey())
	zse, _ := rt1ECDH(sPhone, eHost.PublicKey())
	check("Zee", hex.EncodeToString(zee) == v.Session.ZeeHex)
	check("Zes", hex.EncodeToString(zes) == v.Session.ZesHex)
	check("Zse", hex.EncodeToString(zse) == v.Session.ZseHex)
	// The host computes Zes/Zse from its own side; they must match.
	zesHost, _ := rt1ECDH(sHost, ePhone.PublicKey())
	zseHost, _ := rt1ECDH(eHost, sPhone.PublicKey())
	check("Zes from the host side", hex.EncodeToString(zesHost) == v.Session.ZesHex)
	check("Zse from the host side", hex.EncodeToString(zseHost) == v.Session.ZseHex)

	sk := rt1Session(v.Pairing.Dev, v.Pairing.Hid, spkP, spkH, epkP, epkH,
		nP, nH, zee, zes, zse)
	check("k phone->host", hex.EncodeToString(sk.PhoneToHost) == v.Session.KP2HHex)
	check("k host->phone", hex.EncodeToString(sk.HostToPhone) == v.Session.KH2PHex)
	check("session mac_h", eb(sk.MACHost) == v.Session.MacHostB64)

	// 4 — sealed lines, byte for byte.
	key := dh(v.Session.KP2HHex)
	for _, line := range v.SealedLines {
		sealed, err := rt1Seal([]byte(line.JSON), key, rt1PrefixPhoneToHost, uint64(line.Counter))
		check(fmt.Sprintf("sealed line %d", line.Counter), err == nil && eb(sealed) == line.LineB64)
		if err == nil {
			opened, err := rt1Open(sealed, key, rt1PrefixPhoneToHost, uint64(line.Counter))
			check(fmt.Sprintf("round trip %d", line.Counter), err == nil && string(opened) == line.JSON)
			_, err = rt1Open(sealed, key, rt1PrefixHostToPhone, uint64(line.Counter))
			check(fmt.Sprintf("direction separation %d", line.Counter), err != nil)
		}
	}

	// 5 — what must be rejected.
	if pub, err := rt1ParsePublic(db(v.MustReject.InvalidPointSPKIB64)); err == nil {
		_, err2 := rt1ECDH(ePhone, pub)
		check("the invalid point is rejected", err2 != nil)
	} // parse failure is itself a pass

	if len(fails) == 0 {
		logf("RT1 self-test passed")
		return true
	}
	logf("RT1 SELF-TEST FAILED: %v", fails)
	return false
}
