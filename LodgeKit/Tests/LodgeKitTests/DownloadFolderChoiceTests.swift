import Foundation
import Testing

@testable import LodgeKit

@Suite struct DownloadFolderChoiceTests {
    private let custom = URL(filePath: "/Volumes/Disk/Saved Files", directoryHint: .isDirectory)
    private let bookmark = Data([7, 7, 7])

    @Test func noBookmarkSelectsDownloads() {
        let choice = DownloadFolderChoice(DownloadSettings(), resolution: nil)
        #expect(choice == DownloadFolderChoice(selection: .downloads, showsUnavailableNote: false))
    }

    @Test func aResolvedBookmarkSelectsTheFolderByName() {
        let choice = DownloadFolderChoice(
            DownloadSettings(folderBookmark: bookmark), resolution: .folder(custom, refreshed: nil))
        #expect(choice == DownloadFolderChoice(selection: .custom(name: "Saved Files"), showsUnavailableNote: false))
    }

    @Test func anUnresolvedBookmarkSelectsItAsUnavailableWithANote() {
        let choice = DownloadFolderChoice(
            DownloadSettings(folderBookmark: bookmark), resolution: .unavailable(name: "Saved Files"))
        #expect(
            choice == DownloadFolderChoice(selection: .unavailable(name: "Saved Files"), showsUnavailableNote: true))
    }

    @Test func askingEachTimeHidesTheNote() {
        let choice = DownloadFolderChoice(
            DownloadSettings(folderBookmark: bookmark, askEachTime: true), resolution: .unavailable(name: nil))
        #expect(choice == DownloadFolderChoice(selection: .unavailable(name: nil), showsUnavailableNote: false))
    }

    @Test func aResolutionWithoutABookmarkIsIgnored() {
        let choice = DownloadFolderChoice(DownloadSettings(), resolution: .folder(custom, refreshed: nil))
        #expect(choice == DownloadFolderChoice(selection: .downloads, showsUnavailableNote: false))
    }

    @Test func titlesNameTheFolderAndMarkAnUnavailableOne() {
        #expect(DownloadFolderChoice.Selection.downloads.title == "Downloads")
        #expect(DownloadFolderChoice.Selection.custom(name: "Saved").title == "Saved")
        #expect(DownloadFolderChoice.Selection.unavailable(name: "Saved").title == "Saved (unavailable)")
        #expect(DownloadFolderChoice.Selection.unavailable(name: nil).title == "Chosen folder (unavailable)")
    }
}
