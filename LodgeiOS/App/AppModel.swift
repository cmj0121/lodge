import Foundation
import LodgeKit
import Observation
import WebKit
import os

/// The iPhone and iPad app's state: the workspaces in bar order, each one's tabs and selection, Default's pins (which
/// every workspace shows), and the settings kept with them. It reads and writes the same `SessionSnapshot` the Mac
/// app does, in the app's own Application Support/Lodge.
@MainActor
@Observable
final class AppModel {
    private static let logger = Logger(subsystem: "dev.lodge", category: "app")

    private(set) var workspaces = WorkspaceList()
    private(set) var activeID: UUID = Workspace.defaultID
    private(set) var tabs: [UUID: TabList] = [:]
    private(set) var selection: [UUID: TabID] = [:]
    /// Default's pins, shown and changed in every workspace (as on the Mac).
    private(set) var pins: [SavedLink] = []
    private(set) var search = SearchSettings()
    /// Each tab's load progress, 0…1; runtime only.
    private(set) var progress: [TabID: Double] = [:]
    /// Set when the address field asks for `lodge://settings`.
    var showsSettings = false

    /// Kept as read so a round trip through the iPhone and iPad app loses nothing it does not show yet.
    @ObservationIgnored private var bookmarks: [UUID: BookmarkFolder] = [:]
    @ObservationIgnored private var fingerprints: [UUID: FingerprintSettings] = [:]
    @ObservationIgnored private var pendingDeletions: [UUID] = []
    @ObservationIgnored private var rest: [UUID: TabRest] = [:]
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private(set) lazy var pool = WebViewPool(model: self)
    /// A tab's playing video kept in Picture in Picture while the tab is away.
    @ObservationIgnored private(set) lazy var pictureInPicture: PictureInPicture = {
        let controller = PictureInPicture(pool: pool) {
            UserDefaults.standard.object(forKey: VideoPopOut.settingKey) as? Bool ?? VideoPopOut.enabledByDefault
        }
        controller.onRestore = { [weak self] tab in self?.restorePictureInPicture(tab) }
        return controller
    }()
    @ObservationIgnored private var restTimer: Task<Void, Never>?

    init(session: SessionStore = SessionStore()) {
        self.session = session
        pool.pictureInPicture = pictureInPicture
        if let snapshot = session.load() { restore(snapshot) }
        finishPendingDeletions()
        startRestTimer()
    }

    // MARK: - Reading

    var active: Workspace { workspaces[activeID] ?? workspaces.default }

    var activeTabs: [BrowserTab] { tabs[activeID]?.tabs ?? [] }

    var selectedTab: BrowserTab? { selection[activeID].flatMap { tabs[activeID]?[$0] } }

    var catalog: SearchCatalog { search.catalog(for: active) }

    func tab(_ id: TabID) -> BrowserTab? {
        for list in tabs.values { if let tab = list[id] { return tab } }
        return nil
    }

    func workspaceID(of tab: TabID) -> UUID? {
        tabs.first { $0.value[tab] != nil }?.key
    }

    /// The open tab of `pin` in the workspace on screen, if any.
    func tab(for pin: SavedLink) -> BrowserTab? { tabs[activeID]?.tab(forLink: pin.id) }

    // MARK: - Workspaces

    func switchTo(_ id: UUID) {
        let id = workspaces.resolve(id)
        guard id != activeID else { return }
        let left = activeID
        if let tab = selection[left] { pictureInPicture.leaving(tab) }
        activeID = id
        stampShown()
        pool.releaseBackground(tabs[left]?.tabs.map(\.id) ?? []) { [weak self] in self?.activeID != left }
        save()
        if let tab = selection[id] { pictureInPicture.shown(tab) }
    }

    /// ⌃1–⌃9: 1 is Default, 2…9 the next workspaces in order; an empty slot does nothing.
    func switchTo(slot: Int) {
        if let workspace = workspaces.workspace(forSlot: slot) { switchTo(workspace.id) }
    }

    func createWorkspace(name: String, symbol: String, color: WorkspaceColor?, appearance: WorkspaceAppearance) throws(
        WorkspaceList.EditError
    ) {
        let workspace = try workspaces.create(name: name, symbol: symbol, color: color)
        try workspaces.setAppearance(workspace.id, appearance)
        fingerprints[workspace.id] = .fresh()
        switchTo(workspace.id)
        save()
    }

    func editWorkspace(
        _ id: UUID, name: String, symbol: String, color: WorkspaceColor?, appearance: WorkspaceAppearance
    ) throws(WorkspaceList.EditError) {
        var edited = workspaces
        if edited[id]?.kind == .custom { try edited.rename(id, to: name) }
        if id != Workspace.anonymousID {
            try edited.setSymbol(id, symbol)
            try edited.setColor(id, color)
        }
        try edited.setAppearance(id, appearance)
        workspaces = edited
        save()
    }

