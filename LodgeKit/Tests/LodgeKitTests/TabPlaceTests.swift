import Foundation
import JavaScriptCore
import Testing

@testable import LodgeKit

@Suite struct TabPlaceTests {
    private let page = URL(string: "https://example.com/a")!
    /// A stand-in for WebKit's state of a tab that sent a form: S0 found the body in it in plain text.
    private let postedState = Data("SessionHistoryEntries field=hello&pw=MARKERPW3X".utf8)

    private func place(state: Data? = Data("state".utf8), sentForm: Bool = false, scrollY: Double? = 120)
        -> TabPlace
    {
        TabPlace(url: page, title: "A", scrollY: scrollY, state: state, sentForm: sentForm)
    }

    // MARK: The hybrid rule

    @Test func aTabThatNeverSentAFormKeepsWebKitsState() {
        let place = place()
        #expect(!place.isRecord)
        #expect(place.wake(at: page) == .state(Data("state".utf8)))
    }

    @Test func aTabThatSentAFormKeepsOnlyItsRecord() throws {
        let place = place(state: postedState, sentForm: true)
        #expect(place.isRecord)
        #expect(place.state == nil)
        #expect(place.wake(at: page) == .load(page, scrollY: 120))
        let data = try #require(place.encoded(limit: PlaceStore.tabLimit))
        #expect(data.range(of: Data("MARKERPW3X".utf8)) == nil)
        #expect(data.range(of: Data("field=hello".utf8)) == nil)
    }

    @Test func aRecordAtTheTopLoadsWithoutScrolling() {
        #expect(place(state: nil, scrollY: 0).wake(at: page) == .load(page, scrollY: nil))
        #expect(place(state: nil, scrollY: nil).wake(at: page) == .load(page, scrollY: nil))
    }

    @Test func aPlaceForAnotherAddressIsNotUsed() {
        #expect(place().wake(at: URL(string: "https://example.com/b")) == nil)
        #expect(place().wake(at: nil) == nil)
    }

    @Test func anUnusableScrollPositionIsDropped() {
        for y in [-1, .nan, .infinity, 20_000_000] {
            #expect(place(scrollY: y).scrollY == nil, "\(y)")
        }
    }

    // MARK: Format

    @Test func aPlaceRoundTrips() throws {
        for original in [place(), place(sentForm: true), place(state: nil, scrollY: nil)] {
            let data = try #require(original.encoded(limit: PlaceStore.tabLimit))
            #expect(TabPlace.decode(data, limit: PlaceStore.tabLimit) == original)
        }
    }

    @Test func aPlaceTooBigKeepsOnlyItsRecord() throws {
        let big = place(state: Data(repeating: 7, count: 2_000))
        let data = try #require(big.encoded(limit: 1_000))
        let read = try #require(TabPlace.decode(data, limit: 1_000))
        #expect(read.isRecord)
        #expect(read.url == page && read.scrollY == 120)
    }

    @Test func aRecordTooBigIsNoPlace() {
        let huge = URL(string: "data:text/html," + String(repeating: "x", count: 2_000))!
        let place = TabPlace(url: huge, title: "", scrollY: nil, state: nil, sentForm: false)
        #expect(place.encoded(limit: 1_000) == nil)
    }

