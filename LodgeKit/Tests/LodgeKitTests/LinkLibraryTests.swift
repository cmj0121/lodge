import Foundation
import Testing

@testable import LodgeKit

@Suite struct LinkLibraryTests {
    private let a = URL(string: "https://a.example")!
    private let b = URL(string: "https://b.example")!
    private let c = URL(string: "https://c.example")!

    @Test(arguments: [LinkShelf.pins, .bookmarks])
    func addsLinksInOrder(shelf: LinkShelf) {
        var library = LinkLibrary()
        library.add(a, title: "A", to: shelf)
        library.add(b, title: "B", to: shelf)
        library.add(c, title: "C", to: shelf)
        #expect(library.links(on: shelf).map(\.url) == [a, b, c])
        #expect(library.links(on: shelf).map(\.title) == ["A", "B", "C"])
    }

    @Test func keepsShelvesApart() {
        var library = LinkLibrary()
        library.add(a, title: "A", to: .pins)
        library.add(b, title: "B", to: .bookmarks)
        #expect(library.links(on: .pins).map(\.url) == [a])
        #expect(library.links(on: .bookmarks).map(\.url) == [b])
    }

    @Test(arguments: [LinkShelf.pins, .bookmarks])
    func removesALinkKeepingTheOrderOfTheRest(shelf: LinkShelf) {
        var library = LinkLibrary()
        library.add(a, title: "A", to: shelf)
        let middle = library.add(b, title: "B", to: shelf)
        library.add(c, title: "C", to: shelf)
        library.remove(middle.id)
        #expect(library.links(on: shelf).map(\.url) == [a, c])
    }

    @Test func removingAnUnknownIDChangesNothing() {
        var library = LinkLibrary.sample
        library.remove(UUID())
        #expect(library == .sample)
    }

    @Test(arguments: [LinkShelf.pins, .bookmarks])
    func addingTheSameURLToAShelfReturnsTheExistingLink(shelf: LinkShelf) {
        var library = LinkLibrary()
        let first = library.add(a, title: "A", to: shelf)
        let again = library.add(a, title: "Another title", to: shelf)
        #expect(again == first)
        #expect(library.links(on: shelf) == [first])
    }

    @Test func theSameURLCanSitOnBothShelves() {
        var library = LinkLibrary()
        let pin = library.add(a, title: "A", to: .pins)
        let bookmark = library.add(a, title: "A", to: .bookmarks)
        #expect(pin.id != bookmark.id)
        #expect(library.links(on: .pins) == [pin])
        #expect(library.links(on: .bookmarks) == [bookmark])
    }

    @Test func sampleHasFourPinsThreeRootBookmarksAndAFolderAllHTTPS() {
        let sample = LinkLibrary.sample
        #expect(sample.links(on: .pins).count == 4)
        #expect(sample.bookmarks.children.filter { if case .link = $0 { true } else { false } }.count == 3)
        #expect(sample.bookmarks.children.filter { if case .folder = $0 { true } else { false } }.count == 1)
        let links = sample.links(on: .pins) + sample.links(on: .bookmarks)
        #expect(links.allSatisfy { $0.url.scheme == "https" && !$0.title.isEmpty })
        #expect(Set(links.map(\.id)).count == links.count)
    }

    @Test(arguments: [(0, ["B", "A", "C"]), (2, ["A", "C", "B"]), (-3, ["B", "A", "C"]), (9, ["A", "C", "B"])])
    func movesAPinToAnIndexKeepingTheOrderOfTheRest(index: Int, titles: [String]) {
        var library = LinkLibrary()
        library.add(a, title: "A", to: .pins)
        let middle = library.add(b, title: "B", to: .pins)
        library.add(c, title: "C", to: .pins)
        library.add(a, title: "A", to: .bookmarks)
        library.move(middle.id, to: index)
        #expect(library.links(on: .pins).map(\.title) == titles)
        #expect(library.links(on: .bookmarks).map(\.title) == ["A"])
    }

    @Test func moveLeavesBookmarksAlone() {
        var library = LinkLibrary.sample
        library.move(library.links(on: .bookmarks).last!.id, to: 0)
        #expect(library == .sample)
    }

