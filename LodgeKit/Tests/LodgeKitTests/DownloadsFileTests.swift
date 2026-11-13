import Foundation
import Testing

@testable import LodgeKit

/// Each test works in its own fresh temporary folder, never the app's real downloads.
@Suite struct DownloadsFileTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "DownloadsFileTests-\(UUID())")
    private var file: DownloadsFile { DownloadsFile(directory: root) }

    private let list: DownloadList = {
        let start = Date(timeIntervalSince1970: 1_000)
        let states: [DownloadItem.State] = [
            .waitingForLocation, .running, .finished, .failed(reason: "Network lost"), .cancelled, .interrupted,
        ]
        return DownloadList(
            items: states.map { state in
                DownloadItem(
                    sourceURL: URL(string: "https://a.example/f.zip"), method: "GET", fileName: "f.zip",
                    directory: URL(filePath: "/tmp/d", directoryHint: .isDirectory),
                    fileURL: state == .finished ? URL(filePath: "/tmp/d/f.zip") : nil,
                    bookmark: state == .finished ? Data([1, 2, 3]) : nil, state: state, receivedBytes: 42,
                    totalBytes: state == .running ? nil : 100, startedAt: start,
                    endedAt: state.isActive ? nil : start.addingTimeInterval(5))
            })
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

    @Test func writeCreatesTheFolderAndLoadRoundTripsEveryState() throws {
        defer { cleanUp() }
        #expect(!exists(root))
        try file.write(list)
        #expect(exists(file.url))
        #expect(file.load().list == list)
    }

    @Test func loadSanitizesNamesAndDropsSourcesThatAreNotWeb() throws {
        defer { cleanUp() }
        let start = Date(timeIntervalSince1970: 1_000)
        try file.write(
            DownloadList(items: [
                DownloadItem(
                    sourceURL: URL(string: "file:///etc/passwd"), fileName: "../../x.zip", state: .failed(reason: "x"),
                    startedAt: start),
                DownloadItem(
                    sourceURL: URL(string: "HTTPS://a.example/f.zip"), fileName: "f.zip", state: .cancelled,
                    startedAt: start),
            ]))
        let items = try #require(file.load().list).items
        #expect(items[0].fileName == "x.zip")
        #expect(items[0].sourceURL == nil)
        #expect(!items[0].canRetry)
        #expect(items[1].sourceURL == URL(string: "HTTPS://a.example/f.zip"))
        #expect(items[1].canRetry)
    }

    @Test func loadKeepsAStoredNameThatIsOneSafeComponentSoCleanupFindsItsPartial() throws {
        defer { cleanUp() }
        let folder = root.appending(path: "Downloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appending(path: "a  b.zip.lodgedownload")
        try put("x", at: partial)
        try file.write(
            DownloadList(items: [
                DownloadItem(
                    sourceURL: nil, fileName: "a  b.zip", directory: folder, state: .interrupted,
                    startedAt: Date(timeIntervalSince1970: 1_000)),
                DownloadItem(
                    sourceURL: nil, fileName: "a\nb.zip", directory: folder, state: .interrupted,
                    startedAt: Date(timeIntervalSince1970: 1_000)),
            ]))
        let items = try #require(file.load().list).items
        #expect(items.map(\.fileName) == ["a  b.zip", "a_b.zip"])
        DownloadFiles(stagingFolder: root.appending(path: "Staging"))
            .cleanUp(items, createdBefore: Date().addingTimeInterval(60), downloadsFolder: folder)
        #expect(!exists(partial))
    }

    @Test func writesVersionOne() throws {
        defer { cleanUp() }
        try file.write(list)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [String: Any]
        #expect(json?["version"] as? Int == 1)
    }

    @Test func corruptFileIsSetAside() throws {
        defer { cleanUp() }
        try put("{ not json", at: file.url)
        let outcome = file.load()
        guard case .setAside(_, let moveFailure) = outcome else { Issue.record("expected .setAside"); return }
        #expect(moveFailure == nil)
        #expect(outcome.list == nil)
        #expect(!exists(file.url))
        #expect(try String(contentsOf: file.badURL, encoding: .utf8) == "{ not json")
    }

    @Test func newerVersionIsSetAside() throws {
        defer { cleanUp() }
        try file.write(DownloadsFile.Contents(version: DownloadsFile.currentVersion + 1, items: list.items))
        let outcome = file.load()
        guard case .setAside(let reason, nil) = outcome else { Issue.record("expected .setAside"); return }
        #expect(reason as? DownloadsFile.DecodeError == .unsupportedVersion(DownloadsFile.currentVersion + 1))
        #expect(!exists(file.url))
        #expect(exists(file.badURL))
    }

    @Test func replacesAnOlderBadFile() throws {
        defer { cleanUp() }
        try put("old bad", at: file.badURL)
        try put("new bad", at: file.url)
        #expect(file.load().list == nil)
        #expect(!exists(file.url))
        #expect(try String(contentsOf: file.badURL, encoding: .utf8) == "new bad")
    }
}
