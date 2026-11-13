import Foundation
import Testing

@testable import LodgeKit

@Suite struct DownloadDestinationTests {
    private let downloads = URL(filePath: "/Users/u/Downloads", directoryHint: .isDirectory)
    private let custom = URL(filePath: "/Volumes/Disk/Saved", directoryHint: .isDirectory)
    private let bookmark = Data([7, 7, 7])

    private func resolve(_ settings: DownloadSettings) -> DownloadDestination {
        DownloadDestination.resolve(settings, downloadsFolder: downloads) { [bookmark, custom] data in
            data == bookmark ? custom : nil
        }
    }

    @Test func defaultsToTheDownloadsFolderUnscoped() {
        #expect(resolve(DownloadSettings()) == .folder(downloads, scoped: false))
    }

    @Test func aResolvableBookmarkGivesTheCustomFolderScoped() {
        #expect(resolve(DownloadSettings(folderBookmark: bookmark)) == .folder(custom, scoped: true))
    }

    @Test func anUnresolvableBookmarkFallsBackToDownloads() {
        #expect(resolve(DownloadSettings(folderBookmark: Data([0]))) == .fallback(downloads))
    }

    @Test func askEachTimeWinsOverAnyFolder() {
        #expect(resolve(DownloadSettings(askEachTime: true)) == .ask)
        #expect(resolve(DownloadSettings(folderBookmark: bookmark, askEachTime: true)) == .ask)
    }
}
