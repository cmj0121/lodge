import Foundation
import SwiftSoup

/// The Netscape bookmark file every browser imports and exports: nested `<DL>` lists of `<DT>` entries, each a
/// folder (`<H3>` with its own `<DL>`) or a link (`<A HREF>`).
public enum NetscapeBookmarks {
    public enum ImportError: Error, Equatable { case notABookmarkFile }

    /// The most folder levels an import keeps below the folder it makes.
    public static let maxDepth = 64

    /// Netscape bookmark file of `root`'s children (root itself is the file, not a folder in it), titles and URLs
    /// HTML-escaped.
    public static func export(_ root: BookmarkFolder) -> String {
        var lines = [
            "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
            "<!-- This is an automatically generated file. It will be read and overwritten. DO NOT EDIT! -->",
            "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">",
            "<TITLE>Bookmarks</TITLE>",
            "<H1>Bookmarks</H1>",
        ]
        append(root.children, depth: 0, to: &lines)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Parses with SwiftSoup into a folder (title `title`, collapsed) holding the file's top-level list, keeping
    /// folder nesting and order. Only http/https links are kept; an empty link title falls back to the host;
    /// folders that end up empty are kept, but none deeper than `maxDepth`: its links go into the deepest folder
    /// kept. Throws `.notABookmarkFile` when there is no `<DL>`.
    ///
    /// Safari leaves out the outer `<DL>`, so when the first `<DL>` is a folder's, the list holding that
    /// folder's `<DT>` is the top level.
    public static func parse(_ html: String, title: String) throws -> BookmarkFolder {
        guard let document = try? SwiftSoup.parse(html), let first = try? document.select("dl").first() else {
            throw ImportError.notABookmarkFile
        }
        let top = first.parent().flatMap { $0.tagName() == "dt" ? $0.parent() : nil } ?? first
        return BookmarkFolder(title: title, children: nodes(in: top, depth: 0))
    }

    private static func append(_ nodes: [BookmarkNode], depth: Int, to lines: inout [String]) {
        let indent = String(repeating: "    ", count: depth)
        lines.append("\(indent)<DL><p>")
        for node in nodes {
            switch node {
            case .link(let link):
                lines.append(
                    "\(indent)    <DT><A HREF=\"\(escape(link.url.absoluteString))\">\(escape(link.title))</A>")
            case .folder(let folder):
                lines.append("\(indent)    <DT><H3>\(escape(folder.title))</H3>")
                append(folder.children, depth: depth + 1, to: &lines)
            }
        }
        lines.append("\(indent)</DL><p>")
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The entries of one `<DL>` filling a folder `depth` levels below the imported one. The HTML5 parser leaves
    /// each `<DT>` directly in its list, with a folder's `<DL>` inside the `<DT>` after its `<H3>`; a `<DL>` that
    /// lands beside its `<DT>` instead belongs to the folder just before it, and wrappers such as `<p>` are looked
    /// through. Everything that adds no folder level is walked with an explicit stack, so only a new folder
    /// recurses: at `maxDepth` none is made and a deeper folder's entries join this one in document order.
    private static func nodes(in list: Element, depth: Int) -> [BookmarkNode] {
        let nests = depth < maxDepth
        var nodes: [BookmarkNode] = []
        var openFolder: BookmarkFolder?
        var pending = Array(list.children().reversed())

        func closeFolder() {
            if let folder = openFolder { nodes.append(.folder(folder)) }
            openFolder = nil
        }

        func children(of element: Element, _ tag: String) -> [Element] {
            element.children().filter { $0.tagName() == tag }
        }

        while let element = pending.popLast() {
            switch element.tagName() {
            case "dt":
                closeFolder()
                let sublists = children(of: element, "dl")
                if nests, let heading = children(of: element, "h3").first {
                    openFolder = BookmarkFolder(
                        title: (try? heading.text()) ?? "",
                        children: sublists.flatMap { Self.nodes(in: $0, depth: depth + 1) })
                    if !sublists.isEmpty { closeFolder() }
                    continue
                }
                if let anchor = children(of: element, "a").first, let link = link(anchor) {
                    nodes.append(.link(link))
                }
                pending += sublists.reversed()
            case "dl" where nests && openFolder != nil:
                openFolder?.children += Self.nodes(in: element, depth: depth + 1)
                closeFolder()
            default:
                pending += element.children().reversed()
            }
        }
        closeFolder()
        return nodes
    }

    private static func link(_ anchor: Element) -> SavedLink? {
        guard let href = try? anchor.attr("href"),
            let url = URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        let text = ((try? anchor.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return SavedLink(url: url, title: text.isEmpty ? url.host() ?? url.absoluteString : text)
    }
}