    /// Closes the workspace's tabs, forgets it and its settings, then removes its website data and files; one whose
    /// data cannot go yet is tried again at the next launch.
    func deleteWorkspace(_ id: UUID) {
        guard workspaces[id]?.kind == .custom else { return }
        if activeID == id { switchTo(Workspace.defaultID) }
        for tab in tabs[id]?.tabs ?? [] { pool.destroy(tab.id) }
        pool.forget(store: .workspace(id))
        _ = try? workspaces.remove(id)
        tabs[id] = nil
        selection[id] = nil
        rest[id] = nil
        bookmarks[id] = nil
        fingerprints[id] = nil
        search.drop(id)
        pendingDeletions.append(id)
        save()
        finishPendingDeletions()
    }

    private func finishPendingDeletions() {
        for id in pendingDeletions {
            Task { [weak self] in
                do {
                    try await WKWebsiteDataStore.remove(forIdentifier: id)
                } catch {
                    Self.logger.info("Website data of a deleted workspace stays for now: \(error.localizedDescription, privacy: .public)")
                }
                do {
                    try WorkspaceFiles.remove(id, in: try SessionStore.appDirectory())
                } catch {
                    Self.logger.error("Cannot remove a deleted workspace's files: \(error.localizedDescription, privacy: .public)")
                    return
                }
                self?.pendingDeletions.removeAll { $0 == id }
                self?.save()
            }
        }
    }

    func setAppearance(_ appearance: WorkspaceAppearance) {
        try? workspaces.setAppearance(activeID, appearance)
        save()
    }

    func chooseEngine(_ engineID: String?) {
        try? search.choose(engineID, for: active)
        save()
    }

    // MARK: - Tabs

    /// Opens a tab in the workspace on screen and selects it; `url` nil opens a blank one, focused on the address.
    @discardableResult
    func newTab(_ url: URL? = nil, link: UUID? = nil, title: String = "") -> TabID {
        let tab = BrowserTab(store: newTabStore(), url: url, title: title, link: link, isLive: false)
        tabs[activeID, default: TabList()].open(tab)
        select(tab.id)
        return tab.id
    }

    /// Default and custom workspaces share their own store; each Anonymous tab gets a browser of its own.
    private func newTabStore() -> StoreRef { active.store ?? .ephemeral(UUID()) }

    /// A popup or a link opened in a new window: a tab on its opener's store, so it stays signed in the same way,
    /// selected and already showing `view`.
    func openPopup(_ view: WKWebView, from opener: TabID) {
        guard let workspace = workspaceID(of: opener), let store = tab(opener)?.store else { return }
        let tab = BrowserTab(store: store, url: nil, isLive: true)
        tabs[workspace, default: TabList()].open(tab)
        pool.adopt(view, for: tab)
        if workspace == activeID { select(tab.id) }
        save()
    }

    func select(_ id: TabID) {
        guard tabs[activeID]?[id] != nil else { return }
        if let left = selection[activeID], left != id { pictureInPicture.leaving(left) }
        selection[activeID] = id
        stampShown()
        save()
        pictureInPicture.shown(id)
    }

    /// The user asked for the Picture in Picture video back: its workspace and tab come on screen.
    private func restorePictureInPicture(_ tab: TabID) {
        guard let workspace = workspaceID(of: tab) else { return }
        switchTo(workspace)
        select(tab)
    }

    func close(_ id: TabID) {
        guard let workspace = workspaceID(of: id), var list = tabs[workspace] else { return }
        let index = list.tabs.firstIndex { $0.id == id }
        let store = list[id]?.store
        pool.destroy(id)
        list.close(id)
        tabs[workspace] = list
        progress[id] = nil
        rest[workspace]?.forget(id)
        if let store, !list.tabs.contains(where: { $0.store == store }) { pool.forget(store: store) }
        if selection[workspace] == id {
            let next = index.map { min($0, list.tabs.count - 1) }.flatMap { $0 >= 0 ? list.tabs[$0].id : nil }
            selection[workspace] = next
            if workspace == activeID, let next { pictureInPicture.shown(next) }
        }
        stampShown()
        save()
    }

    /// Moves the tabs at `source` of `shown` (the list the user reordered) to just before the one at `destination`.
    func move(_ shown: [BrowserTab], fromOffsets source: IndexSet, toOffset destination: Int) {
        guard var list = tabs[activeID] else { return }
        let before = destination < shown.count ? shown[destination].id : nil
        for index in source.sorted() { list.move(shown[index].id, before: before) }
        tabs[activeID] = list
        save()
    }

    func update(_ id: TabID, _ change: (inout BrowserTab) -> Void) {
        guard let workspace = workspaceID(of: id) else { return }
        let before = tabs[workspace]?[id]
        tabs[workspace]?.update(id, change)
        let after = tabs[workspace]?[id]
        if before?.url != after?.url || before?.title != after?.title { save() }
    }

    func setProgress(_ value: Double, for id: TabID) { progress[id] = value }

    /// What the address field submits: a URL, or a search with the workspace's engine, loaded in the selected tab (a
    /// new one when there is none). `lodge://settings` opens Settings.
    func go(_ text: String) {
        guard let url = AddressInput.url(from: text, engine: catalog.engine) else { return }
        if let page = LodgePage(url: url) {
            if page == .settings { showsSettings = true }
            return
        }
        guard let tab = selectedTab else {
            newTab(url)
            return
        }
        update(tab.id) { $0.url = url }
        pool.load(url, in: tab.id)
    }

