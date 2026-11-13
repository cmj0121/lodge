import Foundation
import Testing

@testable import LodgeKit

@Suite struct NetscapeBookmarksTests {
    /// The tree as nested strings: links as "title <url>", folders as "title [children]".
    private func outline(_ nodes: [BookmarkNode]) -> [String] {
        nodes.map {
            switch $0 {
            case .link(let link): "\(link.title) <\(link.url.absoluteString)>"
            case .folder(let folder): "\(folder.title) [\(outline(folder.children).joined(separator: ", "))]"
            }
        }
    }

    /// How many folder levels lie below `folder`.
    private func depth(_ folder: BookmarkFolder) -> Int {
        folder.children.reduce(0) { deepest, node in
            guard case .folder(let child) = node else { return deepest }
            return max(deepest, depth(child) + 1)
        }
    }

    private func link(_ title: String, _ url: String) -> BookmarkNode {
        .link(SavedLink(url: URL(string: url)!, title: title))
    }

    private static let chrome = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <!-- This is an automatically generated file.
             It will be read and overwritten.
             DO NOT EDIT! -->
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>
            <DT><H3 ADD_DATE="1700000000" LAST_MODIFIED="1700000100" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
            <DL><p>
                <DT><A HREF="https://news.example/" ADD_DATE="1700000001" ICON="data:image/png;base64,iVBORw0KGgo=">News</A>
                <DT><H3 ADD_DATE="1700000002" LAST_MODIFIED="1700000003">Work</H3>
                <DL><p>
                    <DT><A HREF="https://wiki.example/start?a=1&amp;b=2" ADD_DATE="1700000004">Wiki</A>
                    <DT><A HREF="javascript:alert(1)" ADD_DATE="1700000005">Bookmarklet</A>
                </DL><p>
                <DT><A HREF="https://mail.example/" ADD_DATE="1700000006">Mail</A>
            </DL><p>
            <DT><H3 ADD_DATE="1700000007" LAST_MODIFIED="1700000008">Other bookmarks</H3>
            <DL><p>
                <DT><A HREF="https://docs.example/" ADD_DATE="1700000009">Docs</A>
            </DL><p>
        </DL><p>
        """

    private static let firefox = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <!-- This is an automatically generated file.
             It will be read and overwritten.
             DO NOT EDIT! -->
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <meta http-equiv="Content-Security-Policy"
              content="default-src 'self'; script-src 'none'; img-src data: *; object-src 'none'"></meta>
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks Menu</H1>

        <DL><p>
            <DT><A HREF="place:parent=menu________&queryType=1&sort=12&maxResults=10&excludeQueries=1">Recent Tags</A>
            <DT><H3 ADD_DATE="1700000000" LAST_MODIFIED="1700000001">Mozilla Firefox</H3>
            <DL><p>
                <DT><A HREF="https://support.mozilla.org/products/firefox" ADD_DATE="1700000002" ICON_URI="https://support.mozilla.org/favicon.ico" ICON="data:image/png;base64,AAAA">Get Help</A>
                <DT><A HREF="https://www.mozilla.org/about/" ADD_DATE="1700000003">About Us</A>
            </DL><p>
            <HR>
            <DT><H3 ADD_DATE="1700000004" LAST_MODIFIED="1700000005" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks Toolbar</H3>
        <DD>Add bookmarks to this folder to see them displayed on the Bookmarks Toolbar
            <DL><p>
                <DT><A HREF="https://blog.example/post" ADD_DATE="1700000006" LAST_MODIFIED="1700000007" TAGS="reading">Blog post</A>
        <DD>A description of the post
                <DT><A HREF="data:text/html,hi">Data</A>
                <DT><A HREF="file:///Users/me/notes.html">Notes</A>
                <DT><A HREF="https://untitled.example/page"></A>
            </DL><p>
            <DT><H3 ADD_DATE="1700000008" LAST_MODIFIED="1700000009" UNFILED_BOOKMARKS_FOLDER="true">Other Bookmarks</H3>
            <DL><p>
            </DL><p>
        </DL>
        """

