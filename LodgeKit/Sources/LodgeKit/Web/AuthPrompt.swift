import Foundation

/// What the sign-in sheet shows for an HTTP authentication challenge, and whether a challenge gets one at all (D2, D3).
public struct AuthPrompt: Equatable, Sendable {
    /// The protection space host, with ":port" only when the port is not the scheme's default.
    public let host: String
    /// The registrable domain of the space host (an IP or a host with no public suffix whole), named in the title so a
    /// long host cannot pass its first labels off as the site.
    public let site: String
    /// `host` for the body, cut from the left to 60 characters with a leading "…" so its end stays visible.
    public let shownHost: String
    /// Stripped of control, format and line or paragraph separator characters, runs of whitespace made one space,
    /// trimmed, nil when empty, cut to 60 characters with "…"; shown quoted, never in the title.
    public let realm: String?
    /// The name and password would be sent without encryption.
    public let isPlainHTTP: Bool
    /// A name and password were already tried for this challenge and refused.
    public let failed: Bool
    /// The name to prefill.
    public let proposedUser: String?
    /// The space is the main frame's navigation target: same scheme, host and port.
    public let isNavigationTarget: Bool

    private static let realmLimit = 60
    private static let hostLimit = 60

    /// Basic, Digest and NTLM ask for a name and password; server trust, client certificates and Negotiate do not.
    public static func prompts(for method: String) -> Bool {
        [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM]
            .contains(method)
    }

    /// Nil when the method does not prompt, or when the space's registrable domain differs from `pageSite` and the
    /// space is not at `navigation` (the origin of the main frame's committed page or provisional target, as
    /// provisional start and server redirect report it) by scheme, host and port.
    public init?(space: URLProtectionSpace, previousFailureCount: Int, proposedUser: String?,
                 pageSite: String?, navigation: Origin?) {
        guard Self.prompts(for: space.authenticationMethod) else { return nil }
        let spaceHost = space.host.lowercased()
        let defaultPort = space.protocol == NSURLProtectionSpaceHTTP ? 80 : 443
        let spacePort = space.port == 0 ? defaultPort : space.port
        isNavigationTarget = navigation.map { Self.isAt($0, scheme: space.protocol, host: spaceHost, port: spacePort) }
            ?? false
        let spaceSite = Self.site(of: spaceHost)
        guard isNavigationTarget || (pageSite != nil && spaceSite == pageSite?.lowercased()) else { return nil }
        host = spacePort == defaultPort ? space.host : "\(Self.bracketed(space.host)):\(space.port)"
        site = spaceSite ?? spaceHost
        shownHost = host.count > Self.hostLimit ? "…" + host.suffix(Self.hostLimit - 1) : host
        realm = Self.shown(realm: space.realm)
        isPlainHTTP = !space.receivesCredentialSecurely
        failed = previousFailureCount > 0
        self.proposedUser = proposedUser
    }

    private static func isAt(_ origin: Origin, scheme: String?, host: String, port: Int) -> Bool {
        guard let scheme = scheme?.lowercased(), origin.scheme == scheme else { return false }
        let originPort = origin.port ?? (scheme == "http" ? 80 : 443)
        return unbracketed(origin.host) == unbracketed(host) && originPort == port
    }

    private static func site(of host: String) -> String? {
        URL(string: "https://\(bracketed(host))").flatMap(RegistrableDomain.of)
    }

    /// An IPv6 host in brackets, as a URL or "host:port" writes it; any other host as given.
    private static func bracketed(_ host: String) -> String {
        guard case .v6 = IPHost(host), !host.hasPrefix("[") else { return host }
        return "[\(host)]"
    }

    private static func unbracketed(_ host: String) -> String {
        host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    }

    /// Hidden characters go, a newline or separator counting as a space, so the realm reads as the one line it shows.
    private static func shown(realm: String?) -> String? {
        guard let realm else { return nil }
        var scalars = String.UnicodeScalarView()
        for scalar in realm.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                if scalar.properties.isWhitespace { scalars.append(" ") }
            default: scalars.append(scalar)
            }
        }
        let words = String(scalars).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        let line = words.joined(separator: " ")
        return line.count > realmLimit ? line.prefix(realmLimit) + "…" : line
    }
}
