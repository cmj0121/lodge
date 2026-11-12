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

    @Test func defaultLibraryIsEmpty() {
        let library = LinkLibrary()
        #expect(LinkShelf.allCases.allSatisfy { library.links(on: $0).isEmpty })
    }
}
