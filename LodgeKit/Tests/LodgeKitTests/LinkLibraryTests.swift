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

    @Test func sampleHasFourPinsAndThreeBookmarksAllHTTPS() {
        let sample = LinkLibrary.sample
        #expect(sample.links(on: .pins).count == 4)
        #expect(sample.links(on: .bookmarks).count == 3)
        let links = sample.links(on: .pins) + sample.links(on: .bookmarks)
        #expect(links.allSatisfy { $0.url.scheme == "https" && !$0.title.isEmpty })
        #expect(Set(links.map(\.id)).count == links.count)
    }
}
