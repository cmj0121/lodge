import Foundation
import Testing

@testable import LodgeKit

/// Each test works in its own fresh temporary folder, never the app's real session.
@Suite struct SessionFileTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "SessionFileTests-\(UUID())")
    private var file: SessionFile { SessionFile(directory: root) }

    private let snapshot: SessionSnapshot = {
        let tab = BrowserTab(url: URL(string: "https://a.example")!, title: "A")
        return SessionSnapshot(
            tabs: TabList(tabs: [tab, BrowserTab()], selectedID: tab.id),
            library: LinkLibrary(pins: [SavedLink(url: URL(string: "https://p.example")!, title: "P")]))
    }()

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    private func put(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: root) }

    @Test func missingFileLoadsNothing() {
        defer { cleanUp() }
        guard case .missing = file.load() else { Issue.record("expected .missing"); return }
    }

    @Test func writeCreatesTheFolderAndLoadRoundTrips() throws {
        defer { cleanUp() }
        #expect(!exists(root))
        try file.write(snapshot)
        #expect(exists(file.url))
        #expect(file.load().snapshot == snapshot)
    }

    @Test func corruptFileIsSetAside() throws {
        defer { cleanUp() }
        try put("{ not json", at: file.url)
        let outcome = file.load()
        guard case .setAside(_, let moveFailure) = outcome else { Issue.record("expected .setAside"); return }
        #expect(moveFailure == nil)
        #expect(outcome.snapshot == nil)
        #expect(!exists(file.url))
        #expect(try String(contentsOf: file.badURL, encoding: .utf8) == "{ not json")
    }

    @Test func newerVersionIsSetAside() throws {
        defer { cleanUp() }
        var newer = snapshot
        newer.version = SessionSnapshot.currentVersion + 1
        try file.write(newer)
        let outcome = file.load()
        guard case .setAside(let reason, nil) = outcome else { Issue.record("expected .setAside"); return }
        #expect(reason as? SessionSnapshot.DecodeError == .unsupportedVersion(SessionSnapshot.currentVersion + 1))
        #expect(!exists(file.url))
        #expect(exists(file.badURL))
    }

    @Test func replacesAnOlderBadFile() throws {
        defer { cleanUp() }
        try put("old bad", at: file.badURL)
        try put("new bad", at: file.url)
        #expect(file.load().snapshot == nil)
        #expect(!exists(file.url))
        #expect(try String(contentsOf: file.badURL, encoding: .utf8) == "new bad")
    }
}