    @Test func corruptTooBigOrOtherVersionDataIsNoPlace() throws {
        #expect(TabPlace.decode(Data("not a plist".utf8), limit: PlaceStore.tabLimit) == nil)
        #expect(TabPlace.decode(Data(), limit: PlaceStore.tabLimit) == nil)
        let data = try #require(place().encoded(limit: PlaceStore.tabLimit))
        #expect(TabPlace.decode(data, limit: data.count - 1) == nil)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let newer = try encoder.encode(
            ["version": "\(TabPlace.formatVersion + 1)", "url": page.absoluteString, "title": "A"])
        #expect(TabPlace.decode(newer, limit: PlaceStore.tabLimit) == nil)
        struct Other: Encodable {
            var version = TabPlace.formatVersion + 1
            var url: URL
            var title = "A"
        }
        #expect(TabPlace.decode(try encoder.encode(Other(url: page)), limit: PlaceStore.tabLimit) == nil)
    }

    // MARK: Main-frame scroll

    @Test func theLatestScrollStandsUntilItsDocumentLeaves() {
        var scroll = MainScroll()
        #expect(scroll.y == nil)
        scroll.apply(.scrolled(document: "a", y: 40))
        scroll.apply(.scrolled(document: "a", y: 80))
        #expect(scroll.y == 80)
        scroll.apply(.left(document: "other"))
        #expect(scroll.y == 80)
        scroll.apply(.left(document: "a"))
        #expect(scroll.y == nil)
        scroll.apply(.scrolled(document: "b", y: 10))
        #expect(scroll.y == 10)
    }

    @Test func placeMessagesDecodeOnlyTheirOwnShape() {
        #expect(PageWorkScript.place(from: ["doc": "d", "kind": "scroll", "y": 12.5]) == .scrolled(document: "d", y: 12.5))
        #expect(PageWorkScript.place(from: ["doc": "d", "kind": "scroll", "y": 0]) == .scrolled(document: "d", y: 0))
        #expect(PageWorkScript.place(from: ["doc": "d", "kind": "left"]) == .left(document: "d"))
        #expect(PageWorkScript.place(from: ["doc": "d", "kind": "scroll", "y": -1]) == nil)
        #expect(PageWorkScript.place(from: ["doc": "d", "kind": "scroll", "y": "1"]) == nil)
        #expect(PageWorkScript.place(from: ["doc": "d", "kind": "scroll"]) == nil)
        #expect(PageWorkScript.place(from: ["doc": "d", "kind": "scroll", "y": 1, "value": "x"]) == nil)
        #expect(PageWorkScript.place(from: ["doc": "", "kind": "left"]) == nil)
        #expect(PageWorkScript.place(from: ["doc": "d", "kind": "typed"]) == nil)
        #expect(PageWorkScript.signal(from: ["doc": "d", "kind": "left"]) == nil)
    }

    // MARK: The scroll-restoring script

    @Test func theRestoreScriptScrollsOnlyItsOwnPageInTheMainFrame() throws {
        func scrolled(href: String, top: Bool, input: String? = nil) throws -> [Double] {
            let context = try #require(JSContext())
            context.evaluateScript(
                """
                var scrolls = [];
                var listeners = {};
                function setTimeout(fn) { fn(); }
                var location = { href: \(String(reflecting: href)) };
                var window = {
                  addEventListener: function (type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
                  scrollTo: function (x, y) { scrolls.push(y); },
                };
                window.top = \(top ? "window" : "{}");
                function fire(type, props) {
                  (listeners[type] || []).forEach(function (fn) { fn(Object.assign({ isTrusted: true }, props || {})); });
                }
                """)
            context.evaluateScript(PlaceScript.restoreScroll(to: 640, at: URL(string: "https://example.com/a?q=\"x\"")!))
            if let input { context.evaluateScript("fire('\(input)');") }
            context.evaluateScript("fire('load');")
            return (context.objectForKeyedSubscript("scrolls").toArray() ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
        }
        let own = "https://example.com/a?q=%22x%22"
        #expect(try scrolled(href: own, top: true) == [640, 640, 640])
        #expect(try scrolled(href: own, top: true, input: "wheel") == [640])
        #expect(try scrolled(href: "https://example.com/b", top: true).isEmpty)
        #expect(try scrolled(href: own, top: false).isEmpty)
    }
}

@Suite final class PlaceStoreTests {
    private let directory: URL
    private let page = URL(string: "https://example.com/a")!

