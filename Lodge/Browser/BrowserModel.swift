import AppKit
import LodgeKit
import Observation
import WebKit

/// State and actions of the browser window: the saved links, the open tabs and their web views, find in page.
@MainActor
@Observable
final class BrowserModel {
    /// Every open tab. A tab keeps its web view, built when it is first selected, until it closes.
    private(set) var tabs = TabList() {
        didSet { didChangeSession() }
    }
    private(set) var library: LinkLibrary {
        didSet { didChangeSession() }
    }
    /// The sidebar's entries, each link paired with its open tab, rebuilt only when `tabs` or
    /// `library` change.
    private(set) var sidebar = SidebarSections()
    /// Load progress per tab, kept apart from `tabs` so progress ticks redraw only the progress line.
    private(set) var loadProgress: [TabID: Double] = [:]
    /// Each page's security, kept apart from `tabs` like progress; gone with the tab.
    private(set) var security: [TabID: SiteSecurity] = [:]
    /// Each tab's page zoom; absent means `PageZoom.actual`. Gone with the tab.
    private(set) var zoom: [TabID: Double] = [:]
    var findText = ""
    var isFindVisible = false
    private(set) var findMissed = false
    /// The sidebar's Downloads popover is open.
    var isDownloadsVisible = false
    /// The keyboard shortcut help overlay is open.
    var isShortcutHelpVisible = false
    /// Each tab's decoded favicon, kept apart from `tabs` so an icon arriving redraws only its icon.
    private(set) var favicons: [TabID: NSImage] = [:]
    /// Bumped to ask the window to focus the address bar or the find field.
    private(set) var addressFocusRequest = 0
    private(set) var findFocusRequest = 0
    /// The text the last search ran for, so the typing debounce does not search it again.
    @ObservationIgnored private var lastSearchedText = ""

    @ObservationIgnored let registry = WebViewRegistry()
    @ObservationIgnored private var controllers: [TabID: TabController] = [:]
    /// Restored tabs whose web view is not built yet; the load that builds one is not a visit.
    @ObservationIgnored private var restoredTabs: Set<TabID> = []
    /// Where tabs on the default store record their visits; nil until the history store opens, and in layout
    /// renders. The store opens after the restored tab may have committed, so the recorder arrives knowing every
    /// default-store tab's page as already seen, and a restored page's load finishing records nothing.
    @ObservationIgnored var historyRecorder: HistoryRecorder? {
        didSet {
            guard oldValue == nil, let historyRecorder else { return }
            for tab in tabs.tabs where tab.store == .global {
                if let url = tab.url { historyRecorder.send(.seen(tab: tab.id, url: url)) }
            }
        }
    }

    /// Runs the tabs' downloads; nil in layout renders, where a download does not run.
    @ObservationIgnored var downloads: DownloadManager?

    /// Called with the new snapshot whenever the tabs or the library change in a way it stores.
    @ObservationIgnored var onSnapshotChange: ((SessionSnapshot) -> Void)?
    /// The snapshot last handed to `onSnapshotChange`, so changes it does not store (loading, history
    /// buttons) do not call it.
    @ObservationIgnored private var lastSnapshot: SessionSnapshot?

    /// Starts from `snapshot`, building only its selected tab's web view; the other tabs build theirs when
    /// first selected. Without one, starts with `defaultLibrary`. Either way an empty window gets a blank tab.
    init(restoring snapshot: SessionSnapshot? = nil, defaultLibrary: LinkLibrary = LinkLibrary()) {
        if let snapshot {
            let restored = snapshot.restored()
            library = restored.library
            tabs = restored.tabs
            restoredTabs = Set(restored.tabs.tabs.map(\.id))
        } else {
            library = defaultLibrary
        }
        refreshSidebar()
        if tabs.tabs.isEmpty {
            open(BrowserTab(), load: false)
        } else if let selected = tabs.selectedID {
            ensureView(for: selected)
        }
        lastSnapshot = self.snapshot
    }

    var selected: BrowserTab? { tabs.selected }

    /// The selected page's security; `.none` with no tab selected.
    var selectedSecurity: SiteSecurity { tabs.selectedID.flatMap { security[$0] } ?? .none }

    /// What the session store keeps of the window.
    var snapshot: SessionSnapshot { SessionSnapshot(tabs: tabs, library: library) }

