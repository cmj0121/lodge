import Foundation
import Testing

@testable import LodgeKit

/// Each test that reads a file works in its own fresh temporary folder.
@Suite struct BookmarkFileTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "BookmarkFileTests-\(UUID())")

    private func put(_ data: Data, named name: String) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: name)
        try data.write(to: url)
        return url
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: root) }

    private func html(charset: String, title: String) -> String {
        """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=\(charset)">
        <DL><p>
            <DT><A HREF="https://a.example/">\(title)</A>
        </DL><p>
        """
    }

    @Test(arguments: [
        ("Chrome Bookmarks.html", "Chrome Bookmarks"), ("bookmarks.htm", "bookmarks"), ("   .html", "Imported"),
    ])
    func importTitleIsTheFileNameWithoutExtension(name: String, title: String) {
        #expect(BookmarkFile.importTitle(for: URL(filePath: "/tmp/\(name)")) == title)
    }

    @Test func utf8TextIsReadAsUTF8() {
        let text = html(charset: "Shift_JIS", title: "日本語 café")
        #expect(BookmarkFile.text(of: Data(text.utf8)) == text)
    }

    @Test func nonUTF8TextFollowsTheDeclaredCharset() throws {
        let text = html(charset: "Shift_JIS", title: "日本語")
        let data = try #require(text.data(using: .shiftJIS))
        #expect(BookmarkFile.text(of: data) == text)
    }

    @Test func htmlFiveMetaCharsetIsFound() {
        #expect(BookmarkFile.declaredEncoding(in: Data("<meta charset='iso-8859-2'>".utf8)) == .isoLatin2)
    }

    @Test func undeclaredOrUnknownCharsetFallsBackToWindows1252() throws {
        for charset in ["", "x-no-such-charset"] {
            let text = html(charset: charset, title: "Café – “quoted”")
            let data = try #require(text.data(using: .windowsCP1252))
            #expect(BookmarkFile.declaredEncoding(in: data) == nil)
            #expect(BookmarkFile.text(of: data) == text)
        }
    }

    @Test func readParsesTheFileIntoAFolderNamedAfterIt() throws {
        defer { cleanUp() }
        let url = try put(Data(html(charset: "UTF-8", title: "A").utf8), named: "Work.html")
        let folder = try BookmarkFile.read(url)
        #expect(folder.title == "Work")
        #expect(folder.children.count == 1)
    }

    @Test func readRefusesAFileAboveTheSizeCap() throws {
        defer { cleanUp() }
        let url = try put(Data(html(charset: "UTF-8", title: "A").utf8), named: "Big.html")
        #expect(throws: BookmarkFile.ReadError.tooLarge) { try BookmarkFile.read(url, maxSize: 10) }
    }

    @Test func readTakesAFileOfExactlyTheSizeCap() throws {
        defer { cleanUp() }
        let data = Data(html(charset: "UTF-8", title: "A").utf8)
        let url = try put(data, named: "Exact.html")
        #expect(try BookmarkFile.read(url, maxSize: data.count).children.count == 1)
        #expect(throws: BookmarkFile.ReadError.tooLarge) { try BookmarkFile.read(url, maxSize: data.count - 1) }
    }

    @Test func readOfAFolderIsUnreadable() throws {
        defer { cleanUp() }
        let folder = root.appending(path: "Folder.html")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(throws: BookmarkFile.ReadError.unreadable) { try BookmarkFile.read(folder) }
    }

    @Test(arguments: ["UTF-16", "utf-16le", "UTF-16BE", "utf-32"])
    func declaredWideCharsetIsIgnored(charset: String) throws {
        let text = html(charset: charset, title: "Café – “quoted”")
        let data = try #require(text.data(using: .windowsCP1252))
        #expect(BookmarkFile.declaredEncoding(in: data) == nil)
        #expect(BookmarkFile.text(of: data) == text)
    }

    @Test func readOfAMissingFileIsUnreadable() {
        #expect(throws: BookmarkFile.ReadError.unreadable) { try BookmarkFile.read(root.appending(path: "none.html")) }
    }

    @Test func readOfAFileWithoutAListIsNotABookmarkFile() throws {
        defer { cleanUp() }
        let url = try put(Data("<html><body>Hello</body></html>".utf8), named: "Page.html")
        #expect(throws: NetscapeBookmarks.ImportError.notABookmarkFile) { try BookmarkFile.read(url) }
    }

    @Test func maxSizeIsAboutFiveMegabytes() {
        #expect(BookmarkFile.maxSize == 5 * 1024 * 1024)
    }
}
