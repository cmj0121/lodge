import Foundation

/// Turns what the user typed into the address bar into the URL to load.
public enum AddressInput {
    private static let schemes: Set<String> = ["http", "https", "file", "about"]

    /// A URL with a known scheme as is, a host-like text with `https://` (`http://` for localhost and
    /// IP addresses), anything else (trimmed) as a search with `engine` (`SearchEngine.url(for:)`).
    /// A `lodge:` address gives its page's canonical URL, or nil when it names none; it is never a search.
    /// Blank text gives nil.
    public static func url(from text: String, engine: SearchEngine = .duckDuckGo) -> URL? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        switch reading(input) {
        case .address(let url): return url
        case .search: return engine.url(for: input)
        }
    }

    /// Whether `url(from:)` would search for `text` rather than go to an address. Blank text gives false.
    public static func isSearch(_ text: String) -> Bool {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, case .search = reading(input) else { return false }
        return true
    }

    private enum Reading {
        /// nil for a `lodge:` address that names no page.
        case address(URL?)
        case search
    }

    /// What trimmed, non-blank `input` is, as `url(from:)` reads it.
    private static func reading(_ input: String) -> Reading {
        if input.lowercased().hasPrefix(LodgePage.scheme + ":") {
            return .address(URL(string: input).flatMap(LodgePage.init)?.url)
        }
        if let url = URL(string: input), let scheme = url.scheme?.lowercased(), schemes.contains(scheme) {
            return .address(url)
        }
        if !input.contains(where: \.isWhitespace), let url = hostLikeURL(input) {
            return .address(url)
        }
        return .search
    }

    private static func hostLikeURL(_ input: String) -> URL? {
        guard let components = URLComponents(string: "https://" + input), let host = components.host?.lowercased(),
            components.user == nil
        else { return nil }
        if host == "localhost" || IPHost(host) != nil {
            return URL(string: "http://" + input)
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }), let tld = labels.last, tld.count >= 2,
            tld.allSatisfy(\.isLetter)
        else { return nil }
        return components.url
    }
}