    private static let safari = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        \t<HTML>
        \t<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        \t<Title>Bookmarks</Title>
        \t<H1>Bookmarks</H1>
        \t<DT><H3 FOLDED>Favorites</H3>
        \t<DL><p>
        \t\t<DT><A HREF="https://www.apple.com/">Apple</A>
        \t\t<DT><H3 FOLDED>Dev</H3>
        \t\t<DL><p>
        \t\t\t<DT><A HREF="https://developer.apple.com/">Apple Developer</A>
        \t\t</DL><p>
        \t</DL><p>
        \t<DT><H3 FOLDED>Bookmarks Menu</H3>
        \t<DL><p>
        \t</DL><p>
        \t<DT><H3 id="com.apple.ReadingList">Reading List</H3>
        \t<DL><p>
        \t\t<DT><A HREF="http://read.example/later">Read later</A>
        \t</DL><p>
        </HTML>
        """

    @Test func exportThenParseRoundTripsTheTree() throws {
        let root = BookmarkFolder(
            title: "Bookmarks", isExpanded: true,
            children: [
                link("A", "https://a.example/"),
                .folder(
                    BookmarkFolder(
                        title: "Work",
                        children: [
                            link("B", "https://b.example/x?y=1&z=2"),
                            .folder(BookmarkFolder(title: "Deep", children: [link("C", "http://c.example/")])),
                            .folder(BookmarkFolder(title: "Empty")),
                            link("D", "https://d.example/"),
                        ])),
                link("Tom & \"Jerry\" <3>", "https://e.example/"),
            ])
        let parsed = try NetscapeBookmarks.parse(NetscapeBookmarks.export(root), title: "Imported")
        #expect(parsed.title == "Imported")
        #expect(!parsed.isExpanded)
        #expect(outline(parsed.children) == outline(root.children))
    }

    @Test func exportIsAValidEscapedNetscapeFile() {
        let root = BookmarkFolder(
            title: "Bookmarks",
            children: [
                .folder(BookmarkFolder(title: "R&D <new>", children: [link("Q", "https://q.example/s?a=1&b=2")])),
                link("Tom & \"Jerry\" <3>", "https://e.example/"),
            ])
        let html = NetscapeBookmarks.export(root)
        #expect(html.hasPrefix("<!DOCTYPE NETSCAPE-Bookmark-file-1>\n"))
        #expect(html.contains("<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">"))
        #expect(html.contains("<TITLE>Bookmarks</TITLE>"))
        #expect(html.contains("<H1>Bookmarks</H1>"))
        #expect(html.contains("<DT><H3>R&amp;D &lt;new&gt;</H3>"))
        #expect(html.contains("<DT><A HREF=\"https://q.example/s?a=1&amp;b=2\">Q</A>"))
        #expect(html.contains("<DT><A HREF=\"https://e.example/\">Tom &amp; &quot;Jerry&quot; &lt;3&gt;</A>"))
        #expect(html.components(separatedBy: "<DL><p>").count == 3)
        #expect(html.components(separatedBy: "</DL><p>").count == 3)
        #expect(!html.contains("Bookmarks</H3>"))
    }

    @Test func importsAChromeExport() throws {
        let parsed = try NetscapeBookmarks.parse(Self.chrome, title: "Chrome")
        #expect(
            outline(parsed.children) == [
                "Bookmarks bar [News <https://news.example/>, Work [Wiki <https://wiki.example/start?a=1&b=2>], "
                    + "Mail <https://mail.example/>]",
                "Other bookmarks [Docs <https://docs.example/>]",
            ])
    }

    @Test func importsAFirefoxExport() throws {
        let parsed = try NetscapeBookmarks.parse(Self.firefox, title: "Firefox")
        #expect(
            outline(parsed.children) == [
                "Mozilla Firefox [Get Help <https://support.mozilla.org/products/firefox>, "
                    + "About Us <https://www.mozilla.org/about/>]",
                "Bookmarks Toolbar [Blog post <https://blog.example/post>, "
                    + "untitled.example <https://untitled.example/page>]",
                "Other Bookmarks []",
            ])
    }

    @Test func importsASafariExport() throws {
        let parsed = try NetscapeBookmarks.parse(Self.safari, title: "Safari")
        #expect(
            outline(parsed.children) == [
                "Favorites [Apple <https://www.apple.com/>, Dev [Apple Developer <https://developer.apple.com/>]]",
                "Bookmarks Menu []",
                "Reading List [Read later <http://read.example/later>]",
            ])
    }

    @Test func skipsLinksThatAreNotHTTP() throws {
        let html = """
            <DL><p>
                <DT><A HREF="javascript:void(0)">JS</A>
                <DT><A HREF="place:sort=8">Place</A>
                <DT><A HREF="data:text/plain,x">Data</A>
                <DT><A HREF="file:///etc/hosts">File</A>
                <DT><A HREF="HTTPS://kept.example/">Kept</A>
            </DL><p>
            """
        #expect(outline(try NetscapeBookmarks.parse(html, title: "T").children) == ["Kept <HTTPS://kept.example/>"])
    }

    @Test func anEmptyLinkTitleFallsBackToTheHost() throws {
        let html = #"<DL><p><DT><A HREF="https://host.example/a/b">  </A></DL><p>"#
        #expect(
            outline(try NetscapeBookmarks.parse(html, title: "T").children) == ["host.example <https://host.example/a/b>"])
    }

    @Test func inputWithoutAListIsNotABookmarkFile() {
        #expect(throws: NetscapeBookmarks.ImportError.notABookmarkFile) {
            try NetscapeBookmarks.parse("<html><body><a href=\"https://a.example\">A</a></body></html>", title: "T")
        }
        #expect(throws: NetscapeBookmarks.ImportError.notABookmarkFile) {
            try NetscapeBookmarks.parse("", title: "T")
        }
    }

    /// `URL` percent-encodes a quote, so one in an imported HREF must come back out without ending the attribute.
    @Test func aQuoteInsideAnHREFKeepsTheAttributeIntact() throws {
        let imported = try NetscapeBookmarks.parse(
            #"<DL><p><DT><A HREF="https://q.example/s?a=&quot;y&quot;&amp;b=1">Q</A></DL><p>"#, title: "T")
        let url = try #require(imported.links.first?.url)
        #expect(url.query() == "a=%22y%22&b=1")
        let html = NetscapeBookmarks.export(imported)
        #expect(html.contains(#"<DT><A HREF="https://q.example/s?a=%22y%22&amp;b=1">Q</A>"#))
        #expect(try NetscapeBookmarks.parse(html, title: "T").links.map(\.url) == [url])
    }

    @Test func aListInsideALinkEntryIsKept() throws {
        let html = """
            <DL><p>
                <DT><A HREF="https://outer.example/">Outer <b>bold</b></A>
                <DL><p>
                    <DT><A HREF="https://inner.example/">Inner</A>
                    <DT><H3>Folder</H3>
                    <DL><p><DT><A HREF="https://deep.example/">Deep</A></DL><p>
                </DL><p>
                <DT><A HREF="https://after.example/">After</A>
            </DL><p>
            """
        #expect(
            outline(try NetscapeBookmarks.parse(html, title: "T").children) == [
                "Outer bold <https://outer.example/>", "Inner <https://inner.example/>",
                "Folder [Deep <https://deep.example/>]", "After <https://after.example/>",
            ])
    }

    @Test func deepNestingIsCappedWithoutOverflowingASmallStack() async throws {
        let levels = 1000
        let html =
            (0..<levels).map { #"<DL><p><DT><A HREF="https://l\#($0).example/">L\#($0)</A><DT><H3>F\#($0)</H3>"# }
            .joined() + #"<DL><p><DT><A HREF="https://deepest.example/">Deepest</A></DL><p>"#
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<BookmarkFolder?, Never>) in
            let thread = Thread {
                continuation.resume(returning: try? NetscapeBookmarks.parse(html, title: "Deep"))
            }
            thread.stackSize = 512 * 1024
            thread.start()
        }
        let parsed = try #require(result)
        #expect(depth(parsed) == NetscapeBookmarks.maxDepth)
        #expect(parsed.links.map(\.title) == (0..<levels).map { "L\($0)" } + ["Deepest"])

        var deepest = parsed
        while case .folder(let child)? = deepest.children.last { deepest = child }
        #expect(deepest.title == "F\(NetscapeBookmarks.maxDepth - 1)")
        #expect(
            deepest.children.map(\.id) == deepest.links.map(\.id)
                && deepest.links.map(\.title) == (NetscapeBookmarks.maxDepth..<levels).map { "L\($0)" } + ["Deepest"])
    }

    @Test func fiveThousandBookmarksParseAndExportQuickly() throws {
        var serial = 0
        func level(_ depth: Int) -> [BookmarkNode] {
            var nodes: [BookmarkNode] = []
            for _ in 0..<(depth == 3 ? 40 : 4) {
                serial += 1
                nodes.append(link("Page \(serial)", "https://site\(serial).example/path?n=\(serial)&q=x"))
            }
            if depth < 3 {
                for index in 0..<5 {
                    nodes.append(.folder(BookmarkFolder(title: "Folder \(depth).\(index)", children: level(depth + 1))))
                }
            }
            return nodes
        }
        let root = BookmarkFolder(title: "Bookmarks", children: level(0))
        #expect(root.links.count > 5000)

        let clock = ContinuousClock()
        var html = ""
        let exportTime = clock.measure { html = NetscapeBookmarks.export(root) }
        var parsed = BookmarkFolder(title: "")
        let parseTime = try clock.measure { parsed = try NetscapeBookmarks.parse(html, title: "Big") }

        #expect(parsed.links.count == root.links.count)
        #expect(outline(parsed.children) == outline(root.children))
        // A canary against quadratic blow-up, not a benchmark: loose enough for a loaded machine.
        #expect(exportTime < .seconds(10))
        #expect(parseTime < .seconds(10))
    }

    /// `count` links in one flat list.
    private func flatFile(links count: Int) -> String {
        "<DL><p>\n" + (0..<count).map { #"<DT><A HREF="https://s\#($0).example/">P\#($0)</A>"# }
            .joined(separator: "\n") + "\n</DL><p>\n"
    }

    @Test func tooManyElementsAreRefused() {
        #expect(NetscapeBookmarks.maxElements == 250_000)
        let html = "<DL><p>" + String(repeating: "<", count: NetscapeBookmarks.maxElements - 2)
        #expect(throws: Never.self) { try NetscapeBookmarks.checkComplexity(html) }
        #expect(throws: NetscapeBookmarks.ImportError.tooComplex) { try NetscapeBookmarks.parse(html + "<", title: "T") }
    }

    @Test func moreThanTheBookmarkLimitIsRefused() {
        #expect(throws: NetscapeBookmarks.ImportError.tooManyBookmarks(limit: NetscapeBookmarks.maxBookmarks)) {
            try NetscapeBookmarks.parse(flatFile(links: NetscapeBookmarks.maxBookmarks + 1), title: "T")
        }
    }

    @Test func aCancelledImportStops() async {
        let html = flatFile(links: 5000)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try NetscapeBookmarks.parse(html, title: "T")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
