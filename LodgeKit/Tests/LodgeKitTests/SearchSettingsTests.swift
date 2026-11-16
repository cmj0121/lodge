import Foundation
import Testing

@testable import LodgeKit

@Suite struct SearchEngineTests {
    @Test func builtInsAreTheSixInOrder() {
        #expect(SearchEngine.builtIns.map(\.id) == ["duckduckgo", "google", "bing", "kagi", "brave", "startpage"])
        #expect(SearchEngine.builtIns.map(\.name) == ["DuckDuckGo", "Google", "Bing", "Kagi", "Brave", "Startpage"])
        #expect(SearchEngine.builtIns.map(\.template) == [
            "https://duckduckgo.com/?q=%s", "https://www.google.com/search?q=%s", "https://www.bing.com/search?q=%s",
            "https://kagi.com/search?q=%s", "https://search.brave.com/search?q=%s",
            "https://www.startpage.com/sp/search?query=%s",
        ])
        #expect(SearchEngine.builtIns.first == .duckDuckGo)
        #expect(SearchEngine.builtIns.allSatisfy { $0.isBuiltIn })
        #expect(!SearchEngine(id: UUID().uuidString, name: "Mine", template: "https://x.example/?q=%s").isBuiltIn)
    }

    @Test func urlFillsEveryPlaceholderWithTheEncodedQuery() {
        let engine = SearchEngine(id: "x", name: "X", template: "https://x.example/s?q=%s&again=%s")
        #expect(engine.url(for: "a&b c")?.absoluteString == "https://x.example/s?q=a%26b%20c&again=a%26b%20c")
        #expect(SearchEngine.builtIns[1].url(for: "swift 6")?.absoluteString == "https://www.google.com/search?q=swift%206")
    }

    @Test func validateTrimsAndRefuses() throws {
        let ok = try SearchEngine.validate(name: "  Mine ", template: " https://x.example/?q=%s ").get()
        #expect(ok.name == "Mine")
        #expect(ok.template == "https://x.example/?q=%s")
        func refusal(_ name: String, _ template: String) -> SearchEngine.EditError? {
            if case .failure(let error) = SearchEngine.validate(name: name, template: template) { error } else { nil }
        }
        #expect(refusal(" ", "https://x.example/?q=%s") == .emptyName)
        #expect(refusal("X", "https://x.example/") == .missingPlaceholder)
        #expect(refusal("X", "ftp://x.example/%s") == .unsupportedScheme)
        #expect(refusal("X", "javascript:%s") == .unsupportedScheme)
        #expect(refusal("X", "%s") == .invalidAddress)
        #expect(refusal("X", "https:///?q=%s") == .invalidAddress)
    }

    @Test func addressInputSearchesWithTheGivenEngine() {
        let bing = SearchEngine.builtIns[2]
        #expect(AddressInput.url(from: " lodge search ", engine: bing)?.absoluteString
            == "https://www.bing.com/search?q=lodge%20search")
        #expect(AddressInput.url(from: "example.com", engine: bing)?.absoluteString == "https://example.com")
        #expect(AddressInput.url(from: "lodge search")?.absoluteString == "https://duckduckgo.com/?q=lodge%20search")
    }
}

@Suite struct SearchSettingsTests {
    private let work = Workspace(name: "Work", symbol: "briefcase")
    private static let google = SearchEngine.builtIns[1]
    private static let kagi = SearchEngine.builtIns[3]

    @Test func everyWorkspaceStartsOnDuckDuckGoAndCustomFollowsDefault() {
        let settings = SearchSettings()
        let defaults = settings.catalog(for: .default)
        #expect(defaults.engine == .duckDuckGo)
        #expect(defaults.available == SearchEngine.builtIns)
        #expect(!defaults.followsDefault)
        let custom = settings.catalog(for: work)
        #expect(custom.engine == .duckDuckGo)
        #expect(custom.followsDefault)
        #expect(custom.choice == nil)
        let anonymous = settings.catalog(for: .anonymous)
        #expect(anonymous.engine == .duckDuckGo)
        #expect(!anonymous.followsDefault)
    }