    @Test func movingAnUnknownIDChangesNothing() {
        var library = LinkLibrary.sample
        library.move(UUID(), to: 0)
        #expect(library == .sample)
    }

    @Test func savedLinksRoundTripThroughJSON() throws {
        let links = LinkLibrary.sample.links(on: .pins)
        let data = try JSONEncoder().encode(links)
        #expect(try JSONDecoder().decode([SavedLink].self, from: data) == links)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(object.allSatisfy { Set($0.keys) == ["id", "url", "title"] })
    }

    @Test func aLodgePageLinkRoundTripsThroughJSON() throws {
        var library = LinkLibrary()
        library.add(LodgePage.settings.url, title: "Settings", to: .pins)
        library.add(LodgePage.history.url, title: "History", to: .bookmarks)
        let pins = try JSONDecoder().decode([SavedLink].self, from: JSONEncoder().encode(library.links(on: .pins)))
        #expect(pins.map(\.url) == [LodgePage.settings.url])
        #expect(library.links(on: .bookmarks).map(\.url) == [LodgePage.history.url])
    }

    @Test func libraryRebuildsFromDecodedShelves() throws {
        let sample = LinkLibrary.sample
        let pins = try JSONEncoder().encode(sample.links(on: .pins))
        let bookmarks = try JSONEncoder().encode(sample.bookmarks)
        let rebuilt = LinkLibrary(
            pins: try JSONDecoder().decode([SavedLink].self, from: pins),
            bookmarks: try JSONDecoder().decode(BookmarkFolder.self, from: bookmarks)
        )
        #expect(rebuilt == sample)
    }

    @Test func flatBookmarksLandInAnOpenRootInOrder() {
        let links = LinkLibrary.sample.links(on: .pins)
        let library = LinkLibrary(pins: [], bookmarks: links)
        #expect(library.bookmarks.children == links.map(BookmarkNode.link))
        #expect(library.bookmarks.isExpanded)
    }

