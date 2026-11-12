import Foundation

/// Picks the icon a page declares and decides whether a fetched icon may be used, so the app can
/// show favicons without asking any third-party service.
public enum FaviconSource {
    /// One `<link>` element whose `rel` mentions an icon.
    public struct Link: Sendable, Equatable {
        public var rel: String
        public var href: String
        public var sizes: String?

        public init(rel: String, href: String, sizes: String? = nil) {
            self.rel = rel
            self.href = href
            self.sizes = sizes
        }

        /// One element of the page script's result: `{rel, href, sizes}`; nil when it has no href.
        public init?(scriptResult: Any) {
            guard let dict = scriptResult as? [String: Any], let href = dict["href"] as? String, !href.isEmpty
            else { return nil }
            self.init(rel: dict["rel"] as? String ?? "", href: href, sizes: dict["sizes"] as? String)
        }
    }

    /// The largest icon body the app accepts.
    public static let maxBytes = 512 * 1024

    /// The size a rail icon is drawn at on a Retina screen; declared sizes are ranked by distance to it.
    static let preferredSize = 32

    /// Best icon URL for `page`: an `icon` link (SVG first, else the declared size closest to 32,
    /// the larger on a tie, else the first), then `apple-touch-icon`, then `<origin>/favicon.ico`.
    /// Only web pages get an icon, and only http(s) or `data:` icon URLs are returned.
    public static func candidate(page: URL, links: [Link]) -> URL? {
        guard Origin.isWeb(page) else { return nil }
        let candidates = links.compactMap { Candidate.resolve($0, against: page) }
        let icons = candidates.filter { $0.rel.contains("icon") }
        if let svg = icons.first(where: { $0.url.pathExtension.lowercased() == "svg" }) { return svg.url }
        // Closest to 32 wins; on a tie the larger one, which downscales cleanly.
        let sized = icons.compactMap { icon in icon.size.map { (rank: rank($0), url: icon.url) } }
        if let closest = sized.min(by: { $0.rank < $1.rank }) { return closest.url }
        if let first = icons.first ?? candidates.first(where: { $0.rel.contains("apple-touch-icon") }) {
            return first.url
        }
        return URL(string: Origin(url: page).description + "/favicon.ico")
    }

    /// Whether a fetched icon may be used, judged from the response before reading its body.
    public static func accepts(statusCode: Int?, mimeType: String?, expectedLength: Int64) -> Bool {
        if let statusCode, !(200..<300).contains(statusCode) { return false }
        guard let mimeType, mimeType.lowercased().hasPrefix("image/") else { return false }
        return expectedLength <= Int64(maxBytes)
    }

    /// A link resolved against its page, with its `rel` tokens and declared width parsed once.
    private struct Candidate {
        let rel: Set<String>
        let size: Int?
        let url: URL

        static func resolve(_ link: Link, against page: URL) -> Candidate? {
            guard let url = URL(string: link.href, relativeTo: page)?.absoluteURL,
                ["http", "https", "data"].contains(url.scheme?.lowercased() ?? "")
            else { return nil }
            let rel = Set(link.rel.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
            // The first `WxH` in `sizes`, as its width.
            let size = link.sizes?.lowercased().split(separator: " ").lazy
                .compactMap { $0.split(separator: "x").first.flatMap { Int($0) } }.first
            return Candidate(rel: rel, size: size, url: url)
        }
    }

    private static func rank(_ size: Int) -> (Int, Int) { (abs(size - preferredSize), -size) }
}
