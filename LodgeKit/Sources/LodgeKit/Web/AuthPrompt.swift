import Foundation

/// What the sign-in sheet shows for an HTTP authentication challenge, and whether a challenge gets one at all (D2, D3).
public struct AuthPrompt: Equatable, Sendable {
    /// The protection space host, with ":port" only when the port is not the scheme's default.
    public let host: String
    /// Trimmed, nil when empty, cut to 60 characters with "…"; shown quoted, never in the title.
    public let realm: String?
    /// The name and password would be sent without encryption.
    public let isPlainHTTP: Bool
    /// A name and password were already tried for this challenge and refused.
    public let failed: Bool
    /// The name to prefill.
    public let proposedUser: String?

    private static let realmLimit = 60

    /// Basic, Digest and NTLM ask for a name and password; server trust, client certificates and Negotiate do not.
    public static func prompts(for method: String) -> Bool {
        [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM]
            .contains(method)
    }

    /// Nil when the method does not prompt, or when the space's registrable domain differs from `pageSite`
    /// and the space host is not `navigationHost` (the main frame's committed or provisional target host).
    public init?(space: URLProtectionSpace, previousFailureCount: Int, proposedUser: String?,
                 pageSite: String?, navigationHost: String?) {
        guard Self.prompts(for: space.authenticationMethod) else { return nil }
        let spaceHost = space.host.lowercased()
        let isNavigationTarget = navigationHost?.lowercased() == spaceHost
        guard isNavigationTarget || (pageSite != nil && Self.site(of: spaceHost) == pageSite?.lowercased()) else {
            return nil
        }
        let defaultPort = space.protocol == NSURLProtectionSpaceHTTP ? 80 : 443
        host = space.port == 0 || space.port == defaultPort ? space.host : "\(Self.bracketed(space.host)):\(space.port)"
        realm = Self.shown(realm: space.realm)
        isPlainHTTP = !space.receivesCredentialSecurely
        failed = previousFailureCount > 0
        self.proposedUser = proposedUser
    }

    private static func site(of host: String) -> String? {
        URL(string: "https://\(bracketed(host))").flatMap(RegistrableDomain.of)
    }

    /// An IPv6 host in brackets, as a URL or "host:port" writes it; any other host as given.
    private static func bracketed(_ host: String) -> String {
        guard case .v6 = IPHost(host), !host.hasPrefix("[") else { return host }
        return "[\(host)]"
    }

    private static func shown(realm: String?) -> String? {
        guard let trimmed = realm?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed.count > realmLimit ? trimmed.prefix(realmLimit) + "…" : trimmed
    }
}
