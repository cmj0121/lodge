import Foundation

/// One of Lodge's own pages, shown natively in a tab at a `lodge://` address (D1, D2).
public enum LodgePage: String, CaseIterable, Hashable, Sendable {
    case settings, history, protection

    public static let scheme = "lodge"

    /// `lodge://settings` / `lodge://history` / `lodge://protection`, scheme and host compared ignoring case (via URLComponents); path
    /// empty or "/", no user, password, port, query or fragment. Anything else, `lodge:` included, is nil.
    public init?(url: URL) {
        guard Self.isLodge(url), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.user == nil, components.password == nil, components.port == nil, components.query == nil,
            components.fragment == nil, components.path.isEmpty || components.path == "/",
            let host = components.host?.lowercased(), let page = LodgePage(rawValue: host)
        else { return nil }
        self = page
    }

    /// The canonical form, lower-case, no trailing slash: `lodge://settings`, `lodge://history`, `lodge://protection`.
    /// The protection page carries no site in its address; the pane hands it the one it is opened for (D5).
    public var url: URL { URL(string: "\(Self.scheme)://\(rawValue)")! }

    /// The scheme of `url` is `lodge` (any case), whether or not it names a page.
    public static func isLodge(_ url: URL?) -> Bool { url?.scheme?.lowercased() == scheme }

    /// Localized in LodgeKit: "Settings" / "History" / "Fingerprint protection".
    public var title: String {
        switch self {
        case .settings: String(localized: "Settings", bundle: .module)
        case .history: String(localized: "History", bundle: .module)
        case .protection: String(localized: "Fingerprint protection", bundle: .module)
        }
    }

    /// SF Symbol: "gearshape" / "clock" / "touchid".
    public var symbol: String {
        switch self {
        case .settings: "gearshape"
        case .history: "clock"
        case .protection: "touchid"
        }
    }
}

extension BrowserTab {
    /// The page the tab shows; nil for web or blank tabs and for a `lodge:` URL that names no page.
    public var lodgePage: LodgePage? { url.flatMap(LodgePage.init(url:)) }
}