    @Test func pinIconsCodeTolerantlyAndCanBeSet() throws {
        var library = LinkLibrary()
        let pin = library.add(a, title: "A", to: .pins)
        #expect(pin.icon == nil)
        library.setIcon(pin.id, Data([7]))
        #expect(library.links(on: .pins).map(\.icon) == [Data([7])])
        let data = try JSONEncoder().encode(library.links(on: .pins))
        #expect(try JSONDecoder().decode([SavedLink].self, from: data) == library.links(on: .pins))
        let plain = try JSONEncoder().encode(SavedLink(url: b, title: "B"))
        #expect(!String(decoding: plain, as: UTF8.self).contains("icon"))
        let id = UUID()
        let old = Data(#"{"id":"\#(id.uuidString)","title":"B","url":"https://b.example"}"#.utf8)
        #expect(try JSONDecoder().decode(SavedLink.self, from: old) == SavedLink(id: id, url: b, title: "B"))
    }

    @Test func defaultLibraryIsEmpty() {
        let library = LinkLibrary()
        #expect(LinkShelf.allCases.allSatisfy { library.links(on: $0).isEmpty })
    }

    // MARK: Moves between shelves (#33)

    private func done(_ changed: Bool) -> Bool { changed }

    private var reading: BookmarkFolder {
        LinkLibrary.sample.bookmarks.children.compactMap { if case .folder(let f) = $0 { f } else { nil } }[0]
    }

    @Test func aBookmarkMovesToThePinsKeepingItsLink() {
        var library = LinkLibrary.sample
        let bookmark = library.links(on: .bookmarks)[1]
        #expect(done(library.moveLinkToPins(bookmark.id, at: 1)))
        #expect(library.links(on: .pins)[1] == bookmark)
        #expect(library.links(on: .pins).count == 5)
        #expect(!library.links(on: .bookmarks).contains(bookmark))
    }

    @Test func aBookmarkInAFolderMovesToThePinsAndTheIndexIsClamped() {
        var library = LinkLibrary.sample
        let nested = reading.links[0]
        #expect(done(library.moveLinkToPins(nested.id, at: 99)))
        #expect(library.links(on: .pins).last == nested)
        #expect(library.folder(reading.id)?.children.isEmpty == true)
    }

    @Test func aPinMovesIntoAFolderKeepingItsLink() {
        var library = LinkLibrary.sample
        let pin = library.links(on: .pins)[2]
        #expect(done(library.moveLinkToBookmarks(pin.id, into: reading.id, at: 0)))
        #expect(library.folder(reading.id)?.links.first == pin)
        #expect(!library.links(on: .pins).contains(pin))
    }

    @Test func aPinMovesToTheEndOfTheRootWithNoIndex() {
        var library = LinkLibrary.sample
        let pin = library.links(on: .pins)[0]
        #expect(done(library.moveLinkToBookmarks(pin.id, into: library.bookmarks.id, at: nil)))
        #expect(library.bookmarks.children.last == .link(pin))
    }

    @Test func refusedShelfMovesLeaveTheLibraryEqual() {
        let sample = LinkLibrary.sample
        let pin = sample.links(on: .pins)[0]
        let bookmark = sample.links(on: .bookmarks)[0]
        var library = sample
        #expect(!done(library.moveLinkToPins(UUID(), at: 0)))
        #expect(!done(library.moveLinkToPins(pin.id, at: 0)))
        #expect(!done(library.moveLinkToPins(reading.id, at: 0)))
        #expect(!done(library.moveLinkToBookmarks(UUID(), into: sample.bookmarks.id, at: nil)))
        #expect(!done(library.moveLinkToBookmarks(bookmark.id, into: sample.bookmarks.id, at: nil)))
        #expect(!done(library.moveLinkToBookmarks(reading.id, into: sample.bookmarks.id, at: nil)))
        #expect(!done(library.moveLinkToBookmarks(pin.id, into: UUID(), at: nil)))
        #expect(!done(library.moveLinkToBookmarks(pin.id, into: bookmark.id, at: nil)))
        #expect(library == sample)
    }

    @Test func aMoveOntoAURLAlreadyThereIsRefused() {
        var library = LinkLibrary()
        let pin = library.add(a, title: "A", to: .pins)
        let bookmark = library.add(a, title: "A", to: .bookmarks)
        let before = library
        #expect(!done(library.moveLinkToPins(bookmark.id, at: 0)))
        #expect(!done(library.moveLinkToBookmarks(pin.id, into: library.bookmarks.id, at: 0)))
        #expect(library == before)
    }

    @Test func insertingKeepsTheLinkAsItIsAtTheClampedPlace() {
        var library = LinkLibrary.sample
        let link = SavedLink(url: a, title: "A", icon: Data([1]))
        #expect(done(library.insert(link, toPinsAt: -3)))
        #expect(library.links(on: .pins).first == link)
        let bookmark = SavedLink(url: b, title: "B")
        #expect(done(library.insertBookmark(bookmark, into: reading.id, at: 0)))
        #expect(library.folder(reading.id)?.links.first == bookmark)
        let last = SavedLink(url: c, title: "C")
        #expect(done(library.insertBookmark(last, into: library.bookmarks.id, at: nil)))
        #expect(library.bookmarks.children.last == .link(last))
    }

    @Test func refusedInsertsLeaveTheLibraryEqual() {
        let sample = LinkLibrary.sample
        let pin = sample.links(on: .pins)[0]
        let bookmark = sample.links(on: .bookmarks)[0]
        var library = sample
        #expect(!done(library.insert(SavedLink(url: pin.url, title: "Again"), toPinsAt: 0)))
        #expect(!done(library.insert(bookmark, toPinsAt: 0)))
        let again = SavedLink(url: bookmark.url, title: "Again")
        #expect(!done(library.insertBookmark(again, into: sample.bookmarks.id, at: 0)))
        #expect(!done(library.insertBookmark(pin, into: sample.bookmarks.id, at: 0)))
        #expect(!done(library.insertBookmark(SavedLink(url: a, title: "A"), into: UUID(), at: 0)))
        #expect(library == sample)
    }

    @Test func aURLInAnotherFolderCanStillBeInserted() {
        var library = LinkLibrary.sample
        let nested = reading.links[0]
        let copy = SavedLink(url: nested.url, title: "Root copy")
        #expect(done(library.insertBookmark(copy, into: library.bookmarks.id, at: 0)))
    }
}