    init() {
        directory = FileManager.default.temporaryDirectory.appending(
            path: "PlaceStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func place(state: Data? = Data("state".utf8), sentForm: Bool = false) -> TabPlace {
        TabPlace(url: page, title: "A", scrollY: 10, state: state, sentForm: sentForm)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    private func permissions(_ url: URL) throws -> Int {
        try #require(
            FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int)
    }

    @Test func aWrittenPlaceReadsBack() throws {
        let store = PlaceStore(directory: directory)
        let tab = TabID()
        try store.write(place(), for: tab)
        #expect(store.read(tab) == place())
        #expect(store.url(for: tab).lastPathComponent == "\(tab.uuidString).place")
    }

    @Test func placesAreOwnerOnly() throws {
        let store = PlaceStore(directory: directory)
        let tab = TabID()
        try store.write(place(), for: tab)
        #expect(try permissions(directory) == 0o700)
        #expect(try permissions(store.url(for: tab)) == 0o600)
    }

    @Test func writingLeavesNoTemporaryFileAndRewritesInPlace() throws {
        let store = PlaceStore(directory: directory)
        let tab = TabID()
        try store.write(place(), for: tab)
        try store.write(place(state: Data("newer".utf8)), for: tab)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(names == ["\(tab.uuidString).place"])
        #expect(store.read(tab)?.state == Data("newer".utf8))
        #expect(try permissions(store.url(for: tab)) == 0o600)
    }

    @Test func pruneRemovesTemporaryFilesAWriteLeftBehind() throws {
        let store = PlaceStore(directory: directory)
        let tab = TabID()
        try store.write(place(), for: tab)
        let leftover = directory.appending(path: ".\(UUID().uuidString).tmp")
        try Data("pw=MARKERPW3X".utf8).write(to: leftover)
        store.prune(keeping: [tab])
        #expect(!exists(leftover))
        #expect(store.read(tab) != nil)
    }

    @Test func aPlaceRemovedBehindTheStoresBackNoLongerCounts() throws {
        let probe = try #require(place(state: Data(repeating: 1, count: 1_000)).encoded(limit: PlaceStore.tabLimit))
        let store = PlaceStore(directory: directory, totalLimit: probe.count * 2 + 10)
        let (gone, kept, new) = (TabID(), TabID(), TabID())
        try store.write(place(state: Data(repeating: 1, count: 1_000)), for: gone, seen: .now)
        try store.write(
            place(state: Data(repeating: 1, count: 1_000)), for: kept, seen: .now.addingTimeInterval(-3_600))
        try FileManager.default.removeItem(at: store.url(for: gone))
        #expect(store.read(gone) == nil)
        // Without the stale size of `gone`, the total fits and the older `kept` stays.
        try store.write(place(state: Data(repeating: 1, count: 1_000)), for: new)
        #expect(store.read(kept) != nil)
        #expect(store.read(new) != nil)
    }

    @Test func aStoreCountsThePlacesAnEarlierOneWrote() throws {
        let probe = try #require(place(state: Data(repeating: 1, count: 1_000)).encoded(limit: PlaceStore.tabLimit))
        let old = TabID()
        try PlaceStore(directory: directory)
            .write(place(state: Data(repeating: 1, count: 1_000)), for: old, seen: .distantPast)
        let store = PlaceStore(directory: directory, totalLimit: probe.count + 10)
        let new = TabID()
        try store.write(place(state: Data(repeating: 1, count: 1_000)), for: new)
        #expect(store.read(old) == nil)
        #expect(store.read(new) != nil)
    }

    @Test func aDirectoryRemovedAfterTheFirstWriteIsMadeAgain() throws {
        let store = PlaceStore(directory: directory)
        try store.write(place(), for: TabID())
        try FileManager.default.removeItem(at: directory)
        let tab = TabID()
        try store.write(place(), for: tab)
        #expect(store.read(tab) != nil)
        #expect(try permissions(directory) == 0o700)
    }

    @Test func aTabThatSentAFormWritesNoState() throws {
        let store = PlaceStore(directory: directory)
        let tab = TabID()
        try store.write(place(state: Data("pw=MARKERPW3X".utf8), sentForm: true), for: tab)
        let bytes = try Data(contentsOf: store.url(for: tab))
        #expect(bytes.range(of: Data("MARKERPW3X".utf8)) == nil)
        #expect(store.read(tab)?.isRecord == true)
    }

    @Test func aMissingPlaceIsNil() {
        #expect(PlaceStore(directory: directory).read(TabID()) == nil)
    }

    @Test func aCorruptPlaceIsNilAndRemoved() throws {
        let store = PlaceStore(directory: directory)
        let tab = TabID()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: store.url(for: tab))
        #expect(store.read(tab) == nil)
        #expect(!exists(store.url(for: tab)))
    }