    private func didChangeSession() {
        refreshSidebar()
        let snapshot = self.snapshot
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        onSnapshotChange?(snapshot)
    }

    private func refreshSidebar() {
        let sections = SidebarSections(
            pins: library.links(on: .pins), bookmarks: library.bookmarks, tabs: tabs)
        if sections != sidebar { sidebar = sections }
    }

    // MARK: Tabs

    /// Opens a loose blank tab and selects it.
    func newTab() {
        hideShortcutHelp()
        open(BrowserTab(), load: false)
        addressFocusRequest += 1
    }

    /// Cmd-click on a link: the link opens in a new selected tab, on the opener's store.
    func open(url: URL, from source: TabID) {
        let store = tabs[source]?.store ?? .global
        open(BrowserTab(store: store, url: url), load: true)
    }

    /// A History window entry: the page opens in a new selected tab on the default store; a URL that is not a
    /// web page opens nothing.
    func open(historyURL url: URL) {
        guard NewTabPolicy.allowsFromHistory(url) else { return }
        open(BrowserTab(store: .global, url: url), load: true)
    }

    /// Selects the tab, building its web view when it has none; every other tab keeps its own.
    func select(_ id: TabID) {
        changeTabs { $0.select(id) }
        ensureView(for: id)
    }

    func selectNextTab() { step(1) }

    func selectPreviousTab() { step(-1) }

    private func step(_ offset: Int) {
        if let target = sidebar.target(offset, from: tabs.selectedID) { activate(target) }
    }

    /// Selects the row's target.
    func activate(_ target: SidebarSections.Target) {
        switch target {
        case .tab(let id): select(id)
        case .link(let link): openLink(link)
        }
    }

    /// Closes the tab and its web view. A link's row stays, not open. Closing the selected tab selects
    /// its sidebar neighbour; closing the last one leaves a blank tab.
    func close(_ id: TabID) {
        let next = tabs.selectedID == id ? sidebar.neighbour(ofClosing: id) : tabs.selectedID
        changeTabs { $0.close(id, selecting: next) }
        if tabs.tabs.isEmpty {
            open(BrowserTab(), load: false)
        } else if let selected = tabs.selectedID {
            ensureView(for: selected)
        }
    }

    func closeSelectedTab() {
        hideShortcutHelp()
        if let id = tabs.selectedID { close(id) }
    }

    /// Called by WebKit for popups and `target=_blank`: the new tab runs on the configuration it
    /// hands over and opens selected; WebKit loads it.
    func openPopup(from source: TabID, configuration: WKWebViewConfiguration) -> WKWebView? {
        guard let opener = tabs[source] else { return nil }
        return open(BrowserTab(store: opener.store), configuration: configuration, load: false)
    }

    /// Appends `tab`, selects it and builds its web view, loading `tab.url` when `load` is true.
    @discardableResult
    private func open(_ tab: BrowserTab, configuration: WKWebViewConfiguration? = nil, load: Bool) -> LodgeWebView? {
        var tab = tab
        tab.isLive = false
        changeTabs { $0.open(tab) }
        return ensureView(for: tab.id, configuration: configuration, load: load)
    }

    /// The tab's web view, building it (registry + TabController) when the tab has none, then marking the tab
    /// live. Loads `tab.url` when it built the view and `load` is true. Nil for an unknown tab.
    /// The ONLY place that sets `isLive = true`.
    @discardableResult
    private func ensureView(for id: TabID, configuration: WKWebViewConfiguration? = nil, load: Bool = true) -> LodgeWebView? {
        guard let tab = tabs[id] else { return nil }
        if let view = registry.webView(for: id) { return view }
        let isRestoring = restoredTabs.remove(id) != nil
        let view = registry.make(
            for: id, store: tab.store, configuration: configuration, zoom: zoom[id] ?? PageZoom.actual)
        update(id) { $0.isLive = true }
        // Built once the tab is listed, so the controller's initial KVO values reach it.
        let controller = TabController(tab: id, webView: view, model: self)
        controllers[id] = controller
        if load, let url = tab.url {
            controller.browserWillLoad()
            let navigation = view.load(URLRequest(url: url))
            if isRestoring { controller.restoreNavigation = navigation }
        }
        return view
    }

