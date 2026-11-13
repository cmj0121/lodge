import Foundation
import Testing

@testable import LodgeKit

@Suite struct DownloadFilesTests {
    private let root: URL
    private let folder: URL
    private let files: DownloadFiles

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "DownloadFilesTests-\(UUID().uuidString)")
        folder = root.appending(path: "Downloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        files = DownloadFiles(stagingFolder: root.appending(path: "Staging", directoryHint: .isDirectory))
    }

    private func make(_ url: URL, _ text: String = "x") throws {
        try Data(text.utf8).write(to: url)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    private func text(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }

    // MARK: Partial path

    @Test func thePartialSitsBesideTheFinalFileWhenItCanAndLeavesNothing() {
        let final = folder.appending(path: "a.zip")
        let partial = files.partialURL(for: final, id: UUID())
        #expect(partial == folder.appending(path: "a.zip.lodgedownload"))
        #expect(!exists(partial))
    }

    @Test func aFolderItCannotWriteStagesThePartial() {
        let id = UUID()
        let partial = files.partialURL(for: root.appending(path: "missing/a.zip"), id: id)
        #expect(partial == files.stagingFolder.appending(path: "\(id.uuidString).lodgedownload"))
        #expect(exists(files.stagingFolder))
        #expect(!exists(partial))
    }

    @Test func anExistingPartialIsNeverReplacedSoThePartialIsStaged() throws {
        let final = folder.appending(path: "a.zip")
        let existing = DownloadNaming.partialURL(for: final)
        try make(existing, "theirs")
        let id = UUID()
        #expect(files.partialURL(for: final, id: id) == files.stagedPartial(of: id))
        #expect(try text(existing) == "theirs")
    }

    @Test func aDanglingLinkWhereThePartialGoesStagesIt() throws {
        let final = folder.appending(path: "a.zip")
        let target = folder.appending(path: "nowhere")
        try FileManager.default.createSymbolicLink(
            at: DownloadNaming.partialURL(for: final), withDestinationURL: target)
        let id = UUID()
        #expect(files.partialURL(for: final, id: id) == files.stagedPartial(of: id))
        #expect(!exists(target))
    }

    // MARK: Finish

    @Test func aPartialSwappedForALinkFailsTheDownload() throws {
        let final = folder.appending(path: "a.zip")
        let partial = DownloadNaming.partialURL(for: final)
        let target = folder.appending(path: "secret.txt")
        try make(target)
        try FileManager.default.createSymbolicLink(at: partial, withDestinationURL: target)
        #expect(throws: DownloadFiles.FinishError.notARegularFile) {
            try files.finish(partial, to: final, placement: .unique)
        }
        #expect(!exists(final))
    }

    @Test func aFinalNameTakenByADanglingLinkPicksAnother() throws {
        let final = folder.appending(path: "a.zip")
        let partial = DownloadNaming.partialURL(for: final)
        try FileManager.default.createSymbolicLink(at: final, withDestinationURL: folder.appending(path: "nowhere"))
        try make(partial, "new")
        #expect(try files.finish(partial, to: final, placement: .unique) == folder.appending(path: "a (1).zip"))
    }

    @Test func uniqueMovesToTheFinalName() throws {
        let final = folder.appending(path: "a.zip")
        let partial = DownloadNaming.partialURL(for: final)
        try make(partial, "new")
        #expect(try files.finish(partial, to: final, placement: .unique) == final)
        #expect(try text(final) == "new")
        #expect(!exists(partial))
    }

    @Test func uniquePicksAnotherNameWhenTheFinalWasTakenMeanwhile() throws {
        let final = folder.appending(path: "a.zip")
        let partial = DownloadNaming.partialURL(for: final)
        try make(final, "old")
        try make(partial, "new")
        let landed = try files.finish(partial, to: final, placement: .unique, reserved: ["a (1).zip"])
        #expect(landed == folder.appending(path: "a (2).zip"))
        #expect(try text(final) == "old")
        #expect(try text(landed) == "new")
    }

    @Test func exactReplacesTheChosenFile() throws {
        let final = folder.appending(path: "a.zip")
        let partial = DownloadNaming.partialURL(for: final)
        try make(final, "old")
        try make(partial, "new")
        #expect(try files.finish(partial, to: final, placement: .exact) == final)
        #expect(try text(final) == "new")
        #expect(!exists(partial))
    }

    @Test func exactMovesAStagedPartialToANewFile() throws {
        let final = folder.appending(path: "chosen.bin")
        let partial = files.partialURL(for: root.appending(path: "missing/a.zip"), id: UUID())
        try make(partial, "new")
        #expect(try files.finish(partial, to: final, placement: .exact) == final)
        #expect(try text(final) == "new")
    }

    @Test func exactOverwritesAnExistingFileWithAStagedPartialFromAnotherFolder() throws {
        let final = folder.appending(path: "chosen.bin")
        try make(final, "old")
        let partial = files.partialURL(for: root.appending(path: "missing/a.zip"), id: UUID())
        #expect(partial.deletingLastPathComponent() != folder)
        try make(partial, "new")
        #expect(try files.finish(partial, to: final, placement: .exact) == final)
        #expect(try text(final) == "new")
        #expect(!exists(partial))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["chosen.bin"])
    }

    // MARK: Deleting

    @Test func onlyPartialsAreDeleted() throws {
        let partial = folder.appending(path: "a.zip.lodgedownload")
        let other = folder.appending(path: "a.zip")
        try make(partial)
        try make(other)
        #expect(DownloadFiles.deletePartial(partial))
        #expect(!DownloadFiles.deletePartial(other))
        #expect(!exists(partial))
        #expect(exists(other))
        #expect(!DownloadFiles.deletePartial(partial))
    }

    @Test func relaunchCleansPartialsOfInterruptedItemsAndTheStagingFolder() throws {
        func item(_ name: String, _ state: DownloadItem.State) -> DownloadItem {
            DownloadItem(sourceURL: nil, fileName: name, directory: folder, state: state, startedAt: Date())
        }
        let interrupted = folder.appending(path: "i.zip.lodgedownload")
        let failed = folder.appending(path: "f.zip.lodgedownload")
        let finalOfInterrupted = folder.appending(path: "i.zip")
        try FileManager.default.createDirectory(at: files.stagingFolder, withIntermediateDirectories: true)
        let staged = files.stagedPartial(of: UUID())
        let stagedOther = files.stagingFolder.appending(path: "note.txt")
        for url in [interrupted, failed, finalOfInterrupted, staged, stagedOther] { try make(url) }

        files.cleanUp(
            [item("i.zip", .interrupted), item("f.zip", .failed(reason: "x"))],
            createdBefore: Date().addingTimeInterval(60), downloadsFolder: folder)

        #expect(!exists(interrupted))
        #expect(!exists(staged))
        #expect(exists(failed))
        #expect(exists(finalOfInterrupted))
        #expect(exists(stagedOther))
    }

    @Test func relaunchKeepsPartialsCreatedSinceTheCutoff() throws {
        try FileManager.default.createDirectory(at: files.stagingFolder, withIntermediateDirectories: true)
        let staged = files.stagedPartial(of: UUID())
        try make(staged)
        files.cleanUp([], createdBefore: Date().addingTimeInterval(-60), downloadsFolder: folder)
        #expect(exists(staged))
    }

    @Test func relaunchWithoutAStagingFolderIsFine() {
        files.cleanUp([], createdBefore: Date(), downloadsFolder: folder)
    }

    @Test func relaunchOnlyCleansTheDownloadsCustomAndStagingFolders() throws {
        let elsewhere = root.appending(path: "Elsewhere", directoryHint: .isDirectory)
        let custom = root.appending(path: "Custom", directoryHint: .isDirectory)
        for url in [elsewhere, custom] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let outside = elsewhere.appending(path: "a.zip.lodgedownload")
        let inCustom = custom.appending(path: "b.zip.lodgedownload")
        try make(outside)
        try make(inCustom)
        func item(_ name: String, in directory: URL) -> DownloadItem {
            DownloadItem(sourceURL: nil, fileName: name, directory: directory, state: .interrupted, startedAt: Date())
        }

        files.cleanUp(
            [item("a.zip", in: elsewhere), item("b.zip", in: URL(filePath: custom.path(percentEncoded: false)))],
            createdBefore: Date().addingTimeInterval(60), downloadsFolder: folder, folder: custom)

        #expect(exists(outside))
        #expect(!exists(inCustom))
    }

    @Test func aFolderNamedLikeAPartialIsNeverDeleted() throws {
        let directory = folder.appending(path: "d.lodgedownload", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(!DownloadFiles.deletePartial(directory))
        #expect(exists(directory))
    }

    @Test func aLinkedPartialIsDeletedButNotItsTarget() throws {
        let target = folder.appending(path: "keep.txt")
        try make(target)
        let link = folder.appending(path: "l.zip.lodgedownload")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(DownloadFiles.deletePartial(link))
        #expect(DownloadFiles.fileType(of: link) == nil)
        #expect(exists(target))
    }
}