    @Test func followDefaultKeepsUpWithALaterDefaultChange() throws {
        var settings = SearchSettings()
        try settings.choose(Self.google.id, for: .default)
        #expect(settings.catalog(for: work).engine == Self.google)
        #expect(settings.catalog(for: work).followsDefault)
        try settings.choose(Self.kagi.id, for: .default)
        #expect(settings.catalog(for: work).engine == Self.kagi)
    }

    @Test func pickingAnEngineOverridesDefaultUntilFollowingAgain() throws {
        var settings = SearchSettings()
        try settings.choose(Self.google.id, for: .default)
        try settings.choose(Self.kagi.id, for: work)
        #expect(settings.catalog(for: work).engine == Self.kagi)
        #expect(!settings.catalog(for: work).followsDefault)
        try settings.choose(nil, for: work)
        #expect(settings.catalog(for: work).engine == Self.google)
        #expect(settings[work.id] == .empty)
    }

    @Test func anonymousIgnoresDefaultAndCanPickABuiltIn() throws {
        var settings = SearchSettings()
        try settings.choose(Self.google.id, for: .default)
        #expect(settings.catalog(for: .anonymous).engine == .duckDuckGo)
        try settings.choose(Self.kagi.id, for: .anonymous)
        #expect(settings.catalog(for: .anonymous).engine == Self.kagi)
        try settings.choose(nil, for: .anonymous)
        #expect(settings.catalog(for: .anonymous).engine == .duckDuckGo)
    }

    @Test func choosingAnUnknownEngineThrowsAndChangesNothing() {
        var settings = SearchSettings()
        #expect(throws: SearchEngine.EditError.unknown("nope")) { try settings.choose("nope", for: work) }
        #expect(settings == SearchSettings())
    }

    @Test func unresolvableChoiceFallsBackAtResolutionAndIsKept() {
        let settings = SearchSettings([
            Workspace.defaultID: WorkspaceSearch(choice: Self.google.id),
            work.id: WorkspaceSearch(choice: "gone"),
            Workspace.anonymousID: WorkspaceSearch(choice: "gone"),
        ])
        #expect(settings.catalog(for: work).engine == Self.google)
        #expect(settings.catalog(for: work).choice == "gone")
        #expect(!settings.catalog(for: work).followsDefault)
        #expect(settings.catalog(for: .anonymous).engine == .duckDuckGo)
        #expect(settings[work.id].choice == "gone")
        let lostDefault = SearchSettings([Workspace.defaultID: WorkspaceSearch(choice: "gone")])
        #expect(lostDefault.catalog(for: .default).engine == .duckDuckGo)
        #expect(lostDefault.catalog(for: work).engine == .duckDuckGo)
        #expect(lostDefault.catalog(for: .default).choice == "gone")
    }

    @Test func availableListsDefaultsEnginesThenTheWorkspacesOwn() {
        let shared = SearchEngine(id: "shared", name: "Shared", template: "https://shared.example/?q=%s")
        let own = SearchEngine(id: "own", name: "Own", template: "https://own.example/?q=%s")
        let settings = SearchSettings([
            Workspace.defaultID: WorkspaceSearch(engines: [shared]), work.id: WorkspaceSearch(engines: [own]),
        ])
        #expect(settings.catalog(for: .default).available == SearchEngine.builtIns + [shared])
        #expect(settings.catalog(for: work).available == SearchEngine.builtIns + [shared, own])
        #expect(settings.catalog(for: .anonymous).available == SearchEngine.builtIns + [shared])
    }

    @Test func dropForgetsTheWorkspacesChoice() throws {
        var settings = SearchSettings()
        try settings.choose(Self.kagi.id, for: work)
        settings.drop(work.id)
        #expect(settings[work.id] == .empty)
        #expect(settings.catalog(for: work).followsDefault)
    }
}