    /// Every change to `tabs` goes through here: a selection change hides find, ends any sheet the
    /// previous tab had open and opens the folders above the new tab's bookmark, and a tab that closes
    /// loses everything kept for it. Its web view goes on
    /// the next main-actor turn, so a WebKit callback running on it (a popup's opener) returns first.
    private func changeTabs(_ change: (inout TabList) -> Void) {
        let previous = tabs.selectedID
        let before = tabs.tabs.map(\.id)
        change(&tabs)
        if tabs.selectedID != previous {
            if isFindVisible { isFindVisible = false }
            clearFindMiss()
            if let previous { controllers[previous]?.didDeselect() }
            if let link = tabs.selected?.link { changeLibrary { $0.reveal(link) } }
        }
        let dropped = before.filter { tabs[$0] == nil }
        guard !dropped.isEmpty else { return }
        for id in dropped {
            controllers[id] = nil
            restoredTabs.remove(id)
            historyRecorder?.send(.closed(tab: id))
            if loadProgress[id] != nil { loadProgress[id] = nil }
            if favicons[id] != nil { favicons[id] = nil }
            if security[id] != nil { security[id] = nil }
            if zoom[id] != nil { zoom[id] = nil }
        }
        Task { @MainActor [registry] in
            for id in dropped { registry.destroy(id) }
        }
    }

    /// Writes to `tabs` only when the tab really changes, so unchanged KVO ticks do not redraw the window.
    func update(_ id: TabID, _ change: (inout BrowserTab) -> Void) {
        guard let old = tabs[id] else { return }
        var tab = old
        change(&tab)
        if tab != old { tabs.update(id) { $0 = tab } }
    }

    func setFavicon(_ image: NSImage?, for id: TabID) {
        guard tabs[id] != nil, favicons[id] !== image else { return }
        favicons[id] = image
    }

    func setProgress(_ progress: Double, for id: TabID) {
        if loadProgress[id] != progress { loadProgress[id] = progress }
    }

    func setSecurity(_ value: SiteSecurity, for id: TabID) {
        guard tabs[id] != nil, security[id] != value else { return }
        security[id] = value
    }

    // MARK: Links

    /// Selects the link's open tab, else opens a fresh tab on the link's URL, loaded unless `load` is
    /// false (layout renders, so no request goes out). The tab keeps the link while it navigates.
    func openLink(_ link: SavedLink, load: Bool = true) {
        if let tab = tabs.tab(forLink: link.id) {
            select(tab.id)
        } else {
            open(tab(for: link), load: load)
        }
    }

    /// A fresh tab on the link. Every link opens in the default profile.
    private func tab(for link: SavedLink) -> BrowserTab {
        BrowserTab(store: .global, url: link.url, title: link.title, link: link.id)
    }

    /// Whether the tab has a page to save as a link.
    func canAddLink(from id: TabID) -> Bool { savablePage(of: id) != nil }

    private func savablePage(of id: TabID) -> (tab: BrowserTab, url: URL)? {
        guard let tab = tabs[id], let url = tab.url else { return nil }
        return (tab, url)
    }

    /// Saves the tab's page on `shelf`. A loose tab becomes that link's tab, so its row moves to the
    /// shelf and outlives closing it.
    func addLink(_ shelf: LinkShelf, from id: TabID) {
        guard let page = savablePage(of: id) else { return }
        let link = library.add(page.url, title: page.tab.displayTitle, to: shelf)
        if page.tab.link == nil { update(id) { $0.link = link.id } }
    }

    func bookmarkSelectedTab() {
        hideShortcutHelp()
        if let id = tabs.selectedID { addLink(.bookmarks, from: id) }
    }

    /// The pin holding the selected tab's page, matched by URL so a bookmark's tab finds its pin too.
    private var selectedPin: SavedLink? {
        guard let url = selected?.url else { return nil }
        return library.links(on: .pins).first { $0.url == url }
    }

    /// The selected tab's page is one of the pins.
    var isSelectedTabPinned: Bool { selectedPin != nil }

    /// Pins the selected tab's page, or unpins it; the page stays open, and a bookmark's tab keeps its bookmark.
    func togglePinSelectedTab() {
        hideShortcutHelp()
        if let pin = selectedPin {
            removeLink(pin.id)
        } else if let id = tabs.selectedID {
            addLink(.pins, from: id)
        }
    }

