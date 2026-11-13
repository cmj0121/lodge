import Foundation
import Testing

@testable import LodgeKit

@Suite struct BookmarkTreeTests {
    private let a = URL(string: "https://a.example")!
    private let b = URL(string: "https://b.example")!
    private let c = URL(string: "https://c.example")!

    private func titles(_ folder: BookmarkFolder?) -> [String] {
        (folder?.children ?? []).map {
            switch $0 {
            case .link(let link): link.title
            case .folder(let folder): folder.title
            }
        }
    }

    /// Root: A, B, Work [Deep [D]], C.
    private func tree() -> (library: LinkLibrary, work: UUID, deep: UUID, d: SavedLink) {
        var library = LinkLibrary()
        let root = library.bookmarks.id
        library.add(a, title: "A", to: .bookmarks)
        library.add(b, title: "B", to: .bookmarks)
        let work = library.addFolder("Work", in: root)!.id
        let deep = library.addFolder("Deep", in: work)!.id
        let d = library.addBookmark(URL(string: "https://d.example")!, title: "D", in: deep)!
        library.add(c, title: "C", to: .bookmarks)
        return (library, work, deep, d)
    }

    @Test func linksOnBookmarksAreTheWholeTreeDepthFirst() {
        #expect(tree().library.links(on: .bookmarks).map(\.title) == ["A", "B", "D", "C"])
    }

    @Test func aURLIsAddedOnlyOncePerFolder() {
        var library = LinkLibrary()
        let folder = library.addFolder("F", in: library.bookmarks.id)!.id
        let first = library.addBookmark(a, title: "A", in: folder)!
        let again = library.addBookmark(a, title: "Again", in: folder)
        #expect(again == first)
        let inRoot = library.add(a, title: "A", to: .bookmarks)
        #expect(inRoot.id != first.id)
        let againInRoot = library.add(a, title: "Again", to: .bookmarks)
        #expect(againInRoot == inRoot)
        #expect(library.links(on: .bookmarks).map(\.id) == [first.id, inRoot.id])
        let nowhere = library.addBookmark(b, title: "B", in: UUID())
        #expect(nowhere == nil)
    }

    @Test func addsFoldersCollapsedAtAnIndexClampedOrAppended() {
        var library = LinkLibrary()
        let root = library.bookmarks.id
        library.add(a, title: "A", to: .bookmarks)
        library.addFolder("End", in: root)
        library.addFolder("First", in: root, at: -4)
        library.addFolder("Second", in: root, at: 1)
        library.addFolder("Last", in: root, at: 99)
        #expect(titles(library.bookmarks) == ["First", "Second", "A", "End", "Last"])
        #expect(library.bookmarks.children.allSatisfy { if case .folder(let f) = $0 { !f.isExpanded } else { true } })
        let nowhere = library.addFolder("Nowhere", in: UUID())
        #expect(nowhere == nil)
    }

    @Test func insertAppendsAWholeFolder() {
        var (library, work, _, _) = tree()
        let imported = BookmarkFolder(
            title: "Imported", children: [.link(SavedLink(url: a, title: "X")), .folder(BookmarkFolder(title: "Sub"))])
        library.insert(imported, in: work)
        #expect(library.folder(imported.id) == imported)
        #expect(titles(library.folder(work)) == ["Deep", "Imported"])
        let before = library
        library.insert(imported, in: UUID())
        #expect(library == before)
    }

    @Test func renamesFoldersAndBookmarksButNotTheRootOrPins() {
        var (library, work, _, d) = tree()
        let pin = library.add(a, title: "Pin", to: .pins)
        library.rename(work, to: "Job")
        library.rename(d.id, to: "Dee")
        #expect(library.folder(work)?.title == "Job")
        #expect(library.links(on: .bookmarks).map(\.title) == ["A", "B", "Dee", "C"])
        let before = library
        library.rename(library.bookmarks.id, to: "Root")
        library.rename(pin.id, to: "Renamed")
        library.rename(UUID(), to: "Ghost")
        #expect(library == before)
    }

    @Test func removingAFolderRemovesItsDescendantsAndReturnsTheirLinks() {
        var (library, work, deep, d) = tree()
        let e = library.addBookmark(a, title: "E", in: work)!
        let removed = library.remove(work)
        #expect(Set(removed) == [d.id, e.id])
        #expect(library.folder(work) == nil)
        #expect(library.folder(deep) == nil)
        #expect(library.links(on: .bookmarks).map(\.title) == ["A", "B", "C"])
    }

    @Test func removeReturnsTheLinkForABookmarkOrPinAndNothingForTheRootOrUnknown() {
        var (library, _, deep, d) = tree()
        let pin = library.add(a, title: "Pin", to: .pins)
        let bookmark = library.remove(d.id)
        #expect(bookmark == [d.id])
        #expect(library.folder(deep)?.children.isEmpty == true)
        let pinned = library.remove(pin.id)
        #expect(pinned == [pin.id])
        #expect(library.links(on: .pins).isEmpty)
        let emptyFolder = library.remove(deep)
        #expect(emptyFolder == [])
        let before = library
        let root = library.remove(library.bookmarks.id)
        let unknown = library.remove(UUID())
        #expect(root == [] && unknown == [])
        #expect(library == before)
    }

