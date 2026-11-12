import Foundation
import Network

/// Turns what the user typed into the address bar into the URL to load.
public enum AddressInput {
    private static let searchTemplate = "https://duckduckgo.com/?q=%s"
    private static let schemes: Set<String> = ["http", "https", "file", "about"]
    private static let queryAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=#?"))

    /// A URL with a known scheme as is, a host-like text with `https://` (`http://` for localhost and
    /// IP addresses), anything else as a DuckDuckGo search.
    /// Blank text gives nil.
    public static func url(from text: String) -> URL? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        if let url = URL(string: input), let scheme = url.scheme?.lowercased(), schemes.contains(scheme) {
            return url
        }
        if !input.contains(where: \.isWhitespace), let url = hostLikeURL(input) {
            return url
        }
        guard let query = input.addingPercentEncoding(withAllowedCharacters: queryAllowed) else { return nil }
        return URL(string: searchTemplate.replacingOccurrences(of: "%s", with: query))
    }

    private static func hostLikeURL(_ input: String) -> URL? {
        guard let components = URLComponents(string: "https://" + input), let host = components.host?.lowercased(),
            components.user == nil
        else { return nil }
        if host == "localhost" || isIPAddress(host) {
            return URL(string: "http://" + input)
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }), let tld = labels.last, tld.count >= 2,
            tld.allSatisfy(\.isLetter)
        else { return nil }
        return components.url
    }

    private static func isIPAddress(_ host: String) -> Bool {
        let isDottedQuad = host.split(separator: ".", omittingEmptySubsequences: false).count == 4
        if isDottedQuad && IPv4Address(host) != nil { return true }
        guard host.hasPrefix("["), host.hasSuffix("]") else { return false }
        return IPv6Address(String(host.dropFirst().dropLast())) != nil
    }
}
