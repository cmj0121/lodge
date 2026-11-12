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
        didSet { refreshSidebar() }
    }
    private(set) var library: LinkLibrary {
        didSet { refreshSidebar() }
    }
    /// The sidebar's entries, each link paired with its open tab, rebuilt only when `tabs` or
    /// `library` change.
    private(set) var sidebar = SidebarSections()
    /// Load progress per tab, kept apart from `tabs` so progress ticks redraw only the progress line.
    private(set) var loadProgress: [TabID: Double] = [:]
    /// Each page's security, kept apart from `tabs` like progress; gone with the tab.
    private(set) var security: [TabID: SiteSecurity] = [:]
    var findText = ""
    var isFindVisible = false
    private(set) var findMissed = false
    /// Each tab's decoded favicon, kept apart from `tabs` so an icon arriving redraws only its icon.
    private(set) var favicons: [TabID: NSImage] = [:]
    /// Bumped to ask the window to focus the address bar or the find field.
    private(set) var addressFocusRequest = 0
    private(set) var findFocusRequest = 0
    /// The text the last search ran for, so the typing debounce does not search it again.
    @ObservationIgnored private var lastSearchedText = ""

    @ObservationIgnored let registry = WebViewRegistry()
    @ObservationIgnored private var controllers: [TabID: TabController] = [:]

    /// Starts with `defaultLibrary` and one blank tab.
    init(defaultLibrary: LinkLibrary = LinkLibrary()) {
        library = defaultLibrary
        open(BrowserTab(), load: false)
    }

    var selected: BrowserTab? { tabs.selected }

    /// The selected page's security; `.none` with no tab selected.
    var selectedSecurity: SiteSecurity { tabs.selectedID.flatMap { security[$0] } ?? .none }

    private func refreshSidebar() {
        let sections = SidebarSections(
            pins: library.links(on: .pins), bookmarks: library.links(on: .bookmarks), tabs: tabs)
        if sections != sidebar { sidebar = sections }
    }

    // MARK: Tabs

    /// Opens a loose blank tab and selects it.
    func newTab() {
        open(BrowserTab(), load: false)
        addressFocusRequest += 1
    }

    /// Cmd-click on a link: the link opens in a new selected tab, on the opener's store.
    func open(url: URL, from source: TabID) {
        let store = tabs[source]?.store ?? .global
        open(BrowserTab(store: store, url: url), load: true)
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
        let view = registry.make(for: id, store: tab.store, configuration: configuration)
        update(id) { $0.isLive = true }
        // Built once the tab is listed, so the controller's initial KVO values reach it.
        controllers[id] = TabController(tab: id, webView: view, model: self)
        if load, let url = tab.url { view.load(URLRequest(url: url)) }
        return view
    }

    /// Every change to `tabs` goes through here: a selection change hides find and ends any sheet the
    /// previous tab had open, and a tab that closes loses everything kept for it. Its web view goes on
    /// the next main-actor turn, so a WebKit callback running on it (a popup's opener) returns first.
    private func changeTabs(_ change: (inout TabList) -> Void) {
        let previous = tabs.selectedID
        let before = tabs.tabs.map(\.id)
        change(&tabs)
        if tabs.selectedID != previous {
            if isFindVisible { isFindVisible = false }
            clearFindMiss()
            if let previous { controllers[previous]?.didDeselect() }
        }
        let dropped = before.filter { tabs[$0] == nil }
        guard !dropped.isEmpty else { return }
        for id in dropped {
            controllers[id] = nil
            if loadProgress[id] != nil { loadProgress[id] = nil }
            if favicons[id] != nil { favicons[id] = nil }
            if security[id] != nil { security[id] = nil }
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
        if let id = tabs.selectedID { addLink(.bookmarks, from: id) }
    }

    /// Drops the link's row; an open tab of it carries on as a loose tab.
    func removeLink(_ id: UUID) {
        library.remove(id)
        if let tab = tabs.tab(forLink: id) { update(tab.id) { $0.link = nil } }
    }

    /// Moves the pin so it ends at `index` among the pins.
    func movePin(_ id: UUID, to index: Int) {
        library.move(id, to: index)
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
        view.load(URLRequest(url: url))
        view.window?.makeFirstResponder(view)
    }

    func goBack() { selectedView?.goBack() }

    func goForward() { selectedView?.goForward() }

    func reload() {
        guard let id = tabs.selectedID, let view = ensureView(for: id, load: false) else { return }
        if view.url == nil, let url = tabs[id]?.url {
            view.load(URLRequest(url: url))
        } else {
            view.reload()
        }
    }

    func stopLoading() { selectedView?.stopLoading() }

    func focusAddressBar() { addressFocusRequest += 1 }

    // MARK: Find

    func showFind() {
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
