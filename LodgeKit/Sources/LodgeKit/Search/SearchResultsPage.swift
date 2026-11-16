import Foundation

/// Tells a search engine's results page by its address, so the address bar can show the words searched for.
public enum SearchResultsPage {
    private static let marker = SearchEngine.marker

    /// The engine and the words when `url` is a results page of one of `engines` (a catalog's `available`):
    /// the engine's template is `https`, its `%s` is the whole value of one query item, and `url` has scheme
    /// `https`, the same host (case-insensitive) and the same path exactly, with that item non-empty after
    /// decoding (`+` as space, runs of whitespace as one space, trimmed). First match in `engines` order wins. `http`
    /// templates, a `%s` in the path or host, redirects (`/url?q=`), look-alike hosts and other paths give nil, and so
    /// do words that could pass for an address or hide what they say (see `shownWords`), so the real URL is shown.
    public static func match(_ url: URL, engines: [SearchEngine]) -> (engine: SearchEngine, words: String)? {
        guard let page = URLComponents(url: url, resolvingAgainstBaseURL: false), page.scheme?.lowercased() == "https"
        else { return nil }
        for engine in engines {
            if let words = value(in: page, template: engine.template).flatMap(shownWords) { return (engine, words) }
        }
        return nil
    }

    /// The percent-encoded value of the template's `%s` item in `page`; nil when `page` is not that template's page
    /// or the template has `%s` anywhere but as the whole value of exactly one query item.
    private static func value(in page: URLComponents, template: String) -> String? {
        guard !template.contains(marker),
            let search = URLComponents(string: template.replacingOccurrences(of: "%s", with: marker)),
            search.scheme?.lowercased() == "https", let host = search.host, !host.contains(marker),
            !search.percentEncodedPath.contains(marker), search.fragment?.contains(marker) != true,
            let items = search.percentEncodedQueryItems,
            items.filter({ $0.value?.contains(marker) == true || $0.name.contains(marker) }).count == 1,
            let name = items.first(where: { $0.value == marker })?.name,
            page.host?.lowercased() == host.lowercased(), page.port == search.port,
            page.percentEncodedPath == search.percentEncodedPath
        else { return nil }
        return page.percentEncodedQueryItems?.first(where: { $0.name == name })?.value
    }

    /// `value` decoded (`+` as space) with runs of whitespace collapsed to one space and trimmed; nil when that is
    /// empty, holds a control or format character (newlines, tabs, bidi overrides and isolates included), or looks
    /// like an address: it has `://`, starts with a scheme and its colon as RFC 3986 spells one (`javascript:`,
    /// `mailto:`), or `AddressInput` would go to it rather than search for it.
    private static func shownWords(_ value: String) -> String? {
        guard let decoded = value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
            !decoded.unicodeScalars.contains(where: hidesText)
        else { return nil }
        let words = decoded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty, !words.contains("://"), words.prefixMatch(of: /[A-Za-z][A-Za-z0-9+.\-]*:/) == nil,
            AddressInput.isSearch(words)
        else { return nil }
        return words
    }

    private static func hidesText(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: true
        default: false
        }
    }
}