@Suite struct SearchPersistenceTests {
    private let work = Workspace(name: "Work", symbol: "briefcase")
    private static let google = SearchEngine.builtIns[1]
    private static let kagi = SearchEngine.builtIns[3]

    private func snapshot(_ searches: [UUID: WorkspaceSearch], workspaces: [Workspace]) -> SessionSnapshot {
        SessionSnapshot(
            workspaces: workspaces.map {
                .init(
                    workspace: $0,
                    content: .init(tabs: TabList(), library: LinkLibrary(), selectedTab: nil, search: searches[$0.id] ?? .empty))
            },
            windows: [.init(activeWorkspace: Workspace.defaultID)], pendingDeletions: [])
    }

    private func settings(of snapshot: SessionSnapshot) -> SearchSettings {
        SearchSettings(Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.workspace.id, $0.content.search) }))
    }

    @Test func choicesRoundTripIncludingAnonymous() throws {
        let original = snapshot(
            [
                Workspace.defaultID: WorkspaceSearch(choice: Self.google.id),
                work.id: WorkspaceSearch(choice: Self.kagi.id),
                Workspace.anonymousID: WorkspaceSearch(choice: Self.kagi.id),
            ], workspaces: [.default, work, .anonymous])
        let decoded = try SessionSnapshot.decode(original.encoded())
        #expect(decoded == original)
        let restored = settings(of: decoded)
        #expect(restored.catalog(for: .default).engine == Self.google)
        #expect(restored.catalog(for: work).engine == Self.kagi)
        #expect(restored.catalog(for: .anonymous).engine == Self.kagi)
    }

    @Test func anonymizedKeepsSearchAndBookmarksOnly() {
        let tab = BrowserTab(url: URL(string: "https://duckduckgo.com/?q=secret")!, title: "secret")
        let content = SessionSnapshot.WorkspaceContent(
            tabs: TabList(tabs: [tab]), library: LinkLibrary(), selectedTab: tab.id,
            search: WorkspaceSearch(choice: Self.kagi.id))
        let anonymized = content.anonymized()
        #expect(anonymized.search == WorkspaceSearch(choice: Self.kagi.id))
        #expect(anonymized.tabs.isEmpty)
        #expect(anonymized.selectedTab == nil)
    }

    @Test func anonymousSessionHoldsTheChoiceButNoWords() throws {
        let tab = BrowserTab(url: URL(string: "https://kagi.com/search?q=secretwords")!, title: "secretwords")
        let original = SessionSnapshot(
            workspaces: [
                .init(workspace: .default, content: .empty),
                .init(
                    workspace: .anonymous,
                    content: .init(
                        tabs: TabList(tabs: [tab]), library: LinkLibrary(), selectedTab: tab.id,
                        search: WorkspaceSearch(choice: Self.kagi.id))),
            ],
            windows: [.init(activeWorkspace: Workspace.defaultID)], pendingDeletions: [])
        let text = String(decoding: try original.encoded(), as: UTF8.self)
        #expect(!text.contains("secretwords"))
        #expect(settings(of: try SessionSnapshot.decode(Data(text.utf8))).catalog(for: .anonymous).engine == Self.kagi)
    }

    @Test func emptySearchIsLeftOutOfTheFile() throws {
        let text = String(decoding: try snapshot([:], workspaces: [.default, work]).encoded(), as: UTF8.self)
        #expect(!text.contains("\"search\""))
        #expect(SessionSnapshot.currentVersion == 4)
    }

    /// A v4 file written before search settings existed.
    private static let searchless = """
        {
          "pendingDeletions" : [],
          "version" : 4,
          "windows" : [{ "activeWorkspace" : "00000000-0000-0000-0000-000000000000" }],
          "workspaces" : [
            {
              "content" : {
                "bookmarks" : { "children" : [], "id" : "F0000000-0000-0000-0000-000000000001", "isExpanded" : true, "title" : "Bookmarks" },
                "pins" : [],
                "tabs" : []
              },
              "workspace" : { "id" : "00000000-0000-0000-0000-000000000000", "kind" : "default", "name" : "Default", "symbol" : "square.stack.3d.up" }
            },
            {
              "content" : {
                "bookmarks" : { "children" : [], "id" : "F0000000-0000-0000-0000-000000000002", "isExpanded" : true, "title" : "Bookmarks" },
                "pins" : [],
                "search" : { "choice" : 42 },
                "tabs" : []
              },
              "workspace" : { "id" : "D0000000-0000-0000-0000-000000000001", "kind" : "custom", "name" : "Work", "symbol" : "briefcase" }
            }
          ]
        }
        """

    @Test func anOlderFileSearchesWithDuckDuckGoAndAMalformedSearchReadsAsEmpty() throws {
        let decoded = try SessionSnapshot.decode(Data(Self.searchless.utf8))
        let workID = UUID(uuidString: "D0000000-0000-0000-0000-000000000001")!
        #expect(decoded.workspaces.allSatisfy { $0.content.search == .empty })
        let restored = settings(of: decoded)
        #expect(restored.catalog(for: .default).engine == .duckDuckGo)
        let work = try #require(decoded.workspaceList[workID])
        #expect(restored.catalog(for: work).engine == .duckDuckGo)
        #expect(restored.catalog(for: work).followsDefault)
        #expect(restored.catalog(for: .anonymous).engine == .duckDuckGo)
    }

    @Test func unresolvableChoiceIsKeptAcrossRelaunch() throws {
        let original = snapshot(
            [Workspace.defaultID: WorkspaceSearch(choice: Self.google.id), work.id: WorkspaceSearch(choice: "removed")],
            workspaces: [.default, work])
        let decoded = try SessionSnapshot.decode(original.encoded())
        let restored = settings(of: decoded)
        #expect(restored.catalog(for: work).engine == Self.google)
        #expect(restored[work.id].choice == "removed")
        let again = try SessionSnapshot.decode(decoded.encoded())
        #expect(again.content(of: work.id)?.search.choice == "removed")
    }

    @Test func aDeletedWorkspaceLosesItsChoice() throws {
        let original = snapshot([work.id: WorkspaceSearch(choice: Self.kagi.id)], workspaces: [.default, work])
        var restored = settings(of: original)
        restored.drop(work.id)
        #expect(restored[work.id] == .empty)
        let pending = SessionSnapshot(
            workspaces: original.workspaces, windows: original.windows, pendingDeletions: [work.id])
        #expect(pending.content(of: work.id) == nil)
    }
}

