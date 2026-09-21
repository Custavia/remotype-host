import CryptoKit
import Foundation

/// Per-connection RT1 state: the pairing ceremony, the session handshake, and
/// the sealed-line codec once the handshake completes.
///
/// The security property this type exists to enforce is simple and absolute:
/// **`isOpen` is false until a paired device has proved possession of its
/// static key.** `Server` refuses to act on anything except the handful of
/// handshake messages while `isOpen` is false, so a peer on the Wi-Fi can no
/// longer type, read the clipboard, pull a file, or evict a live session — the
/// four things it could do before RT1.
///
/// State lives here rather than on `Server` because `Server` keeps exactly one
/// active connection and a Server-wide read buffer; putting counters and keys in
/// the same place would make a stale frame from a previous connection decrypt
/// against the new one's key schedule.
final class RT1Session {

    enum Phase {
        case fresh          // nothing yet — only hello/pair.begin accepted
        case pairing        // pair.hi sent, waiting for pair.conf
        case awaitingConf   // hi sent with rt, waiting for rt.conf
        case open           // sealed both ways
        case legacy         // a pre-RT1 phone; see Server for what this permits
    }

    private(set) var phase: Phase = .fresh
    var isOpen: Bool { phase == .open }
    var isLegacy: Bool { phase == .legacy }
    /// A pairing ceremony has begun on this connection and not yet finished —
    /// the state a pair.cancel, or a dropped socket, ends.
    var isPairing: Bool { phase == .pairing }

    /// pair.cancel: the phone abandoned the ceremony it began here. Back to
    /// fresh, so a later drop of this socket is not mistaken for a phone
    /// vanishing mid-ceremony — by then another phone may have minted a new
    /// code, and this socket must not be the one that retires it.
    func cancelPairing() {
        guard phase == .pairing else { return }
        phase = .fresh
        pendingPair = nil
        ephemeral = nil
        expectedMAC = Data(); replyMAC = Data()
    }

    /// The paired device this connection authenticated as. Nil until `.open`.
    private(set) var device: Identity.Device?

    // Handshake scratch.
    private var ephemeral: P256.KeyAgreement.PrivateKey?
    private var expectedMAC = Data()
    private var replyMAC = Data()
    private var pendingPair: (dev: String, spk: Data, name: String, platform: String)?

    // Sealed-line state. Counters are per direction and never reused.
    private var keyIn = Data()
    private var keyOut = Data()
    private var counterIn: UInt64 = 0
    private var counterOut: UInt64 = 0

    /// GCM with a 64-bit counter is safe far past this, but a counter that has
    /// run away means something is wrong; refuse rather than wrap.
    private static let counterLimit: UInt64 = 1 << 32

    // MARK: - Pairing

    /// Handles `pair.begin`. Returns the reply to send, and — on success — the
    /// device to remember once the phone's MAC checks out.
    func beginPairing(dev: String, spkPhoneB64: String, epkPhoneB64: String,
                      name: String, platform: String,
                      code: String?, hostName: String) -> [String: Any] {
        guard let code, let code8 = try? RT1.codeBytes(code) else {
            // No code showing. The host raises its pairing panel; the phone
            // retries when the user taps. Not an error — the common first-run
            // path is the phone asking before anyone has opened the panel.
            return ["t": "pair.no", "why": "nocode"]
        }
        // A REPEAT pair.begin restarts the ceremony rather than being refused.
        // The phone sends one to raise this panel, and another when the user
        // has finished typing — and a host that answers the second with "busy"
        // tells the user another phone is pairing when the truth is that they
        // took a few seconds to read a code. `.awaitingConf` and `.open` are
        // different: those belong to a session that is already proving itself.
        switch phase {
        case .fresh, .pairing: break
        default: return ["t": "pair.no", "why": "busy"]
        }
        guard let spkPhone = Data(base64Encoded: spkPhoneB64),
              let epkPhoneData = Data(base64Encoded: epkPhoneB64),
              let epkPhone = try? RT1.publicKey(fromSPKI: epkPhoneData)
        else { return ["t": "pair.no", "why": "mac"] }

        let e = P256.KeyAgreement.PrivateKey()
        ephemeral = e
        guard let z = try? RT1.ecdh(e, epkPhone) else {
            return ["t": "pair.no", "why": "mac"]
        }

        let identity = Identity.shared
        let result = RT1.pairing(dev: dev, hid: identity.hostID,
                                 spkPhone: spkPhone, spkHost: identity.publicKeySPKI,
                                 epkPhone: epkPhoneData, epkHost: e.publicKey.derRepresentation,
                                 namePhone: name, nameHost: hostName,
                                 z: z, code8: code8)
        expectedMAC = result.macPhone
        replyMAC = result.macHost
        pendingPair = (dev: dev, spk: spkPhone, name: name, platform: platform)
        phase = .pairing

        return ["t": "pair.hi", "rt": RT1.version,
                "hid": identity.hostID,
                "spk": identity.publicKeySPKI.base64EncodedString(),
                "epk": e.publicKey.derRepresentation.base64EncodedString(),
                "name": hostName, "os": "mac"]
    }