    @Test func aPlaceFileTooBigIsNilAndRemoved() throws {
        let store = PlaceStore(directory: directory, tabLimit: 100)
        let tab = TabID()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 101).write(to: store.url(for: tab))
        #expect(store.read(tab) == nil)
        #expect(!exists(store.url(for: tab)))
    }

    @Test func aPlaceTooBigForTheTabKeepsItsRecord() throws {
        let store = PlaceStore(directory: directory, tabLimit: 1_000)
        let tab = TabID()
        try store.write(place(state: Data(repeating: 1, count: 5_000)), for: tab)
        #expect(store.read(tab)?.isRecord == true)
    }

    @Test func aPlaceThatCannotFitRemovesTheOldOne() throws {
        let store = PlaceStore(directory: directory, tabLimit: 1_000)
        let tab = TabID()
        try store.write(place(), for: tab)
        let huge = URL(string: "data:text/html," + String(repeating: "x", count: 2_000))!
        try store.write(TabPlace(url: huge, title: "", scrollY: nil, state: nil, sentForm: false), for: tab)
        #expect(store.read(tab) == nil)
        #expect(!exists(store.url(for: tab)))
    }

    @Test func pastTheTotalTheLeastRecentlySeenGo() throws {
        let probe = try #require(place(state: Data(repeating: 1, count: 1_000)).encoded(limit: PlaceStore.tabLimit))
        let store = PlaceStore(directory: directory, totalLimit: probe.count * 3)
        let tabs = (0..<4).map { _ in TabID() }
        let start = Date(timeIntervalSince1970: 1_000_000)
        // Written out of seen order: the oldest is the second.
        let seen = [start.addingTimeInterval(20), start, start.addingTimeInterval(30), start.addingTimeInterval(40)]
        for (tab, date) in zip(tabs, seen) {
            try store.write(place(state: Data(repeating: 1, count: 1_000)), for: tab, seen: date)
        }
        #expect(store.read(tabs[1]) == nil)
        for tab in [tabs[0], tabs[2], tabs[3]] { #expect(store.read(tab) != nil) }
    }

    @Test func theTabJustWrittenIsNeverEvicted() throws {
        let probe = try #require(place(state: Data(repeating: 1, count: 1_000)).encoded(limit: PlaceStore.tabLimit))
        let store = PlaceStore(directory: directory, totalLimit: probe.count + 10)
        let old = TabID()
        let new = TabID()
        try store.write(place(state: Data(repeating: 1, count: 1_000)), for: old, seen: .now)
        try store.write(
            place(state: Data(repeating: 1, count: 1_000)), for: new, seen: .now.addingTimeInterval(-3_600))
        #expect(store.read(new) != nil)
        #expect(store.read(old) == nil)
    }

    @Test func removeAndPruneDeleteOnlyWhatTheySay() throws {
        let store = PlaceStore(directory: directory)
        let (a, b, c) = (TabID(), TabID(), TabID())
        for tab in [a, b, c] { try store.write(place(), for: tab) }
        let other = directory.appending(path: "notes.txt")
        try Data("x".utf8).write(to: other)
        store.remove(a)
        store.remove(TabID())
        #expect(store.read(a) == nil)
        store.prune(keeping: [b])
        #expect(store.read(b) != nil)
        #expect(store.read(c) == nil)
        #expect(exists(other))
    }

    @Test func eachWorkspaceKeepsItsPlacesApartAndAnonymousNone() throws {
        let app = directory
        let custom = Workspace(name: "Work", symbol: "briefcase")
        let anonymous = Workspace(name: "Private", symbol: "eye.slash", kind: .anonymous)
        let defaultPlaces = try #require(WorkspaceFiles.placesDirectory(for: .default, in: app))
        let customPlaces = try #require(WorkspaceFiles.placesDirectory(for: custom, in: app))
        #expect(defaultPlaces == app.appending(path: "Places", directoryHint: .isDirectory))
        #expect(customPlaces.deletingLastPathComponent() == WorkspaceFiles.directory(for: custom.id, in: app))
        #expect(WorkspaceFiles.placesDirectory(for: anonymous, in: app) == nil)
        #expect(WorkspaceFiles.placesDirectory(for: .anonymous, in: app) == nil)

        let tab = TabID()
        try PlaceStore(directory: defaultPlaces).write(place(), for: tab)
        try PlaceStore(directory: customPlaces).write(place(), for: tab)
        try WorkspaceFiles.remove(custom.id, in: app)
        #expect(!exists(customPlaces))
        #expect(PlaceStore(directory: defaultPlaces).read(tab) != nil)
        try WorkspaceFiles.remove(Workspace.defaultID, in: app)
        #expect(PlaceStore(directory: defaultPlaces).read(tab) != nil)
    }
}
