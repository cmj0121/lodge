import AppKit
import LodgeKit
import Observation
import WebKit

/// State and actions of one workspace: its saved links, its open tabs and their web views; the window it shows in
/// keeps find, the prompts and the overlays (`WindowState`).
@MainActor
@Observable
final class BrowserModel {
    let workspaceID: UUID
    /// Every tab of the workspace runs on this store; nil for Anonymous, whose tabs each get their own.
    let store: StoreRef?
    /// The Anonymous workspace: each tab is its own browser, its bookmarks keep their icons, nothing is recorded.
    var isAnonymous: Bool { workspaceID == Workspace.anonymousID }
    /// Every open tab. A tab keeps its web view, built when it is first selected, until it closes or the workspace
    /// is released (`releaseViews()`).
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
    /// Each tab's decoded favicon, kept apart from `tabs` so an icon arriving redraws only its icon.
    private(set) var favicons: [TabID: NSImage] = [:]

    /// The window showing the workspace, or that last showed it.
    @ObservationIgnored var window: WindowState
    var findText: String {
        get { window.findText }
        set { window.findText = newValue }
    }
    var isFindVisible: Bool {
        get { window.isFindVisible }
        set { window.isFindVisible = newValue }
    }
    private(set) var findMissed: Bool {
        get { window.findMissed }
        set { window.findMissed = newValue }
    }
    /// The sidebar's Downloads popover is open.
    var isDownloadsVisible: Bool {
        get { window.isDownloadsVisible }
        set { window.isDownloadsVisible = newValue }
    }
    /// The keyboard shortcut help overlay is open.
    var isShortcutHelpVisible: Bool {
        get { window.isShortcutHelpVisible }
        set { window.isShortcutHelpVisible = newValue }
    }
    /// The floating location prompt, open for a new tab or for the tab it loads in; nil when closed.
    private(set) var locationPrompt: LocationPrompt? {
        get { window.locationPrompt }
        set { window.locationPrompt = newValue }
    }
    /// The workspace sheet, open to create a workspace or to rename one or change its icon; nil when closed.
    private(set) var workspaceEditor: WorkspaceEditor? {
        get { window.workspaceEditor }
        set { window.workspaceEditor = newValue }
    }
    /// Bumped to ask the window to focus the find field.
    private(set) var findFocusRequest: Int {
        get { window.findFocusRequest }
        set { window.findFocusRequest = newValue }
    }
    private var lastSearchedText: String {
        get { window.lastSearchedText }
        set { window.lastSearchedText = newValue }
    }

    /// Shared by every workspace's model.
    @ObservationIgnored let registry: WebViewRegistry
    @ObservationIgnored private var controllers: [TabID: TabController] = [:]
    /// Restored or released tabs whose web view is not built yet; the load that builds one is not a visit.
    @ObservationIgnored private var restoredTabs: Set<TabID> = []
    /// Decoded icons of Anonymous bookmarks, by link, with the bytes they were decoded from.
    @ObservationIgnored private var storedIcons: [UUID: (data: Data, image: NSImage)] = [:]
    /// Released tabs' `interactionState`, in memory only, put back when the view is rebuilt.
    @ObservationIgnored private var savedStates: [TabID: Any] = [:]
    /// Each popup tab's opener, so neither of a live pair is released while the other has a view.
    @ObservationIgnored private var popupOpeners: [TabID: TabID] = [:]
    /// Retries `releaseViews()` for tabs that were held; nil when no retry waits.
    @ObservationIgnored private var releaseRetryTask: Task<Void, Never>?
    @ObservationIgnored private var viewRelease = ViewRelease()
    /// How long a held tab waits before its release is tried again.
    static let releaseRetry: Duration = .seconds(30)
    /// Where this workspace's tabs record their visits, into its own history store; nil until that store opens,
    /// when the workspace keeps no history, and in layout renders. The store opens after the restored tab may have
    /// committed, so the recorder arrives knowing every tab's page as already seen, and a restored page's load
    /// finishing records nothing.
    @ObservationIgnored var historyRecorder: HistoryRecorder? {
        didSet {
            guard oldValue == nil, let historyRecorder else { return }
            for tab in tabs.tabs {
                if let url = tab.url { historyRecorder.send(.seen(tab: tab.id, url: url)) }
            }
        }
    }

