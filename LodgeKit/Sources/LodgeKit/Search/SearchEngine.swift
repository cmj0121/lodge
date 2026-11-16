import Foundation

/// A web search engine: the address a search goes to, the words standing in for each `%s`.
public struct SearchEngine: Identifiable, Hashable, Codable, Sendable {
    /// Built-ins: "duckduckgo", "google", "bing", "kagi", "brave", "startpage". Added: a UUID string.
    public let id: String
    public var name: String
    /// `https`/`http` URL text with at least one `%s`.
    public var template: String

    public init(id: String, name: String, template: String) {
        self.id = id
        self.name = name
        self.template = template
    }

    public static let duckDuckGo = SearchEngine(
        id: "duckduckgo", name: "DuckDuckGo", template: "https://duckduckgo.com/?q=%s")

    /// In this order: DuckDuckGo, Google, Bing, Kagi, Brave, Startpage. Names are brand names, never localized.
    public static let builtIns: [SearchEngine] = [
        duckDuckGo,
        SearchEngine(id: "google", name: "Google", template: "https://www.google.com/search?q=%s"),
        SearchEngine(id: "bing", name: "Bing", template: "https://www.bing.com/search?q=%s"),
        SearchEngine(id: "kagi", name: "Kagi", template: "https://kagi.com/search?q=%s"),
        SearchEngine(id: "brave", name: "Brave", template: "https://search.brave.com/search?q=%s"),
        SearchEngine(id: "startpage", name: "Startpage", template: "https://www.startpage.com/sp/search?query=%s"),
    ]

    /// One of `builtIns`, by id.
    public var isBuiltIn: Bool { Self.builtIns.contains { $0.id == id } }

    private static let placeholder = "%s"
    private static let schemes: Set<String> = ["http", "https"]
    /// What a query keeps unencoded: URL query characters, less those that would end or split its value.
    private static let queryAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=#?"))

    /// Every `%s` replaced by the query percent-encoded (`&`, `+`, `=`, `#` and `?` included); nil if the result is
    /// no URL.
    public func url(for query: String) -> URL? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: Self.queryAllowed) else { return nil }
        return URL(string: template.replacingOccurrences(of: Self.placeholder, with: encoded))
    }

    public enum EditError: Error, Equatable {
        case emptyName, missingPlaceholder, unsupportedScheme, invalidAddress, builtInIsFixed, unknown(String)

        /// Why the engine was not saved, as the line under its fields says it.
        public var message: String {
            switch self {
            case .emptyName: String(localized: "Enter a name.", bundle: .module)
            case .missingPlaceholder:
                String(localized: "Put \(SearchEngine.placeholder) where your search words go.", bundle: .module)
            case .unsupportedScheme:
                String(localized: "Use an address that starts with https:// or http://.", bundle: .module)
            case .invalidAddress: String(localized: "Enter a valid web address.", bundle: .module)
            case .builtInIsFixed: String(localized: "Built-in engines can’t be changed or removed.", bundle: .module)
            case .unknown: String(localized: "This engine no longer exists.", bundle: .module)
            }
        }
    }

    /// Trimmed name and template, or why they are refused, checked in this order: an empty name, no `%s`, a
    /// template that is no URL with a scheme once `%s` is filled in (`.invalidAddress`), a scheme other than `http`
    /// or `https`, no host (`.invalidAddress`).
    public static func validate(name: String, template: String) -> Result<(name: String, template: String), EditError>
    {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.emptyName) }
        guard template.contains(placeholder) else { return .failure(.missingPlaceholder) }
        guard let components = URLComponents(string: template.replacingOccurrences(of: placeholder, with: "x")),
            let scheme = components.scheme
        else { return .failure(.invalidAddress) }
        guard schemes.contains(scheme.lowercased()) else { return .failure(.unsupportedScheme) }
        guard components.host?.isEmpty == false else { return .failure(.invalidAddress) }
        return .success((name, template))
    }
}