@Suite struct CustomEngineTests {
    private let work = Workspace(name: "Work", symbol: "briefcase")
    private let play = Workspace(name: "Play", symbol: "gamecontroller")
    private static let kagi = SearchEngine.builtIns[3]
    private static let template = "https://example.com/search?q=%s"

    @Test func addRenameEditAndRemove() throws {
        var settings = SearchSettings()
        let added = try settings.add(name: " Example ", template: " \(Self.template) ", to: work.id)
        #expect(added.name == "Example")
        #expect(added.template == Self.template)
        #expect(UUID(uuidString: added.id) != nil)
        #expect(!added.isBuiltIn)
        #expect(settings[work.id].engines == [added])
        try settings.choose(added.id, for: work)
        try settings.update(added.id, name: "Renamed", template: "https://other.example/?s=%s", in: work.id)
        let edited = try #require(settings[work.id].engines.first)
        #expect(edited.id == added.id)
        #expect(edited.name == "Renamed")
        #expect(edited.template == "https://other.example/?s=%s")
        #expect(settings.catalog(for: work).engine == edited)
        try settings.remove(added.id, from: work.id)
        #expect(settings[work.id].engines.isEmpty)
        #expect(settings[work.id].choice == added.id)
    }

    @Test func refusedEditsChangeNothing() throws {
        var settings = SearchSettings()
        let added = try settings.add(name: "Example", template: Self.template, to: Workspace.defaultID)
        let before = settings
        #expect(throws: SearchEngine.EditError.missingPlaceholder) {
            try settings.add(name: "X", template: "https://x.example/", to: work.id)
        }
        #expect(throws: SearchEngine.EditError.unsupportedScheme) {
            try settings.update(added.id, name: "X", template: "ftp://x.example/%s", in: Workspace.defaultID)
        }
        #expect(throws: SearchEngine.EditError.emptyName) {
            try settings.update(added.id, name: "  ", template: Self.template, in: Workspace.defaultID)
        }
        #expect(throws: SearchEngine.EditError.unknown(added.id)) {
            try settings.update(added.id, name: "X", template: Self.template, in: work.id)
        }
        #expect(throws: SearchEngine.EditError.unknown(added.id)) { try settings.remove(added.id, from: work.id) }
        #expect(throws: SearchEngine.EditError.unknown("nope")) {
            try settings.remove("nope", from: Workspace.defaultID)
        }
        #expect(settings == before)
    }

    @Test func builtInsCannotBeEditedOrRemoved() {
        var settings = SearchSettings()
        for engine in SearchEngine.builtIns {
            #expect(throws: SearchEngine.EditError.builtInIsFixed) {
                try settings.remove(engine.id, from: Workspace.defaultID)
            }
            #expect(throws: SearchEngine.EditError.builtInIsFixed) {
                try settings.update(engine.id, name: "X", template: Self.template, in: work.id)
            }
        }
        #expect(settings == SearchSettings())
        #expect(settings.catalog(for: .default).available == SearchEngine.builtIns)
    }

    @Test func defaultsEnginesAreEverywhereAndOwnEnginesStayHome() throws {
        var settings = SearchSettings()
        let shared = try settings.add(name: "Shared", template: Self.template, to: Workspace.defaultID)
        let own = try settings.add(name: "Own", template: "https://own.example/?q=%s", to: work.id)
        let hidden = try settings.add(
            name: "Hidden", template: "https://hidden.example/?q=%s", to: Workspace.anonymousID)
        #expect(settings.catalog(for: .default).available == SearchEngine.builtIns + [shared])
        #expect(settings.catalog(for: work).available == SearchEngine.builtIns + [shared, own])
        #expect(settings.catalog(for: play).available == SearchEngine.builtIns + [shared])
        #expect(settings.catalog(for: .anonymous).available == SearchEngine.builtIns + [shared, hidden])
        try settings.choose(shared.id, for: .anonymous)
        #expect(settings.catalog(for: .anonymous).engine == shared)
        #expect(throws: SearchEngine.EditError.unknown(own.id)) { try settings.choose(own.id, for: play) }
        #expect(throws: SearchEngine.EditError.unknown(hidden.id)) { try settings.choose(hidden.id, for: .default) }
    }

    @Test func anAddedEngineAsDefaultSearchesWithTheWordsInPlaceOfThePlaceholder() throws {
        var settings = SearchSettings()
        let added = try settings.add(name: "Example", template: Self.template, to: Workspace.defaultID)
        try settings.choose(added.id, for: .default)
        #expect(settings.catalog(for: work).engine == added)
        #expect(settings.catalog(for: work).followsDefault)
        let engine = settings.catalog(for: work).engine
        #expect(AddressInput.url(from: "lodge browser", engine: engine)?.absoluteString
            == "https://example.com/search?q=lodge%20browser")
    }

    @Test func removalFallsBackPerWorkspaceKindAndKeepsTheStoredChoice() throws {
        var settings = SearchSettings()
        let shared = try settings.add(name: "Shared", template: Self.template, to: Workspace.defaultID)
        let own = try settings.add(name: "Own", template: "https://own.example/?q=%s", to: work.id)
        try settings.choose(Self.kagi.id, for: .default)
        try settings.choose(own.id, for: work)
        try settings.choose(shared.id, for: play)
        try settings.choose(shared.id, for: .anonymous)
        try settings.remove(own.id, from: work.id)
        let workCatalog = settings.catalog(for: work)
        #expect(workCatalog.engine == Self.kagi)
        #expect(workCatalog.choice == own.id)
        #expect(!workCatalog.followsDefault)
        #expect(!workCatalog.available.contains { $0.id == own.id })
        try settings.choose(shared.id, for: .default)
        try settings.remove(shared.id, from: Workspace.defaultID)
        #expect(settings.catalog(for: .default).engine == .duckDuckGo)
        #expect(settings.catalog(for: .default).choice == shared.id)
        #expect(settings.catalog(for: play).engine == .duckDuckGo)
        #expect(settings.catalog(for: play).choice == shared.id)
        #expect(settings.catalog(for: .anonymous).engine == .duckDuckGo)
        #expect(settings[Workspace.anonymousID].choice == shared.id)
        #expect(settings[work.id].choice == own.id)
    }

    @Test func aCustomWorkspaceFallsBackToDefaultsEngineAfterRemoval() throws {
        var settings = SearchSettings()
        let shared = try settings.add(name: "Shared", template: Self.template, to: Workspace.defaultID)
        try settings.choose(Self.kagi.id, for: .default)
        try settings.choose(shared.id, for: play)
        try settings.remove(shared.id, from: Workspace.defaultID)
        #expect(settings.catalog(for: play).engine == Self.kagi)
        #expect(settings.catalog(for: play).choice == shared.id)
    }

    @Test func dependentsAreTheOtherWorkspacesChoosingADefaultEngine() throws {
        var settings = SearchSettings()
        let shared = try settings.add(name: "Shared", template: Self.template, to: Workspace.defaultID)
        let own = try settings.add(name: "Own", template: "https://own.example/?q=%s", to: work.id)
        #expect(settings.dependents(of: shared.id).isEmpty)
        try settings.choose(shared.id, for: .default)
        try settings.choose(shared.id, for: play)
        try settings.choose(shared.id, for: .anonymous)
        try settings.choose(own.id, for: work)
        #expect(Set(settings.dependents(of: shared.id)) == [play.id, Workspace.anonymousID])
        #expect(settings.dependents(of: shared.id).count == 2)
        #expect(settings.dependents(of: own.id).isEmpty)
        #expect(settings.dependents(of: Self.kagi.id).isEmpty)
    }

    @Test func dropForgetsTheWorkspacesEngines() throws {
        var settings = SearchSettings()
        try settings.add(name: "Own", template: Self.template, to: work.id)
        settings.drop(work.id)
        #expect(settings[work.id] == .empty)
        #expect(settings.catalog(for: work).available == SearchEngine.builtIns)
    }

    @Test func everyRefusalHasItsOwnMessage() {
        let errors: [SearchEngine.EditError] = [
            .emptyName, .missingPlaceholder, .unsupportedScheme, .invalidAddress, .builtInIsFixed, .unknown("x"),
        ]
        let messages = errors.map(\.message)
        #expect(Set(messages).count == errors.count)
        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(SearchEngine.EditError.missingPlaceholder.message.contains("%s"))
    }
}