    /// Runs the tabs' downloads; nil in layout renders, where a download does not run.
    @ObservationIgnored var downloads: DownloadManager?

    /// Default's pins, which every other workspace shows and changes in place of pins of its own; nil for Default and
    /// previews.
    @ObservationIgnored weak var sharedPins: (any SharedPins)?

    /// Called with the new content whenever the tabs or the library change in a way it stores.
    @ObservationIgnored var onContentChange: ((SessionSnapshot.WorkspaceContent) -> Void)?
    /// The content last handed to `onContentChange`, so changes it does not store (loading, history
    /// buttons) do not call it.
    @ObservationIgnored private var lastContent: SessionSnapshot.WorkspaceContent?

    /// Starts from `content`, its tabs on `store`; without it, starts with `defaultLibrary`. Either way an empty
    /// workspace gets a blank tab. Only while `window` shows the workspace does its selected tab get a web view; the
    /// other tabs build theirs when first selected.
    init(
        workspace: UUID = Workspace.defaultID, store: StoreRef? = .global,
        restoring content: SessionSnapshot.WorkspaceContent? = nil,
        registry: WebViewRegistry = WebViewRegistry(), window: WindowState = WindowState(),
        defaultLibrary: LinkLibrary = LinkLibrary()
    ) {
        workspaceID = workspace
        self.store = store
        self.registry = registry
        self.window = window
        if let content {
            let restored = content.restored(store: store)
            library = restored.library
            tabs = restored.tabs
            restoredTabs = Set(restored.tabs.tabs.map(\.id))
            for tab in restored.tabs.tabs { registry.attach(tab: tab.id, to: tab.store) }
        } else {
            library = defaultLibrary
        }
        refreshSidebar()
        if tabs.tabs.isEmpty {
            changeTabs { $0.open(BrowserTab(store: newTabStore(), isLive: false)) }
        }
        if isShown, let selected = tabs.selectedID { ensureView(for: selected) }
        lastContent = self.content
    }

    var selected: BrowserTab? { tabs.selected }

    /// The window's title: "Anonymous" whatever its tab shows, else the selected tab's title.
    var windowTitle: String { isAnonymous ? Workspace.anonymousName : selected?.displayTitle ?? "Lodge" }

    /// The store a new tab runs on: the workspace's own; in Anonymous a new browser of its own, except a WebKit popup,
    /// which shares its `opener`'s.
    func newTabStore(popupOf opener: TabID? = nil) -> StoreRef {
        if let opener, let shared = tabs[opener]?.store { return shared }
        return store ?? .ephemeral(UUID())
    }

    /// The selected page's security; `.none` with no tab selected.
    var selectedSecurity: SiteSecurity { tabs.selectedID.flatMap { security[$0] } ?? .none }

    // MARK: Showing and releasing

    /// The window shows this workspace.
    var isShown: Bool { window.activeWorkspace == workspaceID }

    /// The workspace is now on screen in `window`: a pending release retry stops, and the selected tab gets its web
    /// view back, from its saved interaction state when it was released.
    func didShow(in window: WindowState) {
        self.window = window
        releaseRetryTask?.cancel()
        releaseRetryTask = nil
        if let selected = tabs.selectedID { ensureView(for: selected) }
    }

