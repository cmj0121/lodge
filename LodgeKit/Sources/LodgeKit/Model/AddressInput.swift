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
        if input.lowercased().hasPrefix(LodgePage.scheme + ":") { return URL(string: input).flatMap(LodgePage.init)?.url }
        if let url = URL(string: input), let scheme = url.scheme?.lowercased(), schemes.contains(scheme) {
            return url
        }
        if !input.contains(where: \.isWhitespace), let url = hostLikeURL(input) {
            return url
        }
        return engine.url(for: input)
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
