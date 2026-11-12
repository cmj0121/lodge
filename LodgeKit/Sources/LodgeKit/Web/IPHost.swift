import Network

/// A host written as an IP address: a dotted quad, or an IPv6 address, bare or in brackets.
enum IPHost {
    case v4(IPv4Address)
    case v6(IPv6Address)

    init?(_ host: String) {
        if host.split(separator: ".", omittingEmptySubsequences: false).count == 4, let address = IPv4Address(host) {
            self = .v4(address)
            return
        }
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        guard let address = IPv6Address(bare) else { return nil }
        self = .v6(address)
    }

    /// 127.0.0.0/8 or ::1.
    var isLoopback: Bool {
        switch self {
        case .v4(let address): address.rawValue.first == 127
        case .v6(let address): address.isLoopback
        }
    }
}