@Suite struct CustomEnginePersistenceTests {
    private let work = Workspace(name: "Work", symbol: "briefcase")
    private static let template = "https://example.com/search?q=%s"

    @Test func anonymousEnginesAndChoiceSurviveWhileItsTabsDoNot() throws {
        var settings = SearchSettings()
        let added = try settings.add(name: "Mine", template: Self.template, to: Workspace.anonymousID)
        try settings.choose(added.id, for: .anonymous)
        let tab = BrowserTab(url: URL(string: "https://example.com/search?q=secretwords")!, title: "secretwords")
        let original = SessionSnapshot(
            workspaces: [
                .init(workspace: .default, content: .empty),
                .init(
                    workspace: .anonymous,
                    content: .init(
                        tabs: TabList(tabs: [tab]), library: LinkLibrary(), selectedTab: tab.id,
                        search: settings[Workspace.anonymousID])),
            ],
            windows: [.init(activeWorkspace: Workspace.defaultID)], pendingDeletions: [])
        let text = String(decoding: try original.encoded(), as: UTF8.self)
        #expect(!text.contains("secretwords"))
        let decoded = try SessionSnapshot.decode(Data(text.utf8))
        let anonymous = try #require(decoded.content(of: Workspace.anonymousID))
        #expect(anonymous.tabs.isEmpty)
        #expect(anonymous.search == WorkspaceSearch(engines: [added], choice: added.id))
        let restored = SearchSettings([Workspace.anonymousID: anonymous.search])
        #expect(restored.catalog(for: .anonymous).engine == added)
    }

