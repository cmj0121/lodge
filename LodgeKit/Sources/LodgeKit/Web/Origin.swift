import Foundation

/// A web security origin: `scheme://host[:port]`, `scheme:` when it has no host, or opaque when it
/// has no scheme (a sandboxed or `data:` frame).
public struct Origin: Hashable, Sendable, CustomStringConvertible {
    public let scheme: String
    public let host: String
    public let port: Int?

    public init(url: URL) {
        self.init(scheme: url.scheme ?? "", host: url.host() ?? "", port: url.port ?? 0)
    }

    /// Port 0, as WebKit reports a default port, means none.
    public init(scheme: String, host: String, port: Int) {
        self.scheme = scheme.lowercased()
        self.host = host.lowercased()
        self.port = port > 0 ? port : nil
    }

    public var isOpaque: Bool { scheme.isEmpty }

    public var description: String {
        if isOpaque { return "null" }
        guard !host.isEmpty else { return "\(scheme):" }
        return port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }
}
