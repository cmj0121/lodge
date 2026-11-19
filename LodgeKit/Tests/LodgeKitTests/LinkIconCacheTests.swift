import CoreGraphics
import Foundation
import Testing

@testable import LodgeKit

@Suite final class LinkIconCacheTests {
    private let app: URL
    private let cache: LinkIconCache

    init() throws {
        app = FileManager.default.temporaryDirectory.appending(
            path: "LinkIconCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        cache = LinkIconCache(directory: WorkspaceFiles.iconsDirectory(for: .default, in: app)!)
    }

    deinit {
        try? FileManager.default.removeItem(at: app)
    }

    private func icon(red: CGFloat) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: red, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try #require(context.makeImage())
        return try #require(LinkIcon.png(from: image))
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    private func modified(_ link: UUID) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: cache.url(for: link).path(percentEncoded: false))[
            .modificationDate] as? Date
    }

    // MARK: Where icons live

    @Test func eachWorkspaceKeepsItsIconsInItsOwnDirectory() {
        let custom = Workspace(name: "Work", symbol: "briefcase")
        #expect(WorkspaceFiles.iconsDirectory(for: .default, in: app) == app.appending(path: "Icons/"))
        #expect(
            WorkspaceFiles.iconsDirectory(for: custom, in: app)
                == WorkspaceFiles.directory(for: custom.id, in: app).appending(path: "Icons/"))
        let anonymous = Workspace(name: "Private", symbol: "eye.slash", kind: .anonymous)
        #expect(WorkspaceFiles.iconsDirectory(for: anonymous, in: app) == nil)
    }

    @Test func deletingAWorkspaceDeletesItsIcons() throws {
        let custom = Workspace(name: "Work", symbol: "briefcase")
        let icons = LinkIconCache(directory: WorkspaceFiles.iconsDirectory(for: custom, in: app)!)
        let link = UUID()
        try icons.write(try icon(red: 1), for: link)
        try WorkspaceFiles.remove(custom.id, in: app)
        #expect(!exists(icons.url(for: link)))
    }

    // MARK: Reading and writing

    /// A cache over the same directory that has read nothing yet, as after a relaunch.
    private var fresh: LinkIconCache { LinkIconCache(directory: cache.directory) }

    @Test func anIconWrittenIsReadBack() throws {
        let link = UUID()
        let data = try icon(red: 1)
        #expect(try cache.write(data, for: link))
        #expect(cache.icon(for: link) == data)
        #expect(fresh.icon(for: link) == data)
        #expect(cache.url(for: link).lastPathComponent == "\(link.uuidString).png")
    }

    @Test func aMissingDirectoryReadsAsNoIcons() {
        #expect(cache.icon(for: UUID()) == nil)
        #expect(!exists(cache.directory))
    }

    @Test func eachFileIsReadOnceThenRemembered() throws {
        let link = UUID()
        let data = try icon(red: 1)
        try fresh.write(data, for: link)
        #expect(cache.icon(for: link) == data)
        try FileManager.default.removeItem(at: cache.url(for: link))
        #expect(cache.icon(for: link) == data)
    }

    @Test func equalBytesWriteNothing() throws {
        let link = UUID()
        let data = try icon(red: 1)
        try cache.write(data, for: link)
        let past = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: past], ofItemAtPath: cache.url(for: link).path(percentEncoded: false))
        #expect(try !cache.write(data, for: link))
        #expect(try modified(link) == past)
    }

    @Test func aWriteComparesInMemoryWithoutReadingTheFileAgain() throws {
        let link = UUID()
        let data = try icon(red: 1)
        try cache.write(data, for: link)
        // Changed behind the cache's back: a write that read the file again would replace it.
        try Data("changed".utf8).write(to: cache.url(for: link))
        #expect(try !cache.write(data, for: link))
        #expect(try Data(contentsOf: cache.url(for: link)) == Data("changed".utf8))
    }

    @Test func equalBytesAlreadyOnDiskAfterARelaunchWriteNothing() throws {
        let link = UUID()
        let data = try icon(red: 1)
        try cache.write(data, for: link)
        #expect(try !fresh.write(data, for: link))
    }

    @Test func differentBytesReplaceTheIcon() throws {
        let link = UUID()
        try cache.write(try icon(red: 1), for: link)
        let next = try icon(red: 0.2)
        #expect(try cache.write(next, for: link))
        #expect(fresh.icon(for: link) == next)
    }

    @Test func bytesThatAreNotAnIconAreRefused() throws {
        let link = UUID()
        #expect(try !cache.write(Data("not a png".utf8), for: link))
        #expect(cache.icon(for: link) == nil)
    }

    @Test func aBadFileReadsAsNoneAndIsRemoved() throws {
        let link = UUID()
        try cache.write(try icon(red: 1), for: link)
        try Data("garbage".utf8).write(to: cache.url(for: link))
        #expect(fresh.icon(for: link) == nil)
        #expect(!exists(cache.url(for: link)))
    }

    // MARK: Removing

    @Test func removingALinkRemovesItsFile() throws {
        let link = UUID()
        try cache.write(try icon(red: 1), for: link)
        cache.remove(link)
        #expect(!exists(cache.url(for: link)))
        #expect(cache.icon(for: link) == nil)
        cache.remove(link)
    }

    @Test func pruneDropsOrphans() throws {
        let kept = UUID()
        let orphan = UUID()
        try cache.write(try icon(red: 1), for: kept)
        try cache.write(try icon(red: 0.5), for: orphan)
        LinkIconCache.prune(cache.directory, keeping: [kept], before: .distantFuture)
        #expect(exists(cache.url(for: kept)))
        #expect(!exists(cache.url(for: orphan)))
    }

    @Test func pruneKeepsAnIconWrittenAfterItsLinksWereListed() throws {
        let listed = Date.now.addingTimeInterval(-60)
        let added = UUID()
        try cache.write(try icon(red: 1), for: added)
        LinkIconCache.prune(cache.directory, keeping: [], before: listed)
        #expect(exists(cache.url(for: added)))
    }

    @Test func pruneOfAMissingDirectoryCreatesNothing() {
        LinkIconCache.prune(cache.directory, keeping: [], before: .distantFuture)
        #expect(!exists(cache.directory))
    }
}

