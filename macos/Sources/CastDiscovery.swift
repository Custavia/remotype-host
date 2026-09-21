import Foundation
import Network

/// Host-side sink discovery (CASTING.md §5): browses `_googlecast._tcp` and
/// `_airplay._tcp` (with TXT records), resolves each service to an address,
/// and reports FULL snapshots for `cast.targets` (never deltas). Start/stop
/// follows the phone's `cast.scan.sub` lifecycle; the cache is kept across
/// stop() so a `cast.start` racing a picker close still resolves its target.
final class CastDiscovery {
    struct Target {
        let key: String          // browse identity: service type + instance name
        var id: String           // stable id per §5.4: deviceId, else name+type
        var name: String
        var type: String         // "cast" | "airplay"
        var deviceId: String?
        var model: String?
        var addr: String?        // absent until the endpoint resolves
        var port: Int?
        var present: Bool        // currently in the browser's result set
        var lastSeen: Date
    }

    /// Full snapshot on every change. Runs on .main.
    var onChange: (([[String: Any]]) -> Void)?

    private(set) var running = false
    private var browsers: [NWBrowser] = []
    private var targets: [String: Target] = [:]
    private var resolving = Set<String>()
    private var sweepTimer: DispatchSourceTimer?

    /// A target lost from mDNS stays in the snapshot this long before eviction
    /// (§5.2/§5.3 hysteresis — flapping must not flicker the phone's button).
    static let staleEviction: TimeInterval = 10

    private static let localName = Host.current().localizedName ?? ""
    static func isSelf(_ instanceName: String) -> Bool {
        guard !localName.isEmpty else { return false }
        let norm = { (s: String) in s.replacingOccurrences(of: "\u{2019}", with: "'").lowercased() }
        return norm(instanceName) == norm(localName)
    }

    /// §5.4 audio-only / group filter: a `_googlecast._tcp` device is a screen
    /// target only if its capability bitmask `ca` (a DECIMAL TXT value) has the
    /// video-out bit (bit 0) set. Absent `ca` is lenient (include). Cast *groups*
    /// advertise `Google-Cast-Group-…` instance names and never show a screen.
    static func isVideoCastTarget(name: String, txt: [String: String]) -> Bool {
        if name.hasPrefix("Google-Cast-Group-") { return false }
        if let ca = txt["ca"], let bits = Int(ca) { return bits & 1 == 1 }
        return true
    }