    @Test(arguments: [
        ("A", 0, ["A", "B", "Work", "C"]), ("A", 2, ["B", "A", "Work", "C"]), ("A", 3, ["B", "Work", "A", "C"]),
        ("A", 4, ["B", "Work", "C", "A"]), ("C", 0, ["C", "A", "B", "Work"]), ("C", 1, ["A", "C", "B", "Work"]),
        ("B", -5, ["B", "A", "Work", "C"]), ("B", 99, ["A", "Work", "C", "B"]),
    ])
    func movesWithinAFolderCountingIndexBeforeTheMove(title: String, index: Int, expected: [String]) {
        var (library, _, _, _) = tree()
        let id = library.bookmarks.children[titles(library.bookmarks).firstIndex(of: title)!].id
        let moved = library.moveBookmark(id, into: library.bookmarks.id, at: index)
        #expect(moved)
        #expect(titles(library.bookmarks) == expected)
    }

    @Test func movesABookmarkOrAFolderWithItsContentsAcrossFolders() {
        var (library, work, deep, d) = tree()
        let root = library.bookmarks.id
        let aID = library.bookmarks.children[0].id
        let intoDeep = library.moveBookmark(aID, into: deep, at: 0)
        #expect(intoDeep)
        #expect(titles(library.folder(deep)) == ["A", "D"])
        let appended = library.moveBookmark(d.id, into: root, at: nil)
        #expect(appended)
        #expect(titles(library.bookmarks) == ["B", "Work", "C", "D"])
        let folderMoved = library.moveBookmark(deep, into: root, at: 0)
        #expect(folderMoved)
        #expect(titles(library.bookmarks) == ["Deep", "B", "Work", "C", "D"])
        #expect(titles(library.folder(deep)) == ["A"])
        #expect(library.folder(work)?.children.isEmpty == true)
    }

    @Test func refusesMovesThatWouldBreakTheTree() {
        var (library, work, deep, d) = tree()
        let root = library.bookmarks.id
        let pin = library.add(a, title: "Pin", to: .pins)
        let refused: [(UUID, UUID)] = [
            (work, work), (work, deep), (root, work), (pin.id, work), (UUID(), work), (d.id, UUID()), (d.id, d.id),
        ]
        let before = library
        for (id, folder) in refused {
            #expect(!library.canMoveBookmark(id, into: folder))
            let moved = library.moveBookmark(id, into: folder, at: nil)
            #expect(!moved)
        }
        #expect(library == before)
        #expect(library.canMoveBookmark(deep, into: root))
        #expect(library.canMoveBookmark(d.id, into: deep))
    }

    @Test func revealOpensEveryAncestorOfTheLinkOnly() {
        var (library, work, deep, d) = tree()
        let other = library.addFolder("Other", in: library.bookmarks.id)!.id
        library.reveal(d.id)
        #expect(library.folder(work)?.isExpanded == true)
        #expect(library.folder(deep)?.isExpanded == true)
        #expect(library.folder(other)?.isExpanded == false)
        library.setExpanded(work, false)
        #expect(library.folder(work)?.isExpanded == false)
        #expect(library.folder(deep)?.isExpanded == true)
    }

    @Test func parentOfNamesTheHoldingFolder() {
        let (library, work, deep, d) = tree()
        #expect(library.parent(of: d.id) == deep)
        #expect(library.parent(of: deep) == work)
        #expect(library.parent(of: work) == library.bookmarks.id)
        #expect(library.parent(of: library.bookmarks.id) == nil)
        #expect(library.parent(of: UUID()) == nil)
    }

    @Test func nodesCodeWithAKind() throws {
        let link = SavedLink(url: a, title: "A")
        let folder = BookmarkFolder(title: "F", isExpanded: true, children: [.link(link)])
        let data = try JSONEncoder().encode([BookmarkNode.link(link), .folder(folder)])
        let objects = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(Set(objects[0].keys) == ["kind", "id", "url", "title"])
        #expect(objects[0]["kind"] as? String == "link")
        #expect(Set(objects[1].keys) == ["kind", "id", "title", "isExpanded", "children"])
        #expect(objects[1]["kind"] as? String == "folder")
        let children = try #require(objects[1]["children"] as? [[String: Any]])
        #expect(children.first?["kind"] as? String == "link")
    }

    @Test func aTreeRoundTripsThroughJSON() throws {
        let root = tree().library.bookmarks
        let data = try JSONEncoder().encode(root)
        #expect(try JSONDecoder().decode(BookmarkFolder.self, from: data) == root)
    }

    @Test func aLinkIconRoundTripsAndMayBeMissing() throws {
        let link = SavedLink(url: a, title: "A", icon: Data([0x89, 0x50, 0x4E, 0x47]))
        let data = try JSONEncoder().encode(BookmarkNode.link(link))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["kind", "id", "url", "title", "icon"])
        #expect(try JSONDecoder().decode(BookmarkNode.self, from: data) == .link(link))
        let id = UUID()
        let old = Data(#"{"kind":"link","id":"\#(id.uuidString)","title":"A","url":"https://a.example"}"#.utf8)
        #expect(try JSONDecoder().decode(BookmarkNode.self, from: old) == .link(SavedLink(id: id, url: a, title: "A")))
    }

    @Test func setIconChangesANestedBookmarkOnly() {
        var (library, work, _, d) = tree()
        let icon = Data([1, 2, 3])
        library.setIcon(d.id, icon)
        #expect(library.links(on: .bookmarks).first { $0.id == d.id }?.icon == icon)
        #expect(library.links(on: .bookmarks).filter { $0.id != d.id }.allSatisfy { $0.icon == nil })
        let before = library
        library.setIcon(work, icon)
        library.setIcon(UUID(), icon)
        library.setIcon(library.bookmarks.id, icon)
        #expect(library == before)
        library.setIcon(d.id, nil)
        #expect(library.links(on: .bookmarks).allSatisfy { $0.icon == nil })
    }

    @Test func anUnknownKindFailsToDecode() {
        let json = Data(#"{"kind":"separator","id":"\#(UUID().uuidString)","title":"-"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(BookmarkNode.self, from: json) }
    }
}
