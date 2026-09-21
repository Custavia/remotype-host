import CryptoKit
import Foundation

/// RT1 — the Remotype trust layer. See `docs/RT1.md`; that document is the
/// source of truth and this file implements it. Conformance is proved against
/// `spec/rt1/vectors.json` by `RT1SelfTest`, which runs at every launch.
///
/// Three rules here are load-bearing, and each one is a bug that has bitten
/// somebody writing exactly this:
///
///  1. **Every transcript input is length-prefixed.** Concatenating raw fields
///     lets two different field sets hash to the same transcript.
///  2. **Public keys are SPKI DER**, never raw X9.63 points — assembling those
///     on Android means hand-padding affine coordinates and stripping
///     BigInteger's sign byte.
///  3. **The wire format is `ciphertext ‖ tag`.** CryptoKit's
///     `SealedBox.combined` PREPENDS the nonce; using it would put 12 extra
///     bytes on the wire that no other implementation expects.
enum RT1 {

    static let version = 1

    // MARK: - Primitives

    /// LP(x) = u16be(len(x)) ‖ x
    static func lp(_ bytes: Data) -> Data {
        precondition(bytes.count <= 0xFFFF, "RT1 transcript field too long")
        var out = Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)])
        out.append(bytes)
        return out
    }

    static func lp(_ s: String) -> Data { lp(Data(s.utf8)) }

    /// HKDF-SHA256, hand-rolled from HMAC so all four implementations are
    /// byte-identical by construction rather than by three vendors'
    /// interpretations of an HKDF API.
    static func hkdfExtract(salt: Data, ikm: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: salt)))
    }

    static func hkdfExpand(prk: Data, info: Data, count: Int) -> Data {
        var out = Data(), t = Data(), counter: UInt8 = 1
        let key = SymmetricKey(data: prk)
        while out.count < count {
            var input = t
            input.append(info)
            input.append(counter)
            t = Data(HMAC<SHA256>.authenticationCode(for: input, using: key))
            out.append(t)
            counter &+= 1
        }
        return out.prefix(count)
    }

    static func hmac(_ key: Data, _ message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    /// Constant time: a byte-by-byte early return leaks the position of the
    /// first difference, which is enough to forge a MAC one byte at a time.
    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[a.startIndex + i] ^ b[b.startIndex + i] }
        return diff == 0
    }

    /// ECDH, rejecting the all-zero output. An all-zero shared secret means the
    /// peer sent a low-order or otherwise degenerate point; deriving keys from
    /// it would hand the attacker a key they already know.
    static func ecdh(_ priv: P256.KeyAgreement.PrivateKey,
                     _ pub: P256.KeyAgreement.PublicKey) throws -> Data {
        let shared = try priv.sharedSecretFromKeyAgreement(with: pub)
        let raw = shared.withUnsafeBytes { Data($0) }
        guard raw.contains(where: { $0 != 0 }) else { throw Err.degenerateKey }
        return raw
    }

    static func publicKey(fromSPKI der: Data) throws -> P256.KeyAgreement.PublicKey {
        do { return try P256.KeyAgreement.PublicKey(derRepresentation: der) }
        catch { throw Err.badKey }
    }

    enum Err: Error {
        case badKey, degenerateKey, badCode, macMismatch, decryptFailed, counterExhausted
    }

    // MARK: - The pairing code

    /// Crockford base32. `I`/`L`/`O` are absent by design — they fold to 1/1/0
    /// on input so a misread character cannot cause a mismatch.
    private static let crockford = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func normalizeCode(_ text: String) -> String {
        var out = ""
        for ch in text.uppercased() {
            let c: Character = (ch == "I" || ch == "L") ? "1" : (ch == "O" ? "0" : ch)
            if c.isLetter || c.isNumber { out.append(c) }
        }
        return out
    }

    /// CODE8 — the 60-bit code as 8 bytes big-endian. What is fed to the KDF is
    /// this, never the ASCII, so display and typing variance cannot matter.
    static func codeBytes(_ text: String) throws -> Data {
        let norm = normalizeCode(text)
        guard norm.count == 12 else { throw Err.badCode }
        var v: UInt64 = 0
        for ch in norm {
            guard let idx = crockford.firstIndex(of: ch) else { throw Err.badCode }
            v = v << 5 | UInt64(idx)
        }
        guard v < (UInt64(1) << 60) else { throw Err.badCode }
        return withUnsafeBytes(of: v.bigEndian) { Data($0) }
    }

    /// A fresh 60-bit code, formatted `XXXX-XXXX-XXXX`.
    ///
    /// 60 bits is not decoration. The three-attempt rule below is safe only
    /// because guessing is 3/2^60; a 6-digit code would make the same rule
    /// meaningless and reintroduce an offline dictionary attack, because the
    /// code enters the KDF and a wrong guess is testable offline against the
    /// MAC. Do not shorten it.
    static func generateCode() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, 8, &bytes)
        var v = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } & ((UInt64(1) << 60) - 1)
        var chars = [Character](repeating: "0", count: 12)
        for i in stride(from: 11, through: 0, by: -1) {
            chars[i] = crockford[Int(v & 31)]
            v >>= 5
        }
        let s = String(chars)
        return "\(s.prefix(4))-\(s.dropFirst(4).prefix(4))-\(s.suffix(4))"
    }

    // MARK: - Pairing

    struct PairingResult {
        let transcript: Data
        let macPhone: Data      // expected from the phone, in pair.conf
        let macHost: Data       // sent to the phone, in pair.ok
    }

    /// Derives the pairing MACs. The code goes into HKDF-Extract, not into a
    /// comparison: a wrong code therefore produces entirely different keys, so
    /// a guessing peer gets neither authentication nor confidentiality.
    static func pairing(dev: String, hid: String,
                        spkPhone: Data, spkHost: Data,
                        epkPhone: Data, epkHost: Data,
                        namePhone: String, nameHost: String,
                        z: Data, code8: Data) -> PairingResult {
        var th = Data()
        th.append(lp(Data("RT1-PAIR".utf8)))
        th.append(lp(dev)); th.append(lp(hid))
        th.append(lp(spkPhone)); th.append(lp(spkHost))
        th.append(lp(epkPhone)); th.append(lp(epkHost))
        th.append(lp(namePhone)); th.append(lp(nameHost))
        let TH = Data(SHA256.hash(data: th))

        var ikm = z; ikm.append(code8)
        let prk = hkdfExtract(salt: TH, ikm: ikm)
        let kp = hkdfExpand(prk: prk, info: Data("rt1 pair phone".utf8), count: 32)
        let kh = hkdfExpand(prk: prk, info: Data("rt1 pair host".utf8), count: 32)
        return PairingResult(transcript: TH,
                             macPhone: hmac(kp, Data([0x01])),
                             macHost: hmac(kh, Data([0x02])))
    }

    // MARK: - Session

    struct SessionKeys {
        let phoneToHost: Data
        let hostToPhone: Data
        let macPhone: Data      // expected from the phone, in rt.conf
        let macHost: Data       // sent to the phone, in rt.ok
    }

    /// `tag = SHA256(LP("RT1-TAG") ‖ LP(n_p) ‖ LP(spk_p))` — lets the host find
    /// which paired device is calling without that device's identity appearing
    /// on the wire in the clear.
    static func deviceTag(nonce: Data, spkPhone: Data) -> Data {
        var t = Data()
        t.append(lp(Data("RT1-TAG".utf8)))
        t.append(lp(nonce))
        t.append(lp(spkPhone))
        return Data(SHA256.hash(data: t))
    }

    /// Triple-DH: `Zee` gives forward secrecy, `Zes` proves the host holds its
    /// static key, `Zse` proves the phone holds its own. Mutual authentication
    /// from one primitive, with no signatures and so no DER-vs-raw traps.
    static func session(dev: String, hid: String,
                        spkPhone: Data, spkHost: Data,
                        epkPhone: Data, epkHost: Data,
                        noncePhone: Data, nonceHost: Data,
                        zee: Data, zes: Data, zse: Data) -> SessionKeys {
        var th = Data()
        th.append(lp(Data("RT1-SESS".utf8)))
        th.append(lp(dev)); th.append(lp(hid))
        th.append(lp(spkPhone)); th.append(lp(spkHost))
        th.append(lp(epkPhone)); th.append(lp(epkHost))
        th.append(lp(noncePhone)); th.append(lp(nonceHost))
        let TH = Data(SHA256.hash(data: th))

        var ikm = zee; ikm.append(zes); ikm.append(zse)
        let prk = hkdfExtract(salt: TH, ikm: ikm)
        return SessionKeys(
            phoneToHost: hkdfExpand(prk: prk, info: Data("rt1 c2h key".utf8), count: 32),
            hostToPhone: hkdfExpand(prk: prk, info: Data("rt1 h2c key".utf8), count: 32),
            macPhone: hmac(hkdfExpand(prk: prk, info: Data("rt1 c2h mac".utf8), count: 32),
                           Data([0x01])),
            macHost: hmac(hkdfExpand(prk: prk, info: Data("rt1 h2c mac".utf8), count: 32),
                          Data([0x02])))
    }

    // MARK: - Sealed lines

    static let prefixPhoneToHost = Data("RTCH".utf8)
    static let prefixHostToPhone = Data("RTHC".utf8)

    static func nonce(prefix: Data, counter: UInt64) -> Data {
        var n = prefix
        n.append(withUnsafeBytes(of: counter.bigEndian) { Data($0) })
        return n
    }

    /// `u16be(jsonLen) ‖ json ‖ zero-pad to a multiple of 64`, sealed, then
    /// base64. The padding hides a one-character `key` frame from a `mod`
    /// frame; it costs four lines and cannot be added later without a version
    /// bump, so it ships in v1.
    static func seal(json: Data, key: Data, prefix: Data, counter: UInt64) throws -> Data {
        precondition(json.count <= 0xFFFF_FFFF, "RT1 frame too long")
        let n = UInt32(json.count)
        var plain = Data([UInt8(n >> 24), UInt8((n >> 16) & 0xFF),
                          UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
        plain.append(json)
        let pad = (64 - (plain.count % 64)) % 64
        if pad > 0 { plain.append(Data(repeating: 0, count: pad)) }

        let box = try AES.GCM.seal(plain,
                                   using: SymmetricKey(data: key),
                                   nonce: try AES.GCM.Nonce(data: nonce(prefix: prefix, counter: counter)))
        // ciphertext ‖ tag — NOT `box.combined`, which prepends the nonce.
        var wire = box.ciphertext
        wire.append(box.tag)
        return wire
    }

    static func open(sealed: Data, key: Data, prefix: Data, counter: UInt64) throws -> Data {
        guard sealed.count >= 16 + 4 else { throw Err.decryptFailed }
        let tag = sealed.suffix(16)
        let ciphertext = sealed.prefix(sealed.count - 16)
        do {
            let box = try AES.GCM.SealedBox(
                nonce: try AES.GCM.Nonce(data: nonce(prefix: prefix, counter: counter)),
                ciphertext: ciphertext, tag: tag)
            let plain = try AES.GCM.open(box, using: SymmetricKey(data: key))
            guard plain.count >= 4 else { throw Err.decryptFailed }
            let s0 = plain.startIndex
            let len = Int(plain[s0]) << 24 | Int(plain[s0 + 1]) << 16
                    | Int(plain[s0 + 2]) << 8 | Int(plain[s0 + 3])
            guard 4 + len <= plain.count else { throw Err.decryptFailed }
            return plain.subdata(in: (s0 + 4)..<(s0 + 4 + len))
        } catch {
            // No error frame goes back on the wire: a distinguishable failure
            // is a decryption oracle. The caller closes the connection.
            throw Err.decryptFailed
        }
    }
}