    /// The workspace has left the screen: every tab's web view goes, its interaction state kept in memory, except a
    /// held tab's (`isHeld`), retried every `releaseRetry` and whenever a hold state changes. Stops once the
    /// workspace is shown again. Asked for while a pass runs, it makes that pass scan every tab again.
    func releaseViews() async {
        releaseRetryTask?.cancel()
        releaseRetryTask = nil
        guard !isShown, viewRelease.begin() else { return }
        var isAnyHeld: Bool
        repeat {
            isAnyHeld = false
            for id in tabs.tabs.map(\.id) {
                let held = registry.webView(for: id) != nil ? await isHeld(id) : false
                switch ViewRelease.step(isShown: isShown, hasView: registry.webView(for: id) != nil, isHeld: held) {
                case .stop:
                    viewRelease.stop()
                    return
                case .skip: continue
                case .hold: isAnyHeld = true
                case .release: release(id)
                }
            }
        } while viewRelease.finishScan()
        guard ViewRelease.needsRetry(isShown: isShown, isAnyHeld: isAnyHeld) else { return }
        releaseRetryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.releaseRetry)
            guard !Task.isCancelled, let self else { return }
            self.releaseRetryTask = nil
            await self.releaseViews()
        }
    }

    /// A tab's capture or fullscreen state changed: a held background workspace tries its release again now.
    func holdStateChanged(_ id: TabID) {
        guard !isShown, releaseRetryTask != nil else { return }
        Task { await releaseViews() }
    }

    /// The tab plays media, captures camera or microphone, is in fullscreen, or is one of a popup and its opener that
    /// both still have a view.
    private func isHeld(_ id: TabID) async -> Bool {
        guard let view = registry.webView(for: id) else { return false }
        if view.cameraCaptureState != .none || view.microphoneCaptureState != .none { return true }
        if view.fullscreenState != .notInFullscreen { return true }
        if let opener = popupOpeners[id], registry.webView(for: opener) != nil { return true }
        if popupOpeners.contains(where: { $0.value == id && registry.webView(for: $0.key) != nil }) { return true }
        return await view.requestMediaPlaybackState() == .playing
    }

    /// Destroys the tab's web view; the tab keeps its URL and title, and its page's interaction state waits in
    /// memory for the view to be rebuilt.
    private func release(_ id: TabID) {
        guard let tab = tabs[id], registry.webView(for: id) != nil else { return }
        controllers[id]?.didDeselect()
        controllers[id] = nil
        let state = registry.release(id)
        if tab.url != nil, let state { savedStates[id] = state }
        restoredTabs.insert(id)
        if loadProgress[id] != nil { loadProgress[id] = nil }
        update(id) {
            $0.isLive = false
            $0.isLoading = false
        }
    }

    /// What the session store keeps of the workspace.
    var content: SessionSnapshot.WorkspaceContent { SessionSnapshot.WorkspaceContent(tabs: tabs, library: library) }

    private func didChangeSession() {
        refreshSidebar()
        let content = self.content
        guard content != lastContent else { return }
        lastContent = content
        onContentChange?(content)
    }

    private func refreshSidebar() {
        let sections = SidebarSections(
            pins: pins, bookmarks: library.bookmarks, tabs: tabs, pinsAreShared: sharedPins != nil)
        if sections != sidebar { sidebar = sections }
    }

    /// The pins the sidebar shows: Default's when shared, else the library's own.
    private var pins: [SavedLink] { sharedPins?.pins ?? library.links(on: .pins) }

    /// Default's pins changed, or were just shared with this workspace: the sidebar shows them.
    func sharedPinsDidChange() { refreshSidebar() }

    // MARK: Tabs

    /// Opens the location prompt for a new tab; the tab opens only when the prompt submits an address.
    func newTab() {
        hideShortcutHelp()
        workspaceEditor = nil
        locationPrompt = .newTab
    }

    /// Cmd-click on a link: the link opens in a new selected tab of this workspace; in Anonymous a new browser.
    func open(url: URL, from source: TabID) {
        open(BrowserTab(store: newTabStore(), url: url), load: true)
    }

    /// A History window entry: the page opens in a new selected tab of this workspace; a URL that is not a web page
    /// opens nothing.
    func open(historyURL url: URL) {
        guard NewTabPolicy.allowsFromHistory(url) else { return }
        open(BrowserTab(store: newTabStore(), url: url), load: true)
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

    /// Selects the row's target; a shared pin opens in Default, which the window switches to.
    func activate(_ target: SidebarSections.Target) {
        switch target {
        case .tab(let id): select(id)
        case .link(let link):
            if let sharedPins, sharedPins.pins.contains(where: { $0.id == link.id }) {
                sharedPins.openPin(link, from: window)
            } else {
                openLink(link)
            }
        }
    }

    /// Closes the tab with every popup it opened, directly or through them, and their web views. A link's row stays,
    /// not open. Closing the selected tab selects its sidebar neighbour; closing the last one leaves a blank tab.
    func close(_ id: TabID) {
        guard tabs[id] != nil else { return }
        let closing = [id] + PopupTree.descendants(of: id, openers: popupOpeners)
        let next = tabs.selectedID.flatMap { selected in
            closing.contains(selected) ? sidebar.neighbour(ofClosing: Set(closing), selected: selected) : selected
        }
        changeTabs { tabs in
            for tab in closing { tabs.close(tab, selecting: next) }
        }
        if tabs.tabs.isEmpty {
            open(BrowserTab(store: newTabStore()), load: false)
        } else if let selected = tabs.selectedID {
            ensureView(for: selected)
        }
    }

    func closeSelectedTab() {
        closeFloatingSurfaces()
        if let id = tabs.selectedID { close(id) }
    }

    /// Called by WebKit for popups and `target=_blank`: the new tab runs on the configuration it
    /// hands over and opens selected; WebKit loads it.
    func openPopup(from source: TabID, configuration: WKWebViewConfiguration) -> WKWebView? {
        guard tabs[source] != nil else { return nil }
        let popup = BrowserTab(store: newTabStore(popupOf: source))
        popupOpeners[popup.id] = source
        return open(popup, configuration: configuration, load: false)
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
        let saved = savedStates.removeValue(forKey: id)
        let view = registry.make(
            for: id, store: tab.store, configuration: configuration, zoom: zoom[id] ?? PageZoom.actual)
        update(id) { $0.isLive = true }
        // Built once the tab is listed, so the controller's initial KVO values reach it.
        let controller = TabController(tab: id, webView: view, model: self)
        controllers[id] = controller
        if load, let saved {
            controller.browserWillLoad()
            controller.expectsRestoreCommit = true
            view.interactionState = saved
        } else if load, let url = tab.url {
            controller.browserWillLoad()
            let navigation = view.load(URLRequest(url: url))
            if isRestoring { controller.restoreNavigation = navigation }
        }
        return view
    }

    /// Every change to `tabs` goes through here: a selection change hides find, ends any sheet the
    /// previous tab had open and opens the folders above the new tab's bookmark, and a tab that closes
    /// loses everything kept for it. A new tab holds its store; a closed one lets go of it, and its web view goes, on
    /// the next main-actor turn, so a WebKit callback running on it (a popup's opener) returns first.
    private func changeTabs(_ change: (inout TabList) -> Void) {
        let previous = tabs.selectedID
        let before = tabs.tabs.map(\.id)
        change(&tabs)
        if tabs.selectedID != previous {
            if isFindVisible { isFindVisible = false }
            clearFindMiss()
            if let previous {
                controllers[previous]?.didDeselect()
                registry.webView(for: previous)?.focusesWhenShown = false
            }
            if let link = tabs.selected?.link { changeLibrary { $0.reveal(link) } }
        }
        let kept = Set(before)
        for tab in tabs.tabs where !kept.contains(tab.id) { registry.attach(tab: tab.id, to: tab.store) }
        let dropped = before.filter { tabs[$0] == nil }
        guard !dropped.isEmpty else { return }
        for id in dropped {
            controllers[id] = nil
            restoredTabs.remove(id)
            savedStates[id] = nil
            popupOpeners[id] = nil
            popupOpeners = popupOpeners.filter { $0.value != id }
            historyRecorder?.send(.closed(tab: id))
            if loadProgress[id] != nil { loadProgress[id] = nil }
            if favicons[id] != nil { favicons[id] = nil }
            if security[id] != nil { security[id] = nil }
            if zoom[id] != nil { zoom[id] = nil }
        }
        Task { @MainActor [registry] in
            registry.detach(tabs: dropped)
        }
    }

    /// Writes to `tabs` only when the tab really changes, so unchanged KVO ticks do not redraw the window.
    func update(_ id: TabID, _ change: (inout BrowserTab) -> Void) {
        guard let old = tabs[id] else { return }
        var tab = old
        change(&tab)
        if tab != old { tabs.update(id) { $0 = tab } }
    }

    /// Keeps the tab's icon; in Anonymous a bookmark's tab also stores it in the bookmark, for when it has no tab.
    func setFavicon(_ image: NSImage?, for id: TabID) {
        guard let tab = tabs[id], favicons[id] !== image else { return }
        favicons[id] = image
        if let image, let link = tab.link, isAnonymous, library.links(on: .bookmarks).contains(where: { $0.id == link }) {
            storeIcon(image, in: link)
        }
    }

    /// The row's icon: its open tab's favicon, else a shared pin's from Default, else the icon an Anonymous bookmark
    /// stored.
    func favicon(for item: SidebarItem) -> NSImage? {
        if let tab = item.tab, let image = favicons[tab.id] { return image }
        guard case .link(let link, let shelf, _) = item else { return nil }
        if shelf == .pins, let sharedPins { return sharedPins.pinFavicon(link.id) }
        guard let data = link.icon else { return nil }
        if let cached = storedIcons[link.id], cached.data == data { return cached.image }
        guard let image = NSImage(data: data) else { return nil }
        storedIcons[link.id] = (data, image)
        return image
    }

    private func storeIcon(_ image: NSImage, in link: UUID) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let data = LinkIcon.png(from: cgImage)
        else { return }
        changeLibrary { $0.setIcon(link, data) }
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

    /// A fresh tab on the link, in this workspace.
    private func tab(for link: SavedLink) -> BrowserTab {
        BrowserTab(store: newTabStore(), url: link.url, title: link.title, link: link.id)
    }

    /// Whether the tab has a page to save as a link.
    func canAddLink(from id: TabID) -> Bool { savablePage(of: id) != nil }

    private func savablePage(of id: TabID) -> (tab: BrowserTab, url: URL)? {
        guard let tab = tabs[id], let url = tab.url else { return nil }
        return (tab, url)
    }

    /// Saves the tab's page on `shelf`. A loose tab becomes that link's tab, so its row moves to the
    /// shelf and outlives closing it. A pin while pins are shared is a copy in Default, and the tab stays as it is.
    func addLink(_ shelf: LinkShelf, from id: TabID) {
        guard let page = savablePage(of: id) else { return }
        if shelf == .pins, let sharedPins {
            sharedPins.pin(from: page.tab)
            return
        }
        let link = library.add(page.url, title: page.tab.displayTitle, to: shelf)
        if isAnonymous, shelf == .bookmarks, let image = favicons[id] { storeIcon(image, in: link.id) }
        if page.tab.link == nil { update(id) { $0.link = link.id } }
    }

    func bookmarkSelectedTab() {
        closeFloatingSurfaces()
        if let id = tabs.selectedID { addLink(.bookmarks, from: id) }
    }

    /// The pin holding the selected tab's page, matched by URL so a bookmark's tab finds its pin too.
    private var selectedPin: SavedLink? {
        guard let url = selected?.url else { return nil }
        return pins.first { $0.url == url }
    }

    /// The selected tab's page is one of the pins.
    var isSelectedTabPinned: Bool { selectedPin != nil }

    /// Pins the selected tab's page, or unpins it; the page stays open, and a bookmark's tab keeps its bookmark.
    func togglePinSelectedTab() {
        closeFloatingSurfaces()
        if let pin = selectedPin {
            unpin(pin.id)
        } else if let id = tabs.selectedID {
            addLink(.pins, from: id)
        }
    }

    /// Pins `url` on this workspace's own pins (Default's), or returns the pin already there for it.
    @discardableResult
    func addPin(_ url: URL, title: String) -> SavedLink {
        library.add(url, title: title, to: .pins)
    }

    /// Removes the pin, from Default when pins are shared; its open tab carries on as a loose tab.
    func unpin(_ id: UUID) {
        if let sharedPins { sharedPins.unpin(id) } else { removeLink(id) }
    }

    /// Pins a copy of the bookmark, in Default when pins are shared; the bookmark stays.
    func pin(bookmark link: SavedLink) {
        if let sharedPins { sharedPins.pin(from: link) } else { addPin(link.url, title: link.title) }
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

    /// Moves the pin so it ends at `index` among the pins, Default's when shared.
    func movePin(_ id: UUID, to index: Int) {
        if let sharedPins { sharedPins.movePin(id, to: index) } else { library.move(id, to: index) }
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
        guard let id = tabs.selectedID else {
            open(BrowserTab(store: newTabStore(), url: url), load: true)
            return
        }
        load(url, in: id)
        focusSelectedView()
    }

    /// Loads `url` in the tab; when the tab has no web view to load in, opens a loose tab on it instead.
    private func load(_ url: URL, in id: TabID) {
        guard let view = ensureView(for: id, load: false) else {
            open(BrowserTab(store: newTabStore(), url: url), load: true)
            return
        }
        update(id) { $0.url = url }
        controllers[id]?.browserWillLoad()
        view.load(URLRequest(url: url))
    }

    func goBack() { selectedView?.goBack() }

    func goForward() { selectedView?.goForward() }

    func reload() {
        closeFloatingSurfaces()
        guard let id = tabs.selectedID, let view = ensureView(for: id, load: false) else { return }
        if view.url == nil, let url = tabs[id]?.url {
            controllers[id]?.browserWillLoad()
            view.load(URLRequest(url: url))
        } else {
            view.reload()
        }
    }

    func stopLoading() { selectedView?.stopLoading() }

    /// Opens the location prompt on the selected tab's address, or for a new tab when none is selected.
    func focusAddressBar() {
        hideShortcutHelp()
        workspaceEditor = nil
        locationPrompt = tabs.selectedID.map { .current($0) } ?? .newTab
    }

    // MARK: Location prompt

    /// Goes where the prompt's text leads: a new selected tab, or its tab (a new one if that tab has closed since).
    /// Text that makes no address (blank) leaves the prompt open.
    func submitLocation(_ text: String) {
        guard let prompt = locationPrompt, let url = AddressInput.url(from: text) else { return }
        locationPrompt = nil
        if case .current(let id) = prompt, tabs[id] != nil {
            load(url, in: id)
        } else if case .newTab = prompt, let blank = selected, blank.url == nil, !blank.isLoading {
            // The blank tab an empty window or closing the last tab leaves takes the page, so no empty New Tab row
            // is left behind.
            load(url, in: blank.id)
        } else {
            open(BrowserTab(store: newTabStore(), url: url), load: true)
        }
        focusSelectedView()
    }

    /// Closes the prompt and hands the keys back to the page, as closing Find does.
    func cancelLocationPrompt() {
        guard locationPrompt != nil else { return }
        locationPrompt = nil
        focusSelectedView()
    }

    /// Closes the shortcut overlay, the location prompt and the workspace sheet. Every catalog shortcut's action calls
    /// it first, so a key pressed over any of them never acts out of sight behind it.
    func closeFloatingSurfaces() {
        hideShortcutHelp()
        cancelLocationPrompt()
        closeWorkspaceEditor()
    }

    // MARK: Workspace sheet

    /// Opens the workspace sheet in place of every other floating surface (find, the location prompt, the shortcut
    /// overlay, the Downloads popover) and takes the keys from the page under it.
    func showWorkspaceEditor(_ editor: WorkspaceEditor) {
        locationPrompt = nil
        isShortcutHelpVisible = false
        if isFindVisible { isFindVisible = false }
        clearFindMiss()
        isDownloadsVisible = false
        workspaceEditor = editor
        if let window = selectedView?.window { window.makeFirstResponder(nil) }
    }

    /// Closes the sheet and hands the keys back to the page, as closing the location prompt does.
    func closeWorkspaceEditor() {
        guard workspaceEditor != nil else { return }
        finishWorkspaceEditor()
    }

    /// The sheet is done: closed if still open, and the keys go to the page, also when Create already closed it by
    /// switching to the new workspace.
    func finishWorkspaceEditor() {
        workspaceEditor = nil
        focusSelectedView()
    }

    /// Makes the selected page first responder; a view not in a window yet (a tab just opened) takes focus when
    /// SwiftUI puts it in one.
    private func focusSelectedView() {
        guard let view = selectedView else { return }
        if let window = view.window {
            window.makeFirstResponder(view)
        } else {
            view.focusesWhenShown = true
        }
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
        closeFloatingSurfaces()
        if canZoomIn { setSelectedZoom(PageZoom.zoomedIn) }
    }

    func zoomOut() {
        closeFloatingSurfaces()
        if canZoomOut { setSelectedZoom(PageZoom.zoomedOut) }
    }

    func resetZoom() {
        closeFloatingSurfaces()
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
        closeFloatingSurfaces()
        isDownloadsVisible.toggle()
    }

    // MARK: Shortcut help

    /// Opens the overlay and takes the keys from the page under it, so Esc and typing reach the overlay.
    func showShortcutHelp() {
        locationPrompt = nil
        workspaceEditor = nil
        isShortcutHelpVisible = true
        if let window = selectedView?.window { window.makeFirstResponder(nil) }
    }

    /// Closes the overlay and hands the keys back to the page, as closing Find does.
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
        closeFloatingSurfaces()
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
