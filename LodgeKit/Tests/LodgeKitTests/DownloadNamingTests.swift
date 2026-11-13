import Foundation
import Testing

@testable import LodgeKit

@Suite struct DownloadNamingTests {
    private let folder = URL(filePath: "/tmp/DownloadNamingTests", directoryHint: .isDirectory)

    private func unique(_ name: String, taken: Set<String> = [], reserved: Set<String> = []) -> String {
        DownloadNaming.unique(name, in: folder, reserved: reserved) { url in
            url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL
                && taken.contains(url.lastPathComponent)
        }
    }

    @Test(arguments: [
        ("report.pdf", "report.pdf"),
        ("a/b/c.zip", "c.zip"),
        ("../../etc/passwd", "passwd"),
        ("..", "download"),
        (".", "download"),
        ("", "download"),
        ("dir/", "download"),
        ("a:b\\c.txt", "a_b_c.txt"),
        ("tab\there\nnew\u{7F}.txt", "tab_here_new_.txt"),
        ("  ..hidden.txt.. ", "hidden.txt"),
        ("...", "download"),
        ("報告書 2026.pdf", "報告書 2026.pdf"),
        ("name.txt\u{00A0}", "name.txt"),
        ("\u{3000}名前.txt\u{3000}", "名前.txt"),
        (" \u{00A0}.\u{3000}", "download"),
        ("invoice  \u{00A0}\u{3000}.pdf", "invoice .pdf"),
        ("a\u{2028}\u{2029}b.txt", "a b.txt"),
        ("photo.jpg\u{2028}.app", "photo.jpg .app"),
    ])
    func sanitize(_ suggested: String, _ expected: String) {
        #expect(DownloadNaming.sanitize(suggested) == expected)
    }

    @Test func sanitizeCapsAt200BytesKeepingTheExtension() {
        let name = DownloadNaming.sanitize(String(repeating: "a", count: 300) + ".tar")
        #expect(name.utf8.count == 200)
        #expect(name.hasSuffix("a.tar"))
    }

    @Test func sanitizeCapsCJKOnWholeCharacters() {
        let name = DownloadNaming.sanitize(String(repeating: "檔", count: 100) + ".zip")
        #expect(name.utf8.count <= 200)
        #expect(name.utf8.count > 190)
        #expect(name.hasSuffix("檔.zip"))
        #expect(name.dropLast(4).allSatisfy { $0 == "檔" })
    }

    @Test func sanitizeCutsAnExtensionTooLongToKeep() {
        let name = DownloadNaming.sanitize("a." + String(repeating: "x", count: 300))
        #expect(name.utf8.count == 200)
        #expect(name.hasPrefix("a.x"))
    }

    @Test func sanitizeReplacesFormatChars() {
        let name = DownloadNaming.sanitize("invoice\u{202E}fdp.app")
        #expect(!name.unicodeScalars.contains("\u{202E}"))
        #expect(name == "invoice_fdp.app")
        for scalar in ["\u{202A}", "\u{202D}", "\u{2066}", "\u{2069}", "\u{200B}", "\u{200D}", "\u{FEFF}"] {
            #expect(DownloadNaming.sanitize("a\(scalar)b") == "a_b", "\(scalar.unicodeScalars.first!.value)")
        }
    }

    @Test func sanitizeCutsAnOversizedCharacterByScalars() {
        let huge = "e" + String(repeating: "\u{0301}", count: 300)
        #expect(huge.count == 1)
        let bare = DownloadNaming.sanitize(huge)
        #expect(!bare.isEmpty)
        #expect(bare.utf8.count <= 200)
        #expect(bare.unicodeScalars.first == "e")
        let withExtension = DownloadNaming.sanitize(huge + ".txt")
        #expect(withExtension.utf8.count <= 200)
        #expect(withExtension.unicodeScalars.first == "e")
        #expect(withExtension.hasSuffix(".txt"))
    }

