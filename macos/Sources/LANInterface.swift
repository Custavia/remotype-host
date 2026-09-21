import Foundation

/// LAN-IP selection for the browser cast HTTP server (CASTING.md §6.7). The
/// Remotype-link listener binds wildcard (Tailscale connect-by-IP depends on
/// it), but the browser MJPEG server must serve on a real LAN address a viewing
/// browser can dial — so we enumerate interfaces and pick one, EXCLUDING VPN /
/// tunnel / link-local / Tailscale-CGNAT addresses that no LAN peer can reach.
///
/// `pick()` returns nil when the Mac is only on such interfaces (e.g. Tailscale
/// only) — the caller then answers `cast.err unreachable` (§6.7 copy).
enum LANInterface {
    /// Interface name prefixes that are never a plain-LAN interface: VPN/utun
    /// tunnels, IPSec, PPP, and Apple's peer-to-peer radios (AWDL / low-latency
    /// Wi-Fi) which carry no routable LAN address a browser can open a socket to.
    private static let excludedPrefixes = ["utun", "ipsec", "ppp", "awdl", "llw"]

    /// Chosen LAN IPv4 address, or nil if the host has no browser-reachable LAN
    /// interface. Prefers the address on the DEFAULT ROUTE (the exact IP a LAN
    /// browser reaches the host at), falling back to `en*` enumeration.
    static func pick() -> String? {
        // The default-route source IP is authoritative: it is the interface the
        // OS actually routes LAN/Internet traffic through, so a browser on that
        // LAN dials the host at exactly this address. A bare "first en*" scan can
        // hand out a secondary/idle en interface (USB-tether, second NIC, bridge)
        // that no browser can reach. Only trust it if it survives the VPN/CGNAT
        // exclusions; else enumerate.
        if let primary = primaryRouteIP(), !isExcludedAddress(primary) { return primary }
        return enumerateLAN()
    }

    /// The local source address the kernel would use to reach a public host —
    /// i.e. the default-route (primary LAN) interface. A UDP "connect" sends no
    /// packets; it just resolves the route so `getsockname` reveals the source IP.
    private static func primaryRouteIP() -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var dst = sockaddr_in()
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port = in_port_t(9).bigEndian     // discard port; irrelevant, no send
        inet_pton(AF_INET, "8.8.8.8", &dst.sin_addr)
        let cr = withUnsafePointer(to: &dst) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard cr == 0 else { return nil }         // no default route (offline)
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let gr = withUnsafeMutablePointer(to: &local) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard gr == 0 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &local.sin_addr, &buf, socklen_t(buf.count))
        return String(cString: buf)
    }

    /// getifaddrs fallback (§6.7) when the default route is a VPN/tunnel or absent.
    private static func enumerateLAN() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var candidates: [(name: String, ip: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = cursor {
            defer { cursor = cur.pointee.ifa_next }
            let flags = cur.pointee.ifa_flags
            // Up, and NOT loopback.
            guard (flags & UInt32(IFF_UP)) == UInt32(IFF_UP),
                  (flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            // IPv4 only.
            guard let addr = cur.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            if excludedPrefixes.contains(where: { name.hasPrefix($0) }) { continue }
            // Numeric host string.
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                 &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard rc == 0 else { continue }
            let ip = String(cString: host)
            if isExcludedAddress(ip) { continue }
            candidates.append((name, ip))
        }

        // Prefer a real Ethernet/Wi-Fi interface, else any surviving candidate.
        if let en = candidates.first(where: { $0.name.hasPrefix("en") }) { return en.ip }
        return candidates.first?.ip
    }

    /// Reject 169.254/16 (link-local, no DHCP) and 100.64/10 (CGNAT — Tailscale
    /// hands out addresses in this range, unreachable to a plain-LAN browser).
    private static func isExcludedAddress(_ ip: String) -> Bool {
        if ip.hasPrefix("169.254.") { return true }
        let parts = ip.split(separator: ".")
        if parts.count == 4, parts[0] == "100", let o2 = Int(parts[1]),
           (64...127).contains(o2) { return true }
        return false
    }
}