@Suite struct LinkOwnLoadTests {
    /// The link's load as WebKit reports it: its own action, then any redirects.
    private func started(redirects: Int = 0) -> LinkOwnLoad {
        var load = LinkOwnLoad()
        load.start()
        load.navigationAction(isOther: false)
        for _ in 0..<redirects { load.navigationAction(isOther: true) }
        return load
    }

    @Test func aTabNotOpenedOnItsLinkKeepsNoIcon() {
        var load = LinkOwnLoad()
        #expect(!load.isOn)
        load.navigationAction(isOther: false)
        #expect(!load.isOn)
    }

    @Test func theOwnLoadKeepsItsIcon() {
        var load = started()
        load.loadEnded()
        #expect(load.isOn)
    }

    @Test func aRedirectOfTheOwnLoadIsKept() {
        var load = started(redirects: 2)
        #expect(load.isOn)
        load.loadEnded()
        #expect(load.isOn)
    }

    @Test func aLaterNavigationsIconIsNotKept() {
        var load = started()
        load.loadEnded()
        load.navigationAction(isOther: false)
        #expect(!load.isOn)
    }

    @Test func aScriptNavigatingAfterTheLoadIsNotKept() {
        var load = started()
        load.loadEnded()
        load.navigationAction(isOther: true)
        #expect(!load.isOn)
    }

    @Test func aClickDuringTheOwnLoadLeavesIt() {
        var load = started()
        load.navigationAction(isOther: false)
        #expect(!load.isOn)
        load.navigationAction(isOther: true)
        #expect(!load.isOn)
    }

    @Test func onceLeftItStaysOff() {
        var load = started()
        load.loadEnded()
        load.navigationAction(isOther: false)
        load.loadEnded()
        load.navigationAction(isOther: true)
        #expect(!load.isOn)
    }
}
