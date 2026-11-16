import Foundation

/// Tells a search engine's results page by its address, so the address bar can show the words searched for.
public enum SearchResultsPage {
    /// Stands in for `%s` while a template is parsed, as `%s` alone is no valid percent escape.
    private static let marker = "LODGESEARCHWORDS"

    /// The engine and the words when `url` is a results page of one of `engines` (a catalog's `available`):
    /// the engine's template is `https`, its `%s` is the whole value of one query item, and `url` has scheme
    /// `https`, the same host (case-insensitive) and the same path exactly, with that item non-empty after
    /// decoding (`+` as space, trimmed). First match in `engines` order wins. `http` templates, a `%s` in the path
    /// or host, redirects (`/url?q=`), look-alike hosts and other paths give nil.
    public static func match(_ url: URL, engines: [SearchEngine]) -> (engine: SearchEngine, words: String)? {
        guard let page = URLComponents(url: url, resolvingAgainstBaseURL: false), page.scheme?.lowercased() == "https"
        else { return nil }
        for engine in engines {
            if let words = words(in: page, template: engine.template) { return (engine, words) }
        }
        return nil
    }

    /// The decoded, trimmed value of the template's `%s` item in `page`; nil when `page` is not that template's page
    /// or the template has `%s` anywhere but as the whole value of exactly one query item.
    private static func words(in page: URLComponents, template: String) -> String? {
        guard !template.contains(marker),
            let search = URLComponents(string: template.replacingOccurrences(of: "%s", with: marker)),
            search.scheme?.lowercased() == "https", let host = search.host, !host.contains(marker),
            !search.percentEncodedPath.contains(marker), search.fragment?.contains(marker) != true,
            let items = search.percentEncodedQueryItems,
            items.filter({ $0.value?.contains(marker) == true || $0.name.contains(marker) }).count == 1,
            let name = items.first(where: { $0.value == marker })?.name,
            page.host?.lowercased() == host.lowercased(), page.port == search.port,
            page.percentEncodedPath == search.percentEncodedPath,
            let value = page.percentEncodedQueryItems?.first(where: { $0.name == name })?.value,
            let words = value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !words.isEmpty
        else { return nil }
        return words
    }
}
