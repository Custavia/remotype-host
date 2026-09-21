import CryptoKit
import Foundation

/// Proves this build's RT1 against `spec/rt1/vectors.json`, which is bundled as
/// a resource. Runs at every launch, not only in tests.
///
/// The reason it runs in the shipping build: the failure this guards against is
/// not "the algorithm is wrong" — it is "the Swift, Go and Kotlin sides drifted
/// apart", which shows up as a link that connects and then dies, on one platform
/// only, in the field. A 2 ms check at launch that writes one line to the log
/// turns that into something a support ticket can name.
enum RT1SelfTest {

    @discardableResult
    static func run() -> Bool {
        guard let url = Bundle.main.url(forResource: "vectors", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            HostLog.write("RT1 self-test SKIPPED — vectors.json is missing from the bundle")
            return false
        }

        var failures: [String] = []
        func check(_ label: String, _ ok: Bool) { if !ok { failures.append(label) } }

        // 1 — HKDF against RFC 5869, before anything built on it is trusted.
        if let cases = root["hkdf_rfc5869"] as? [[String: Any]] {
            for c in cases {
                guard let name = c["name"] as? String,
                      let ikm = hex(c["ikm_hex"]), let salt = hex(c["salt_hex"]),
                      let info = hex(c["info_hex"]), let L = c["L"] as? Int,
                      let prkWant = hex(c["prk_hex"]), let okmWant = hex(c["okm_hex"])
                else { continue }
                let prk = RT1.hkdfExtract(salt: salt, ikm: ikm)
                check("HKDF PRK — \(name)", prk == prkWant)
                check("HKDF OKM — \(name)", RT1.hkdfExpand(prk: prk, info: info, count: L) == okmWant)
            }
        }

        let keys = root["fixed_private_keys_hex"] as? [String: String] ?? [:]
        func priv(_ name: String) -> P256.KeyAgreement.PrivateKey? {
            guard let h = keys[name], let raw = hex(h) else { return nil }
            return try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw)
        }

        guard let sPhone = priv("s_phone"), let sHost = priv("s_host"),
              let ePhone = priv("e_phone"), let eHost = priv("e_host") else {
            HostLog.write("RT1 self-test FAILED — could not load the fixed test keys")
            return false
        }

        let spkPhone = sPhone.publicKey.derRepresentation
        let spkHost = sHost.publicKey.derRepresentation
        let epkPhone = ePhone.publicKey.derRepresentation
        let epkHost = eHost.publicKey.derRepresentation

        // 2 — pairing. Also proves SPKI encoding matches the other three.
        if let p = root["pairing"] as? [String: Any],
           let dev = p["dev"] as? String, let hid = p["hid"] as? String,
           let nameP = p["name_phone"] as? String, let nameH = p["name_host"] as? String,
           let codeText = p["code_text"] as? String {

            check("SPKI phone static", b64(spkPhone) == p["spk_phone_b64"] as? String)
            check("SPKI host ephemeral", b64(epkHost) == p["epk_host_b64"] as? String)

            if let code8 = try? RT1.codeBytes(codeText) {
                check("CODE8", code8 == hex(p["code8_hex"]))
                // The same code with spaces, lower case and an O-for-0 slip must
                // normalize to the identical eight bytes.
                check("code normalization", (try? RT1.codeBytes("h7k2 9qrt 4mxb")) == code8)

                if let z = try? RT1.ecdh(ePhone, eHost.publicKey) {
                    check("pairing Z", z == hex(p["Z_hex"]))
                    let r = RT1.pairing(dev: dev, hid: hid,
                                        spkPhone: spkPhone, spkHost: spkHost,
                                        epkPhone: epkPhone, epkHost: epkHost,
                                        namePhone: nameP, nameHost: nameH,
                                        z: z, code8: code8)
                    check("pairing TH", r.transcript == hex(p["TH_hex"]))
                    check("pairing mac_p", b64(r.macPhone) == p["mac_phone_b64"] as? String)
                    check("pairing mac_h", b64(r.macHost) == p["mac_host_b64"] as? String)

                    // A wrong code must not merely fail a comparison — it must
                    // produce a different key altogether.
                    if let bad = try? RT1.codeBytes("H7K2-9QRT-4MXC") {
                        let wrong = RT1.pairing(dev: dev, hid: hid,
                                                spkPhone: spkPhone, spkHost: spkHost,
                                                epkPhone: epkPhone, epkHost: epkHost,
                                                namePhone: nameP, nameHost: nameH,
                                                z: z, code8: bad)
                        check("a wrong code changes mac_p", wrong.macPhone != r.macPhone)
                    }
                }
            } else {
                check("CODE8 parses", false)
            }
        }