    // MARK: - Pins

    func openPin(_ pin: SavedLink) {
        if let tab = tab(for: pin) {
            select(tab.id)
        } else {
            newTab(pin.url, link: pin.id, title: pin.title)
        }
    }

    /// Pin `slot` (1-based) of Default's pins; nil past the last.
    func pin(slot: Int) -> SavedLink? {
        pins.indices.contains(slot - 1) ? pins[slot - 1] : nil
    }

    /// ⌘1–⌘9: selects pin `slot`'s open tab in the workspace on screen or opens it, as a tap on it does; an empty
    /// slot does nothing.
    func openPin(slot: Int) {
        if let pin = pin(slot: slot) { openPin(pin) }
    }

    func canPin(_ tab: BrowserTab) -> Bool {
        guard let url = tab.url, Origin.isWeb(url) else { return false }
        return !pins.contains { $0.url == url }
    }

    func pin(_ id: TabID) {
        guard let tab = tab(id), let url = tab.url, canPin(tab) else { return }
        let link = SavedLink(url: url, title: tab.displayTitle)
        pins.append(link)
        update(id) { $0.link = link.id }
        save()
    }

    func unpin(_ link: UUID) {
        pins.removeAll { $0.id == link }
        for workspace in tabs.keys {
            for tab in tabs[workspace]?.tabs ?? [] where tab.link == link {
                tabs[workspace]?.update(tab.id) { $0.link = nil }
            }
        }
        save()
    }

    func movePins(fromOffsets source: IndexSet, toOffset destination: Int) {
        pins.move(fromOffsets: source, toOffset: destination)
        save()
    }

    // MARK: - Memory

    /// The system asks for memory back: every tab off screen, in any workspace, gives up its web view.
    func didReceiveMemoryWarning() {
        let shown = Set(selection[activeID].map { [$0] } ?? [])
        let order = TabRest.oldestFirst(
            workspaces.workspaces.map { (rest[$0.id] ?? TabRest(), pool.liveTabs(in: tabs[$0.id]?.tabs ?? [])) },
            shown: shown)
        for tab in order { pool.release(tab) }
    }

    /// Settings › "Rest tabs after", as on the Mac: a tab off screen that long gives up its web view.
    private func startRestTimer() {
        restTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.restDueTabs()
            }
        }
    }

    private func restDueTabs() {
        guard let after = RestAfter.load(from: .standard).interval else { return }
        let now = ContinuousClock.now
        for workspace in workspaces.workspaces {
            let live = pool.liveTabs(in: tabs[workspace.id]?.tabs ?? [])
            for tab in rest[workspace.id]?.due(live, after: after, now: now) ?? [] { pool.release(tab) }
        }
    }

    private func stampShown() {
        let shown: Set<TabID> = selection[activeID].map { [$0] } ?? []
        let live = pool.liveTabs(in: activeTabs)
        rest[activeID, default: TabRest()].update(shown: shown, live: live, now: .now)
    }

    // MARK: - Session

    private func restore(_ snapshot: SessionSnapshot) {
        workspaces = snapshot.workspaceList
        var searches: [UUID: WorkspaceSearch] = [:]
        for entry in snapshot.workspaces {
            let id = entry.workspace.id
            let restored = entry.content.restored(store: entry.workspace.store)
            tabs[id] = restored.tabs
            selection[id] = restored.selectedTab
            bookmarks[id] = restored.library.bookmarks
            fingerprints[id] = entry.fingerprint
            searches[id] = entry.content.search
            if entry.workspace.kind == .default { pins = restored.library.links(on: .pins) }
        }
        search = SearchSettings(searches)
        let window = snapshot.windows[0]
        activeID = workspaces.resolve(window.activeWorkspace)
        if let selected = window.selectedTab, tabs[activeID]?[selected] != nil { selection[activeID] = selected }
        pendingDeletions = snapshot.pendingDeletions
    }

    func snapshot() -> SessionSnapshot {
        let entries = workspaces.workspaces.map { workspace in
            let library = LinkLibrary(
                pins: workspace.kind == .default ? pins : [],
                bookmarks: bookmarks[workspace.id] ?? LinkLibrary().bookmarks)
            let content = SessionSnapshot.WorkspaceContent(
                tabs: tabs[workspace.id] ?? TabList(), library: library, selectedTab: selection[workspace.id],
                search: search[workspace.id])
            return SessionSnapshot.WorkspaceSnapshot(
                workspace: workspace, content: content, fingerprint: fingerprints[workspace.id])
        }
        return SessionSnapshot(
            workspaces: entries,
            windows: [SessionSnapshot.WindowSnapshot(activeWorkspace: activeID, selectedTab: selection[activeID])],
            pendingDeletions: pendingDeletions)
    }

    private func save() { session.schedule(snapshot()) }

    /// The app goes to the background: write now, since it may not come back.
    func flush() { session.writeNow(snapshot()) }
}
