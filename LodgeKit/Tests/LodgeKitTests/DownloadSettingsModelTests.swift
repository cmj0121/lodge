import Foundation
import Synchronization
import Testing

@testable import LodgeKit

@MainActor @Suite struct DownloadSettingsModelTests {
    private let saved = URL(filePath: "/Volumes/Disk/Saved", directoryHint: .isDirectory)
    private let other = URL(filePath: "/Volumes/Disk/Other", directoryHint: .isDirectory)

    /// A model over a throwaway defaults suite, removed when `body` returns.
    private func withModel(
        _ fake: FakeBookmarks, stored: Data? = nil,
        _ body: @MainActor (DownloadSettingsModel, CountingDefaults) async throws -> Void
    ) async rethrows {
        let suite = "dev.lodge.tests.\(UUID().uuidString)"
        let defaults = CountingDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(stored, forKey: DownloadSettings.folderKey)
        defaults.resetCount()
        let model = DownloadSettingsModel(defaults: defaults, bookmarks: fake.bookmarks)
        await model.refresh()
        try await body(model, defaults)
    }

    @Test func aStoredFolderShowsByItsRecordedNameBeforeTheFirstResolve() async {
        let suite = "dev.lodge.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(FakeBookmarks.data(saved), forKey: DownloadSettings.folderKey)
        let fake = FakeBookmarks()
        let model = DownloadSettingsModel(defaults: defaults, bookmarks: fake.bookmarks)
        #expect(model.selection == .custom(name: "Saved"))
        #expect(!model.isResolved)
        #expect(fake.resolveCount == 0)
        await model.refresh()
        #expect(model.isResolved)
    }

    @Test func noStoredFolderStartsOnDownloads() {
        let suite = "dev.lodge.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DownloadSettingsModel(defaults: defaults, bookmarks: FakeBookmarks().bookmarks)
        #expect(model.selection == .downloads)
        #expect(!model.isResolved)
    }

    @Test func cancellingThePanelKeepsTheStoredFolder() async {
        let fake = FakeBookmarks()
        await withModel(fake, stored: FakeBookmarks.data(saved)) { model, defaults in
            await model.useFolder(nil)
            #expect(model.selection == .custom(name: "Saved"))
            #expect(defaults.data(forKey: DownloadSettings.folderKey) == FakeBookmarks.data(saved))
            #expect(defaults.folderWrites == 0)
        }
    }

    @Test func cancellingWithNoFolderStaysOnDownloads() async {
        await withModel(FakeBookmarks()) { model, defaults in
            await model.useFolder(nil)
            #expect(model.selection == .downloads)
            #expect(defaults.data(forKey: DownloadSettings.folderKey) == nil)
        }
    }

    @Test func choosingTheSameFolderLeavesTheBookmarkAlone() async {
        let fake = FakeBookmarks()
        await withModel(fake, stored: FakeBookmarks.data(saved)) { model, defaults in
            await model.useFolder(saved)
            #expect(model.selection == .custom(name: "Saved"))
            #expect(defaults.folderWrites == 0)
        }
    }

    @Test func choosingANewFolderStoresItsBookmark() async {
        await withModel(FakeBookmarks(), stored: FakeBookmarks.data(saved)) { model, defaults in
            await model.useFolder(other)
            #expect(model.selection == .custom(name: "Other"))
            #expect(model.folder == other)
            #expect(defaults.data(forKey: DownloadSettings.folderKey) == FakeBookmarks.data(other))
        }
    }

    @Test func aFolderThatCannotBeBookmarkedKeepsTheStoredOne() async {
        let fake = FakeBookmarks(failMaking: true)
        await withModel(fake, stored: FakeBookmarks.data(saved)) { model, defaults in
            await model.useFolder(other)
            #expect(model.selection == .custom(name: "Saved"))
            #expect(defaults.data(forKey: DownloadSettings.folderKey) == FakeBookmarks.data(saved))
        }
    }