        // 3 — session keys and the device tag.
        if let s = root["session"] as? [String: Any],
           let p = root["pairing"] as? [String: Any],
           let dev = p["dev"] as? String, let hid = p["hid"] as? String,
           let nP = b64d(s["n_phone_b64"]), let nH = b64d(s["n_host_b64"]) {

            check("device tag", b64(RT1.deviceTag(nonce: nP, spkPhone: spkPhone)) == s["tag_b64"] as? String)

            if let zee = try? RT1.ecdh(ePhone, eHost.publicKey),
               let zes = try? RT1.ecdh(ePhone, sHost.publicKey),
               let zse = try? RT1.ecdh(sPhone, eHost.publicKey) {
                check("Zee", zee == hex(s["Zee_hex"]))
                check("Zes", zes == hex(s["Zes_hex"]))
                check("Zse", zse == hex(s["Zse_hex"]))
                // The host derives Zes/Zse from its own side; they must match.
                check("Zes from the host side", (try? RT1.ecdh(sHost, ePhone.publicKey)) == zes)
                check("Zse from the host side", (try? RT1.ecdh(eHost, sPhone.publicKey)) == zse)

                let k = RT1.session(dev: dev, hid: hid,
                                    spkPhone: spkPhone, spkHost: spkHost,
                                    epkPhone: epkPhone, epkHost: epkHost,
                                    noncePhone: nP, nonceHost: nH,
                                    zee: zee, zes: zes, zse: zse)
                check("k phone→host", k.phoneToHost == hex(s["k_phone_to_host_hex"]))
                check("k host→phone", k.hostToPhone == hex(s["k_host_to_phone_hex"]))
                check("session mac_h", b64(k.macHost) == s["mac_host_b64"] as? String)
            }
        }

        // 4 — the sealed line, byte for byte. This is where CryptoKit's
        // `combined` would betray us by prepending the nonce.
        if let s = root["session"] as? [String: Any],
           let key = hex(s["k_phone_to_host_hex"]),
           let lines = root["sealed_lines"] as? [[String: Any]] {
            for line in lines {
                guard let json = line["json"] as? String,
                      let counter = line["counter"] as? Int,
                      let want = line["line_b64"] as? String else { continue }
                let sealed = try? RT1.seal(json: Data(json.utf8), key: key,
                                           prefix: RT1.prefixPhoneToHost, counter: UInt64(counter))
                check("sealed line \(counter)", sealed.map(b64) == want)
                if let sealed {
                    let opened = try? RT1.open(sealed: sealed, key: key,
                                               prefix: RT1.prefixPhoneToHost, counter: UInt64(counter))
                    check("round trip \(counter)", opened == Data(json.utf8))
                    // Direction separation: the other prefix must not open it.
                    let crossed = try? RT1.open(sealed: sealed, key: key,
                                                prefix: RT1.prefixHostToPhone, counter: UInt64(counter))
                    check("direction separation \(counter)", crossed == nil)
                }
            }
        }

        // 5 — what must be rejected.
        if let neg = root["must_reject"] as? [String: Any],
           let der = b64d(neg["invalid_point_spki_b64"]) {
            let imported = try? RT1.publicKey(fromSPKI: der)
            let survived = imported.flatMap { try? RT1.ecdh(ePhone, $0) }
            check("the invalid point is rejected", survived == nil)
        }

        if failures.isEmpty {
            HostLog.write("RT1 self-test passed")
            return true
        }
        HostLog.write("RT1 SELF-TEST FAILED: \(failures.joined(separator: ", "))")
        return false
    }

    // MARK: helpers

    private static func hex(_ any: Any?) -> Data? {
        guard let s = any as? String else { return nil }
        if s.isEmpty { return Data() }
        var out = Data(); var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            out.append(b); idx = next
        }
        return out
    }

    private static func b64(_ d: Data) -> String { d.base64EncodedString() }

    private static func b64d(_ any: Any?) -> Data? {
        guard let s = any as? String else { return nil }
        return Data(base64Encoded: s)
    }
}
