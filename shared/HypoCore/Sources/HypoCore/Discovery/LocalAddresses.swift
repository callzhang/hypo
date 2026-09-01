import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The addresses this machine answers on.
///
/// Used to keep services running on this Mac out of the list of devices to pair
/// with. A sandboxed app cannot open a LAN connection back to its own host anyway,
/// so offering one produces a "could not reach the device" for something sitting
/// right here -- and pairing a machine with itself was never the intent.
public enum LocalAddresses {
    /// Every IPv4 and IPv6 address currently configured on this machine, loopback
    /// included, lowercased and without IPv6 zone suffixes.
    public static func current() -> Set<String> {
        var addresses: Set<String> = ["127.0.0.1", "::1", "localhost"]
        #if canImport(Darwin)
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return addresses }
        defer { freeifaddrs(ifaddr) }

        var pointer = ifaddr
        while pointer != nil {
            defer { pointer = pointer?.pointee.ifa_next }
            guard let interface = pointer?.pointee, let addr = interface.ifa_addr else { continue }

            switch addr.pointee.sa_family {
            case sa_family_t(AF_INET):
                var sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &sin.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    addresses.insert(normalize(String(cString: buffer)))
                }
            case sa_family_t(AF_INET6):
                var sin6 = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if inet_ntop(AF_INET6, &sin6.sin6_addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil {
                    addresses.insert(normalize(String(cString: buffer)))
                }
            default:
                continue
            }
        }
        #endif
        return addresses
    }

    /// True when `host` is an address or hostname belonging to this machine.
    public static func isLocal(_ host: String, addresses: Set<String>) -> Bool {
        let candidate = normalize(host)
        if addresses.contains(candidate) { return true }
        // Bonjour hands back names like "my-mac.local." for this host too.
        let hostName = ProcessInfo.processInfo.hostName.lowercased()
        let trimmedHost = candidate.hasSuffix(".") ? String(candidate.dropLast()) : candidate
        let trimmedSelf = hostName.hasSuffix(".") ? String(hostName.dropLast()) : hostName
        return !trimmedHost.isEmpty && trimmedHost == trimmedSelf
    }

    /// Lowercases, drops a trailing dot, and strips an IPv6 zone (`fe80::1%en0`).
    private static func normalize(_ host: String) -> String {
        var value = host.lowercased()
        if let percent = value.firstIndex(of: "%") {
            value = String(value[value.startIndex..<percent])
        }
        return value
    }
}
