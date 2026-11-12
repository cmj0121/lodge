import Foundation

/// How safe the connection to the shown page is, for the address bar's security icon.
public enum SiteSecurity: Equatable, Sendable {
    case none
    case secure
    case mixed
    case insecure
    case local

    /// `file:` and loopback hosts are local whatever their scheme; `https` is secure only when every
    /// subresource was too. No page, `about:` and any other scheme give `.none`.
    public init(url: URL?, hasOnlySecureContent: Bool) {
        guard let url else {
            self = .none
            return
        }
        let origin = Origin(url: url)
        if origin.scheme == "file" {
            self = .local
        } else if !Origin.isWeb(url) {
            self = .none
        } else if Self.isLoopback(origin.host) {
            self = .local
        } else if origin.scheme == "https" {
            self = hasOnlySecureContent ? .secure : .mixed
        } else {
            self = .insecure
        }
    }

    /// An SF Symbol name.
    public var symbol: String {
        switch self {
        case .none: "globe"
        case .secure: "lock.fill"
        case .mixed: "lock.trianglebadge.exclamationmark"
        case .insecure: "lock.open"
        case .local: "doc"
        }
    }

    public var summary: String {
        switch self {
        case .none: "No page is loaded."
        case .secure: "The connection to this site is secure."
        case .mixed: "This page loads some content over an insecure connection."
        case .insecure: "The connection to this site is not secure."
        case .local: "This page is on this computer."
        }
    }

    /// localhost, 127.0.0.0/8 or ::1.
    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || IPHost(host)?.isLoopback == true
    }
}