    /// Handles `pair.conf`. On success the device is persisted and the
    /// connection continues straight into a session handshake on the same
    /// socket — no reconnect.
    func confirmPairing(macB64: String) -> (reply: [String: Any], paired: Identity.Device?) {
        guard phase == .pairing, let pending = pendingPair,
              let mac = Data(base64Encoded: macB64) else {
            return (["t": "pair.no", "why": "mac"], nil)
        }
        guard RT1.constantTimeEqual(mac, expectedMAC) else {
            phase = .fresh
            pendingPair = nil
            return (["t": "pair.no", "why": "mac"], nil)
        }
        let device = Identity.Device(dev: pending.dev,
                                     spk: pending.spk.base64EncodedString(),
                                     name: pending.name, platform: pending.platform,
                                     pairedAt: Date(), lastSeen: Date())
        Identity.shared.remember(device)
        phase = .fresh          // the session handshake follows on this socket
        pendingPair = nil
        return (["t": "pair.ok", "mac": replyMAC.base64EncodedString()], device)
    }

    // MARK: - Session

    /// Handles an RT1 `hello`. Finds the paired device by tag, derives the
    /// session keys, and returns the fields to merge into `hi`.
    func beginSession(tagB64: String, noncePhoneB64: String, epkPhoneB64: String)
        -> (fields: [String: Any], failure: [String: Any]?) {

        guard let tag = Data(base64Encoded: tagB64),
              let nonceP = Data(base64Encoded: noncePhoneB64),
              let epkPhoneData = Data(base64Encoded: epkPhoneB64),
              let epkPhone = try? RT1.publicKey(fromSPKI: epkPhoneData)
        else { return ([:], ["t": "rt.no", "why": "unknown"]) }

        let identity = Identity.shared
        guard let dev = identity.device(matchingTag: tag, nonce: nonceP),
              let spkPhoneData = Data(base64Encoded: dev.spk),
              let spkPhone = try? RT1.publicKey(fromSPKI: spkPhoneData)
        else {
            // Not a device we know. Say so plainly: the phone shows "this
            // computer doesn't recognise this phone — pair again".
            return ([:], ["t": "rt.no", "why": "unknown"])
        }

        let e = P256.KeyAgreement.PrivateKey()
        ephemeral = e
        var nonceH = Data(count: 16)
        _ = nonceH.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }

        guard let zee = try? RT1.ecdh(e, epkPhone),
              let zes = try? RT1.ecdh(identity.privateKey, epkPhone),
              let zse = try? RT1.ecdh(e, spkPhone)
        else { return ([:], ["t": "rt.no", "why": "unknown"]) }

        let keys = RT1.session(dev: dev.dev, hid: identity.hostID,
                              spkPhone: spkPhoneData, spkHost: identity.publicKeySPKI,
                              epkPhone: epkPhoneData, epkHost: e.publicKey.derRepresentation,
                              noncePhone: nonceP, nonceHost: nonceH,
                              zee: zee, zes: zes, zse: zse)
        expectedMAC = keys.macPhone
        replyMAC = keys.macHost
        keyIn = keys.phoneToHost
        keyOut = keys.hostToPhone
        counterIn = 0
        counterOut = 0
        device = dev
        phase = .awaitingConf

        return (["rt": RT1.version, "hid": identity.hostID,
                 "n": nonceH.base64EncodedString(),
                 "epk": e.publicKey.derRepresentation.base64EncodedString()], nil)
    }

    /// Handles `rt.conf` — the phone's last plaintext line. `rt.ok` is ours.
    func confirmSession(macB64: String) -> [String: Any] {
        guard phase == .awaitingConf, let mac = Data(base64Encoded: macB64),
              RT1.constantTimeEqual(mac, expectedMAC) else {
            phase = .fresh
            device = nil
            return ["t": "rt.no", "why": "mac"]
        }
        phase = .open
        if let dev = device { Identity.shared.noteSeen(dev: dev.dev) }
        return ["t": "rt.ok", "mac": replyMAC.base64EncodedString()]
    }

    func markLegacy() { phase = .legacy }

    // MARK: - Sealed lines

    /// Decrypts one received line. Any failure is fatal for the connection: a
    /// distinguishable error would be a decryption oracle, so the caller closes
    /// rather than replying.
    func open(line: Data) throws -> Data {
        guard phase == .open,
              let sealed = Data(base64Encoded: line) else { throw RT1.Err.decryptFailed }
        guard counterIn < Self.counterLimit else { throw RT1.Err.counterExhausted }
        let plain = try RT1.open(sealed: sealed, key: keyIn,
                                 prefix: RT1.prefixPhoneToHost, counter: counterIn)
        counterIn &+= 1
        return plain
    }

    /// Seals one line for sending. Must be called on the same queue as every
    /// other send — the counter is sequential, and two threads sealing at once
    /// would swap records on the wire and break the peer's decryption for good.
    func seal(json: Data) throws -> Data {
        guard phase == .open else { throw RT1.Err.decryptFailed }
        guard counterOut < Self.counterLimit else { throw RT1.Err.counterExhausted }
        let sealed = try RT1.seal(json: json, key: keyOut,
                                  prefix: RT1.prefixHostToPhone, counter: counterOut)
        counterOut &+= 1
        return Data(sealed.base64EncodedString().utf8)
    }
}