    @Test func choosingDownloadsWhileUnavailableClearsTheBookmarkAndNote() async {
        let gone = Data([9])
        await withModel(FakeBookmarks(unavailable: [gone: "Gone"]), stored: gone) { model, defaults in
            #expect(model.selection == .unavailable(name: "Gone"))
            #expect(model.showsUnavailableNote)
            model.useDownloads()
            #expect(model.selection == .downloads)
            #expect(!model.showsUnavailableNote)
            #expect(defaults.data(forKey: DownloadSettings.folderKey) == nil)
        }
    }

    @Test func aStaleBookmarkIsRefreshedExactlyOnce() async {
        let stale = Data([5])
        let fake = FakeBookmarks(stale: [stale: saved])
        await withModel(fake, stored: stale) { model, defaults in
            #expect(model.selection == .custom(name: "Saved"))
            #expect(defaults.data(forKey: DownloadSettings.folderKey) == FakeBookmarks.data(saved))
            #expect(defaults.folderWrites == 1)
            #expect(fake.resolveCount == 1)
            await model.refresh()
            #expect(defaults.folderWrites == 1)
            #expect(fake.resolveCount == 2)
        }
    }

    @Test func aRefreshThatReturnsTheSameDataWritesNothing() async {
        let same = FakeBookmarks.data(saved)
        let fake = FakeBookmarks(stale: [same: saved])
        await withModel(fake, stored: same) { model, defaults in
            await model.refresh()
            #expect(model.selection == .custom(name: "Saved"))
            #expect(defaults.folderWrites == 0)
        }
    }

    @Test func theAskToggleIsStoredAndHidesTheNote() async {
        let gone = Data([9])
        await withModel(FakeBookmarks(unavailable: [gone: nil]), stored: gone) { model, defaults in
            #expect(!model.askEachTime)
            model.askEachTime = true
            #expect(defaults.bool(forKey: DownloadSettings.askKey))
            #expect(!model.showsUnavailableNote)
            #expect(model.selection == .unavailable(name: nil))
            model.askEachTime = false
            #expect(!defaults.bool(forKey: DownloadSettings.askKey))
            #expect(model.showsUnavailableNote)
        }
    }
}

/// Bookmarks are a folder's path bytes; `stale` ones resolve with a fresh bookmark, `unavailable` ones do not resolve.
private final class FakeBookmarks: Sendable {
    private struct CannotBookmark: Error {}
    private let resolves = Mutex(0)
    private let stale: [Data: URL]
    private let unavailable: [Data: String?]
    private let failMaking: Bool

    init(stale: [Data: URL] = [:], unavailable: [Data: String?] = [:], failMaking: Bool = false) {
        self.stale = stale
        self.unavailable = unavailable
        self.failMaking = failMaking
    }

    static func data(_ folder: URL) -> Data { Data(folder.path(percentEncoded: false).utf8) }

    var resolveCount: Int { resolves.withLock { $0 } }

    var bookmarks: FolderBookmarks {
        FolderBookmarks(
            make: { [failMaking] folder in
                if failMaking { throw CannotBookmark() }
                return Self.data(folder)
            },
            resolve: { [self] bookmark in
                resolves.withLock { $0 += 1 }
                if let folder = stale[bookmark] { return .folder(folder, refreshed: Self.data(folder)) }
                if let name = unavailable[bookmark] { return .unavailable(name: name) }
                let path = String(decoding: bookmark, as: UTF8.self)
                return .folder(URL(filePath: path, directoryHint: .isDirectory), refreshed: nil)
            },
            name: { bookmark in String(decoding: bookmark, as: UTF8.self).split(separator: "/").last.map(String.init) })
    }
}

/// Counts writes of the folder bookmark, whether or not they change it.
private final class CountingDefaults: UserDefaults, @unchecked Sendable {
    private let writes = Mutex(0)

    var folderWrites: Int { writes.withLock { $0 } }

    func resetCount() { writes.withLock { $0 = 0 } }

    override func set(_ value: Any?, forKey key: String) {
        if key == DownloadSettings.folderKey { writes.withLock { $0 += 1 } }
        super.set(value, forKey: key)
    }

    override func removeObject(forKey key: String) {
        if key == DownloadSettings.folderKey { writes.withLock { $0 += 1 } }
        super.removeObject(forKey: key)
    }
}
