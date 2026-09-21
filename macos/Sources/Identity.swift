import CryptoKit
import Foundation

/// The host's long-term identity, and the phones it has paired with.
///
/// **Deliberately a 0600 file, not the Keychain.** Keychain ACLs are keyed to
/// the code signature, and that is the exact mechanism this project has already
/// lost twice — it is why the host's Accessibility grant goes stale after an
/// update and why `dev-install.sh` exists at all. A shipped update that
/// silently invalidated every pairing would be a far worse outcome than the
/// marginal protection the Keychain buys against a threat model that is "a peer
/// on your Wi-Fi". An attacker who can read files as this user has already won.
///
/// Layout, in `~/Library/Application Support/Remotype Host/` (directory 0700):
///   identity.bin   32-byte P-256 private scalar ‖ 16-byte host id
///   devices.json   the paired phones
final class Identity {
    static let shared = Identity()

    private static let dirName = "Remotype Host"
    private let queue = DispatchQueue(label: "remotype.identity")

    private(set) var privateKey: P256.KeyAgreement.PrivateKey
    /// 32 lowercase hex characters. Stable for the life of the install, and the
    /// thing a phone pins — never the display name, which the user can change.
    private(set) var hostID: String

    var publicKeySPKI: Data { privateKey.publicKey.derRepresentation }

    private init() {
        let dir = Identity.supportDirectory()
        let file = dir.appendingPathComponent("identity.bin")

        if let raw = try? Data(contentsOf: file), raw.count == 48,
           let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw.prefix(32)) {
            privateKey = key
            hostID = raw.suffix(16).map { String(format: "%02x", $0) }.joined()
            return
        }

        // First run, or an unreadable file. Generating a new identity means every
        // previously paired phone will see an unknown host and have to pair
        // again — which is exactly the alarm we want if the file was tampered
        // with, and is unavoidable if it was lost.
        let key = P256.KeyAgreement.PrivateKey()
        var idBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &idBytes)

        privateKey = key
        hostID = idBytes.map { String(format: "%02x", $0) }.joined()

        var blob = key.rawRepresentation
        blob.append(contentsOf: idBytes)
        Identity.writePrivate(blob, to: file)
        HostLog.write("RT1: generated a new host identity (\(hostID.prefix(8))…)")
    }

    // MARK: paired devices

    struct Device: Codable, Identifiable {
        let dev: String             // 32 hex, the phone's id
        let spk: String             // base64 SPKI of the phone's static key
        var name: String
        var platform: String        // "ios" | "android"
        let pairedAt: Date
        var lastSeen: Date?
        var id: String { dev }
    }

    /// The paired list. Every read AND write goes through `queue`: the
    /// handshake reads it from the network queue while the menu bar writes it
    /// from the main actor, and an array is not safe across that on its own.
    private lazy var storedDevices: [Device] = loadDevices()

    var devices: [Device] { queue.sync { storedDevices } }

    func device(matchingTag tag: Data, nonce: Data) -> Device? {
        queue.sync {
            // ≤8 devices × one SHA-256 each: free, and it keeps a stable device
            // identifier off the wire.
            for d in storedDevices {
                guard let spk = Data(base64Encoded: d.spk) else { continue }
                if RT1.constantTimeEqual(RT1.deviceTag(nonce: nonce, spkPhone: spk), tag) { return d }
            }
            return nil
        }
    }

    func remember(_ device: Device) {
        queue.sync {
            storedDevices.removeAll { $0.dev == device.dev }   // re-pairing replaces
            storedDevices.append(device)
            saveDevices()
        }
        HostLog.write("RT1: paired with \(device.name) (\(device.platform))")
    }

    func forget(dev: String) {
        queue.sync {
            guard let idx = storedDevices.firstIndex(where: { $0.dev == dev }) else { return }
            let name = storedDevices[idx].name
            storedDevices.remove(at: idx)
            saveDevices()
            HostLog.write("RT1: removed paired device \(name)")
        }
    }

    func forgetAll() {
        queue.sync {
            storedDevices.removeAll()
            saveDevices()
            HostLog.write("RT1: removed all paired devices")
        }
    }

    func noteSeen(dev: String) {
        queue.sync {
            guard let idx = storedDevices.firstIndex(where: { $0.dev == dev }) else { return }
            storedDevices[idx].lastSeen = Date()
            saveDevices()
        }
    }

    // MARK: storage

    private var devicesFile: URL {
        Identity.supportDirectory().appendingPathComponent("devices.json")
    }

    private func loadDevices() -> [Device] {
        guard let data = try? Data(contentsOf: devicesFile),
              let list = try? JSONDecoder().decode([Device].self, from: data) else { return [] }
        return list
    }

    private func saveDevices() {
        guard let data = try? JSONEncoder().encode(storedDevices) else { return }
        Identity.writePrivate(data, to: devicesFile)
    }

    private static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent(dirName, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // createDirectory's attributes are ignored if the directory already
        // exists, so tighten it every time rather than only on creation.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: dir.path)
        return dir
    }

    /// Write 0600 from the start. Writing then chmod'ing leaves a window in
    /// which the private key is world-readable.
    private static func writePrivate(_ data: Data, to url: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        if !fm.createFile(atPath: url.path, contents: data,
                          attributes: [.posixPermissions: 0o600]) {
            try? data.write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}


/// The menu bar's view of the paired list.
///
/// `Identity` deliberately is not an `ObservableObject`: it is read and written
/// from the network queue during the handshake, and SwiftUI requires publishes
/// on the main actor. This is the main-actor mirror — the menu reads `list`,
/// and anything that changes the underlying store calls `refresh()`.
@MainActor
final class PairedDevices: ObservableObject {
    static let shared = PairedDevices()

    @Published private(set) var list: [Identity.Device] = Identity.shared.devices

    func refresh() { list = Identity.shared.devices }

    func forget(_ dev: String) {
        Identity.shared.forget(dev: dev)
        refresh()
    }

    func forgetAll() {
        Identity.shared.forgetAll()
        refresh()
    }
}
