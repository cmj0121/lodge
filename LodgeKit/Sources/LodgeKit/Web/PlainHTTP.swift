import Foundation

/// Which main-frame loads are warned about before anything is sent (D8): a plain `http:` page whose host is neither on
/// this computer (localhost, 127.0.0.0/8, ::1, unless `exemptsLoopback` is off) nor allowed in the tab's store.
public enum PlainHTTP {
    /// The host a Continue allows, lowercased with no port or brackets; nil for anything but `http:` with a host.
    public static func host(of url: URL) -> String? {
        let origin = Origin(url: url)
        guard origin.scheme == "http" else { return nil }
        let host = origin.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host.isEmpty ? nil : host
    }

    public static func warns(_ url: URL, allowed: Set<String>, exemptsLoopback: Bool = true) -> Bool {
        guard let host = host(of: url), !allowed.contains(host) else { return false }
        return !(exemptsLoopback && SiteSecurity.isLoopback(host))
    }
}
