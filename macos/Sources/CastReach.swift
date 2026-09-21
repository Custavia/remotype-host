import Foundation
import Network

/// Reachability probe (CASTING.md §4 Step 2): a plain TCP connect to the
/// sink's advertised address with a 1 500 ms budget. The handshake completing
/// is the whole test — no protocol exchange — and the connection is torn down
/// immediately either way. Answers the phone's `cast.reach` and confirms
/// "host on sink LAN" before a host-controlled start.
enum CastReach {
    static let timeout: TimeInterval = 1.5

    /// Probe `addr:port`; `completion` fires exactly once, on .main.
    static func probe(addr: String, port: Int, completion: @escaping (Bool) -> Void) {
        guard (1...65535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        CastDial.once(to: .hostPort(host: NWEndpoint.Host(addr), port: nwPort),
                      timeout: timeout, completion: completion)
    }
}

/// The shared one-shot NWConnection dial: open, tear down as soon as the
/// handshake reaches `.ready` (or `.failed`/`.cancelled`/timeout). Used by both
/// `CastReach.probe` (reachability) and `CastDiscovery.resolve` (addr/port). The
/// single owner of the finished-flag / stateUpdateHandler-nil-out / cancel /
/// deadline lifecycle so the two paths can never drift.
enum CastDial {
    /// Dial `endpoint` once. `onReady` runs with the live connection just before
    /// teardown (read `currentPath?.remoteEndpoint` here); `completion` fires
    /// exactly once on .main with whether `.ready` was reached.
    static func once(to endpoint: NWEndpoint, timeout: TimeInterval,
                     onReady: ((NWConnection) -> Void)? = nil,
                     completion: ((Bool) -> Void)? = nil) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        var finished = false
        let finish: (Bool) -> Void = { ok in
            guard !finished else { return }
            finished = true
            conn.stateUpdateHandler = nil
            conn.cancel()
            completion?(ok)
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                onReady?(conn)
                finish(true)
            case .failed, .cancelled:
                finish(false)
            default: break
            }
        }
        conn.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(false) }
    }
}