    @Test(arguments: ["", ".", "..", "...", " . ", "/", "\u{0}", "\u{202E}", ". .", "\u{3000}.\u{00A0}"])
    func sanitizeNeverReturnsAnEmptyOrDotName(_ suggested: String) {
        let name = DownloadNaming.sanitize(suggested)
        #expect(!name.isEmpty && name != "." && name != "..")
    }

    @Test func uniqueKeepsAFreeName() {
        #expect(unique("a.zip") == "a.zip")
    }

    @Test func uniqueNumbersBeforeTheExtension() {
        #expect(unique("a.zip", taken: ["a.zip"]) == "a (1).zip")
        #expect(unique("a.zip", taken: ["a.zip", "a (1).zip"]) == "a (2).zip")
        #expect(unique("a.tar.gz", taken: ["a.tar.gz"]) == "a.tar (1).gz")
    }

    @Test func uniqueWithoutAnExtension() {
        #expect(unique("README", taken: ["README"]) == "README (1)")
    }

    @Test func uniqueTreatsADotfileAsHavingNoExtension() {
        #expect(unique(".env", taken: [".env"]) == ".env (1)")
    }

    @Test func uniqueSkipsReservedNames() {
        #expect(unique("a.zip", reserved: ["a.zip"]) == "a (1).zip")
        #expect(unique("a.zip", taken: ["a.zip"], reserved: ["a (1).zip"]) == "a (2).zip")
        #expect(unique("a.zip", reserved: ["a.zip.lodgedownload"]) == "a (1).zip")
    }

    @Test func uniqueComparesReservedNamesIgnoringCase() {
        #expect(unique("a.zip", reserved: ["A.zip"]) == "a (1).zip")
        #expect(unique("a.zip", reserved: ["A.ZIP.LODGEDOWNLOAD"]) == "a (1).zip")
    }

    @Test(arguments: ["a.zip", "a  b.zip", "..a", ".env"])
    func oneSafeComponentIsKept(_ name: String) {
        #expect(DownloadNaming.isSafeComponent(name))
    }

    @Test(arguments: ["", ".", "..", "../a", "a/b", "a\nb", "a\u{7F}", "a:b", "a\\b", "a\u{202E}b", "a\u{200B}b"])
    func anythingElseIsNotASafeComponent(_ name: String) {
        #expect(!DownloadNaming.isSafeComponent(name))
    }

    @Test func uniqueGivesUpCountingAfter999() {
        let name = DownloadNaming.unique("a.zip", in: folder, reserved: []) { url in
            url.lastPathComponent.hasPrefix("a (") || url.lastPathComponent.hasPrefix("a.zip")
        }
        #expect(name.wholeMatch(of: /a [0-9a-f]{8}\.zip/) != nil, "\(name)")
        let last = DownloadNaming.unique("a.zip", in: folder, reserved: []) { url in
            url.lastPathComponent != "a (\(DownloadNaming.maxNumbered)).zip"
                && url.lastPathComponent != "a (\(DownloadNaming.maxNumbered)).zip.lodgedownload"
        }
        #expect(last == "a (999).zip")
    }

    @Test func uniqueCountsADanglingLinkAsTaken() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "DownloadNamingTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "a.zip"), withDestinationURL: root.appending(path: "nowhere"))
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "a (1).zip.lodgedownload"), withDestinationURL: root.appending(path: "nowhere"))
        #expect(DownloadNaming.unique("a.zip", in: root, reserved: []) == "a (2).zip")
    }

    @Test func uniqueSkipsNamesWithAPartialOnDisk() {
        #expect(unique("a.zip", taken: ["a.zip.lodgedownload"]) == "a (1).zip")
        #expect(unique("a.zip", taken: ["a.zip", "a (1).zip.lodgedownload"]) == "a (2).zip")
    }

    @Test func partialURLAppendsTheSuffix() {
        let final = folder.appending(path: "a b.zip")
        let partial = DownloadNaming.partialURL(for: final)
        #expect(partial.lastPathComponent == "a b.zip.lodgedownload")
        #expect(partial.deletingLastPathComponent() == final.deletingLastPathComponent())
        #expect(DownloadNaming.partialURL(for: folder.appending(path: "README")).lastPathComponent
            == "README.lodgedownload")
    }
}