    /// Drops the link's row, or a folder with every row in it; an open tab of a removed link carries on as a
    /// loose tab.
    func removeLink(_ id: UUID) {
        let removed = Set(library.remove(id))
        let loosened = tabs.tabs.filter { $0.link.map(removed.contains) == true }.map(\.id)
        guard !loosened.isEmpty else { return }
        changeTabs { tabs in
            for id in loosened { tabs.update(id) { $0.link = nil } }
        }
    }

    /// Writes the library only when `change` really changes it, so a no-op stores and redraws nothing.
    private func changeLibrary(_ change: (inout LinkLibrary) -> Void) {
        var changed = library
        change(&changed)
        if changed != library { library = changed }
    }

    // MARK: Bookmark folders

    /// Opens or closes the folder in the sidebar; the state is kept with the session.
    func setFolderExpanded(_ id: UUID, _ isExpanded: Bool) {
        changeLibrary { $0.setExpanded(id, isExpanded) }
    }

    /// Appends a folder named `title` (blank: "New Folder") to `parent`, the root for nil, opening `parent`
    /// so the folder shows. Returns the folder's id; nil for an unknown parent.
    @discardableResult
    func newFolder(in parent: UUID? = nil, title: String = "New Folder") -> UUID? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var folder: BookmarkFolder?
        changeLibrary { library in
            let parent = parent ?? library.bookmarks.id
            folder = library.addFolder(name.isEmpty ? "New Folder" : name, in: parent)
            if folder != nil { library.setExpanded(parent, true) }
        }
        return folder?.id
    }

    /// Retitles a folder or bookmark; a blank title changes nothing.
    func rename(_ id: UUID, to title: String) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        changeLibrary { $0.rename(id, to: name) }
    }

    /// Moves a bookmark or folder into `folder` at `index` (see `LinkLibrary.moveBookmark`); false when the
    /// move is refused.
    @discardableResult
    func moveBookmark(_ id: UUID, into folder: UUID, at index: Int?) -> Bool {
        guard library.canMoveBookmark(id, into: folder) else { return false }
        return library.moveBookmark(id, into: folder, at: index)
    }

    /// Moves the pin so it ends at `index` among the pins.
    func movePin(_ id: UUID, to index: Int) {
        library.move(id, to: index)
    }

    // MARK: Import and export

    /// Whether `importBookmarks(from:)` is running, from its start until the folder is added or the import fails;
    /// a cancelled import counts until its read has ended.
    private(set) var isImportingBookmarks = false

    /// Reads the bookmark file at `url` off the main actor, then adds it to the root as one open folder named
    /// after the file. Throws `BookmarkFile.ReadError`, `NetscapeBookmarks.ImportError` or, when the calling task
    /// is cancelled, `CancellationError`, leaving the library as it was. Cancelling reaches the read, but a
    /// SwiftSoup parse under way runs to its end, and its folder is then dropped.
    func importBookmarks(from url: URL) async throws {
        isImportingBookmarks = true
        defer { isImportingBookmarks = false }
        let read = Task.detached(priority: .userInitiated) { try BookmarkFile.read(url) }
        let folder = try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
        try Task.checkCancellation()
        changeLibrary { library in
            library.insert(folder, in: library.bookmarks.id)
            library.setExpanded(folder.id, true)
        }
    }

    /// Writes every bookmark to `url` as one Netscape bookmark file in UTF-8, replacing it atomically.
    func exportBookmarks(to url: URL) throws {
        try Data(NetscapeBookmarks.export(library.bookmarks).utf8).write(to: url, options: .atomic)
    }

    // MARK: Navigation

    /// The selected tab's web view, built without loading when the tab has none.
    private var selectedView: LodgeWebView? { tabs.selectedID.flatMap { ensureView(for: $0, load: false) } }

    /// Loads the address into the selected tab, or opens a loose tab on it when none is selected.
    func load(_ text: String) {
        guard let url = AddressInput.url(from: text) else { return }
        guard let id = tabs.selectedID, let view = ensureView(for: id, load: false) else {
            open(BrowserTab(url: url), load: true)
            return
        }
        update(id) { $0.url = url }
        controllers[id]?.browserWillLoad()
        view.load(URLRequest(url: url))
        view.window?.makeFirstResponder(view)
    }

    func goBack() { selectedView?.goBack() }

    func goForward() { selectedView?.goForward() }

    func reload() {
        hideShortcutHelp()
        guard let id = tabs.selectedID, let view = ensureView(for: id, load: false) else { return }
        if view.url == nil, let url = tabs[id]?.url {
            controllers[id]?.browserWillLoad()
            view.load(URLRequest(url: url))
        } else {
            view.reload()
        }
    }

    func stopLoading() { selectedView?.stopLoading() }

    func focusAddressBar() {
        hideShortcutHelp()
        addressFocusRequest += 1
    }

    // MARK: Zoom

    /// The selected tab's zoom, nil when it has no page.
    private var selectedPageZoom: Double? {
        guard let id = tabs.selectedID, tabs[id]?.url != nil else { return nil }
        return zoom[id] ?? PageZoom.actual
    }

    var canZoomIn: Bool { selectedPageZoom.map(PageZoom.canZoomIn) == true }

    var canZoomOut: Bool { selectedPageZoom.map(PageZoom.canZoomOut) == true }

    var canResetZoom: Bool { selectedPageZoom.map { $0 != PageZoom.actual } == true }

    func zoomIn() {
        hideShortcutHelp()
        if canZoomIn { setSelectedZoom(PageZoom.zoomedIn) }
    }

    func zoomOut() {
        hideShortcutHelp()
        if canZoomOut { setSelectedZoom(PageZoom.zoomedOut) }
    }

    func resetZoom() {
        hideShortcutHelp()
        if canResetZoom { setSelectedZoom { _ in PageZoom.actual } }
    }

    /// Stores the selected tab's new zoom (dropping the entry at actual size) and applies it to its web view.
    private func setSelectedZoom(_ next: (Double) -> Double) {
        guard let id = tabs.selectedID, let current = selectedPageZoom else { return }
        let value = next(current)
        zoom[id] = value == PageZoom.actual ? nil : value
        ensureView(for: id, load: false)?.pageZoom = value
    }

    /// Each sidebar mode anchors the Downloads popover on its own button, so it closes before the mode changes rather
    /// than leave the flag set with its anchor gone; ⌘J then opens it on the new button.
    func closeDownloadsForModeChange() { isDownloadsVisible = false }

    func toggleDownloads() {
        hideShortcutHelp()
        isDownloadsVisible.toggle()
    }

    // MARK: Shortcut help

    /// Opens the overlay and takes the keys from the page under it, so Esc and typing reach the overlay.
    func showShortcutHelp() {
        isShortcutHelpVisible = true
        if let window = selectedView?.window { window.makeFirstResponder(nil) }
    }

    /// Closes the overlay and hands the keys back to the page, as closing Find does. Every catalog shortcut's
    /// action calls it first, so a key pressed over the overlay never acts out of sight behind it.
    func hideShortcutHelp() {
        guard isShortcutHelpVisible else { return }
        isShortcutHelpVisible = false
        if let view = selectedView { view.window?.makeFirstResponder(view) }
    }

    func toggleShortcutHelp() {
        if isShortcutHelpVisible { hideShortcutHelp() } else { showShortcutHelp() }
    }

    // MARK: Find

    func showFind() {
        hideShortcutHelp()
        isFindVisible = true
        clearFindMiss()
        findFocusRequest += 1
    }

    func hideFind() {
        if isFindVisible { isFindVisible = false }
        clearFindMiss()
        if let view = selectedView { view.window?.makeFirstResponder(view) }
    }

    func findNext() { find(backwards: false) }

    func findPrevious() { find(backwards: true) }

    /// Searches for `findText` unless it was already searched for.
    func findIfChanged() {
        if findText != lastSearchedText { findNext() }
    }

    private func find(backwards: Bool) {
        lastSearchedText = findText
        guard !findText.isEmpty, let view = selectedView else {
            clearFindMiss()
            return
        }
        if !isFindVisible { showFind() }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = false
        config.wraps = true
        view.find(findText, configuration: config) { [weak self] result in
            self?.findMissed = !result.matchFound
        }
    }

    private func clearFindMiss() {
        if findMissed { findMissed = false }
    }
}