    @Test func addedEnginesAndARemovedChoiceRoundTrip() throws {
        var settings = SearchSettings()
        let shared = try settings.add(name: "Shared", template: Self.template, to: Workspace.defaultID)
        let own = try settings.add(name: "Own", template: "https://own.example/?q=%s", to: work.id)
        try settings.choose(shared.id, for: work)
        try settings.remove(shared.id, from: Workspace.defaultID)
        let original = SessionSnapshot(
            workspaces: [Workspace.default, work].map {
                .init(
                    workspace: $0,
                    content: .init(tabs: TabList(), library: LinkLibrary(), selectedTab: nil, search: settings[$0.id]))
            },
            windows: [.init(activeWorkspace: Workspace.defaultID)], pendingDeletions: [])
        let decoded = try SessionSnapshot.decode(original.encoded())
        let restored = SearchSettings(
            Dictionary(uniqueKeysWithValues: decoded.workspaces.map { ($0.workspace.id, $0.content.search) }))
        #expect(restored == settings)
        #expect(restored.catalog(for: work).available == SearchEngine.builtIns + [own])
        #expect(restored.catalog(for: work).engine == .duckDuckGo)
        #expect(restored.catalog(for: work).choice == shared.id)
    }

    /// A v4 file from a build that knew built-in choices only, its custom workspace naming an engine it never had.
    private static let older = """
        {
          "pendingDeletions" : [],
          "version" : 4,
          "windows" : [{ "activeWorkspace" : "00000000-0000-0000-0000-000000000000" }],
          "workspaces" : [
            {
              "content" : {
                "bookmarks" : { "children" : [], "id" : "F0000000-0000-0000-0000-000000000001", "isExpanded" : true, "title" : "Bookmarks" },
                "pins" : [],
                "search" : { "choice" : "kagi" },
                "tabs" : []
              },
              "workspace" : { "id" : "00000000-0000-0000-0000-000000000000", "kind" : "default", "name" : "Default", "symbol" : "square.stack.3d.up" }
            },
            {
              "content" : {
                "bookmarks" : { "children" : [], "id" : "F0000000-0000-0000-0000-000000000002", "isExpanded" : true, "title" : "Bookmarks" },
                "pins" : [],
                "search" : { "choice" : "5A1C0000-0000-0000-0000-00000000BEEF" },
                "tabs" : []
              },
              "workspace" : { "id" : "D0000000-0000-0000-0000-000000000001", "kind" : "custom", "name" : "Work", "symbol" : "briefcase" }
            }
          ]
        }
        """

    @Test func anOlderFileWithAnUnknownChoiceFallsBackAndAcceptsNewEngines() throws {
        let decoded = try SessionSnapshot.decode(Data(Self.older.utf8))
        var settings = SearchSettings(
            Dictionary(uniqueKeysWithValues: decoded.workspaces.map { ($0.workspace.id, $0.content.search) }))
        let work = try #require(decoded.workspaceList[UUID(uuidString: "D0000000-0000-0000-0000-000000000001")!])
        #expect(settings[work.id].engines.isEmpty)
        #expect(settings.catalog(for: work).engine == SearchEngine.builtIns[3])
        #expect(settings.catalog(for: work).choice == "5A1C0000-0000-0000-0000-00000000BEEF")
        let added = try settings.add(name: "Mine", template: Self.template, to: work.id)
        try settings.choose(added.id, for: work)
        #expect(settings.catalog(for: work).engine == added)
    }
}