    func start() {
        guard !running else { return }
        running = true
        for serviceType in ["_googlecast._tcp", "_airplay._tcp"] {
            let params = NWParameters()
            // LAN only — see Server.startListener for why peer-to-peer (AWDL) is
            // never enabled in this process. Cast targets live on the LAN.
            params.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil),
                                    using: params)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.ingest(results, serviceType: serviceType)
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.sweep() }
        timer.resume()
        sweepTimer = timer
    }

    func stop() {
        guard running else { return }
        running = false
        for browser in browsers { browser.cancel() }
        browsers.removeAll()
        sweepTimer?.cancel()
        sweepTimer = nil
        resolving.removeAll()
        // Keep the cache (identity + resolved addresses stay useful for an
        // in-flight cast.start) but drop presence so a restart re-verifies.
        for key in targets.keys { targets[key]?.present = false }
    }

    /// Resolve a `cast.start` target against the host's own cache (§4: the
    /// host is the identity authority; the phone's addr is advisory).
    func target(withId id: String) -> Target? {
        targets.values.first { $0.id == id }
    }

    /// The current `cast.targets` items (§5.4 objects), lost-but-in-hysteresis
    /// entries included.
    func snapshot() -> [[String: Any]] {
        targets.values
            .filter { $0.present || Date().timeIntervalSince($0.lastSeen) < Self.staleEviction }
            .sorted { ($0.name, $0.type) < ($1.name, $1.type) }
            .map { t in
                var obj: [String: Any] = ["id": t.id, "name": t.name, "type": t.type,
                                          "seenBy": "host"]
                if let v = t.deviceId { obj["deviceId"] = v }
                if let v = t.model { obj["model"] = v }
                if let v = t.addr { obj["addr"] = v }
                if let v = t.port { obj["port"] = v }
                // Lost from mDNS but still inside the 10 s eviction window (§5.4):
                // flag it so phones gray+disable it instead of applying their own
                // linger (which would stack to ~20 s). Present targets never carry it.
                if !t.present { obj["stale"] = true }
                return obj
            }
    }

    private func ingest(_ results: Set<NWBrowser.Result>, serviceType: String) {
        let type = serviceType.hasPrefix("_googlecast") ? "cast" : "airplay"
        var seen = Set<String>()
        var changed = false
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            var txt: [String: String] = [:]
            if case let .bonjour(record) = result.metadata {
                for (k, v) in record.dictionary { txt[k.lowercased()] = v }
            }
            if type == "airplay", Self.isSelf(name) { continue }   // this Mac advertises its own AirPlay receiver — never a cast target
            if type == "cast", !Self.isVideoCastTarget(name: name, txt: txt) { continue }   // §5.4: audio-only speakers + cast groups can't show a screen
            let key = "\(type)|\(name)"
            seen.insert(key)
            let deviceId = txt[type == "cast" ? "id" : "deviceid"]
            let displayName = (type == "cast" ? txt["fn"] : nil) ?? name
            let stableId = deviceId ?? "\(displayName)|\(type)"
            let model = txt[type == "cast" ? "md" : "model"]
            if var t = targets[key] {
                if !t.present || t.id != stableId || t.name != displayName
                    || t.deviceId != deviceId { changed = true }
                t.present = true
                t.lastSeen = Date()
                t.id = stableId
                t.name = displayName
                t.deviceId = deviceId
                if let model { t.model = model }
                targets[key] = t
            } else {
                targets[key] = Target(key: key, id: stableId, name: displayName, type: type,
                                      deviceId: deviceId, model: model, addr: nil, port: nil,
                                      present: true, lastSeen: Date())
                changed = true
            }
            if targets[key]?.addr == nil, !resolving.contains(key) {
                resolve(key: key, endpoint: result.endpoint)
            }
        }
        // Gone from this browse: keep the entry through the hysteresis window but
        // re-emit so its snapshot now carries "stale":true (§5.4) — the phone grays
        // + disables it and drops its own linger. sweep() evicts at 10 s.
        for (key, t) in targets where t.type == type && t.present && !seen.contains(key) {
            targets[key]?.present = false
            targets[key]?.lastSeen = Date()
            changed = true
        }
        if changed { emit() }
    }

    private func sweep() {
        var changed = false
        for (key, t) in targets
        where !t.present && Date().timeIntervalSince(t.lastSeen) >= Self.staleEviction {
            targets.removeValue(forKey: key)
            changed = true
        }
        if changed { emit() }
    }

    private func emit() {
        HostLog.write("cast targets \(targets.values.filter(\.present).count)")   // count only, never names
        onChange?(snapshot())
    }

    /// Resolve a service endpoint to addr/port by opening a TCP connection to
    /// it and reading the remote endpoint — the addr feeds `cast.reach` and
    /// the phone's own probes. The target is emitted without addr until this
    /// lands; the snapshot updates when it does.
    private func resolve(key: String, endpoint: NWEndpoint) {
        resolving.insert(key)
        CastDial.once(to: endpoint, timeout: 4, onReady: { [weak self] conn in
            if case let .hostPort(host, port)? = conn.currentPath?.remoteEndpoint {
                self?.resolved(key: key, host: host, port: Int(port.rawValue))
            }
        }, completion: { [weak self] _ in
            self?.resolving.remove(key)
        })
    }

    private func resolved(key: String, host: NWEndpoint.Host, port: Int) {
        guard var t = targets[key] else { return }
        var addr: String
        switch host {
        case .ipv4(let a): addr = "\(a)"
        case .ipv6(let a): addr = "\(a)"
        case .name(let n, _): addr = n
        @unknown default: return
        }
        if let pct = addr.firstIndex(of: "%") { addr = String(addr[..<pct]) }   // strip scope
        guard t.addr != addr || t.port != port else { return }
        t.addr = addr
        t.port = port
        targets[key] = t
        emit()
    }
}
