import AppKit
import LodgeKit
import Observation
import WebKit

/// State and actions of the browser window: the saved links, the one live tab and its web view, find in page.
@MainActor
@Observable
final class BrowserModel {
    /// The tab list holds at most the live session: leaving a tab, by selecting or opening another,
    /// drops it from the list and destroys its web view.
    private(set) var tabs = TabList() {
        didSet { refreshSidebar() }
    }
    private(set) var library = LinkLibrary.sample {
        didSet { refreshSidebar() }
    }
    /// The sidebar's entries, each link paired with its live tab, rebuilt only when `tabs` or
    /// `library` change.
    private(set) var sidebar = SidebarSections()
    /// Load progress per tab, kept apart from `tabs` so progress ticks redraw only the progress line.
    private(set) var loadProgress: [TabID: Double] = [:]
    /// The live page's security, kept apart from `tabs` like progress; gone with the tab's web view.
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

    init() {
        open(BrowserTab(), load: nil)
    }

    var selected: BrowserTab? { tabs.selected }

    /// The live page's security; `.none` with no live tab.
    var selectedSecurity: SiteSecurity { tabs.selectedID.flatMap { security[$0] } ?? .none }

    private func refreshSidebar() {
        let sections = SidebarSections(
            pins: library.links(on: .pins), bookmarks: library.links(on: .bookmarks), tabs: tabs)
        if sections != sidebar { sidebar = sections }
    }

    // MARK: Tabs

    /// Opens a loose blank tab as the live session.
    func newTab() {
        open(BrowserTab(), load: nil)
        addressFocusRequest += 1
    }

    /// Cmd-click on a link: the link opens as the live session, on the opener's store.
    func open(url: URL, from source: TabID) {
        let store = tabs[source]?.store ?? .global
        open(BrowserTab(store: store, url: url), load: url)
    }

    func select(_ id: TabID) { changeTabs { $0.leave(to: id) } }

    func selectNextTab() { step(1) }

    func selectPreviousTab() { step(-1) }

    private func step(_ offset: Int) {
        if let target = sidebar.target(offset, from: tabs.selectedID) { activate(target) }
    }

    /// Makes the row's target the live session.
    func activate(_ target: SidebarSections.Target) {
        switch target {
        case .tab(let id): select(id)
        case .link(let link): openLink(link)
        }
    }

    /// Ends the tab's session. A link's row stays, not open.
    func close(_ id: TabID) { changeTabs { $0.close(id) } }

    func closeSelectedTab() {
        if let id = tabs.selectedID { close(id) }
    }

    /// Called by WebKit for popups and `target=_blank`: the new tab runs on the configuration it
    /// hands over and becomes the live session.
    func openPopup(from source: TabID, configuration: WKWebViewConfiguration) -> WKWebView? {
        guard let opener = tabs[source] else { return nil }
        return open(BrowserTab(store: opener.store), configuration: configuration, load: nil)
    }

    @discardableResult
    private func open(_ tab: BrowserTab, configuration: WKWebViewConfiguration? = nil, load url: URL?) -> LodgeWebView {
        let view = registry.make(for: tab.id, store: tab.store, configuration: configuration)
        changeTabs {
            $0.leave(to: nil)
            $0.open(tab)
        }
        // Built once the tab is listed, so the controller's initial KVO values reach it.
        controllers[tab.id] = TabController(tab: tab.id, webView: view, model: self)
        if let url { view.load(URLRequest(url: url)) }
        return view
    }

    /// Every change to `tabs` goes through here: leaving a tab hides find and ends any sheet the tab
    /// had open, and a tab that drops out loses everything kept for it. Its web view goes on the next
    /// main-actor turn, so a WebKit callback running on it (a popup's opener) returns first.
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

    /// Makes the link the live session: its tab when it is live, else a fresh tab on the link's URL,
    /// loaded unless `load` is false (layout renders, so no request goes out).
    func openLink(_ link: SavedLink, load: Bool = true) {
        if let tab = tabs.tab(forLink: link.id) {
            select(tab.id)
        } else {
            open(tab(for: link), load: load ? link.url : nil)
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
    /// shelf and outlives leaving it.
    func addLink(_ shelf: LinkShelf, from id: TabID) {
        guard let page = savablePage(of: id) else { return }
        let link = library.add(page.url, title: page.tab.displayTitle, to: shelf)
        if page.tab.link == nil { update(id) { $0.link = link.id } }
    }

    func bookmarkSelectedTab() {
        if let id = tabs.selectedID { addLink(.bookmarks, from: id) }
    }

    /// Drops the link's row; a live tab of it carries on as a loose tab.
    func removeLink(_ id: UUID) {
        library.remove(id)
        if let tab = tabs.tab(forLink: id) { update(tab.id) { $0.link = nil } }
    }

    // MARK: Navigation

    private var selectedView: LodgeWebView? { tabs.selectedID.flatMap { registry.webView(for: $0) } }

    /// Loads the address into the live tab, or opens a loose tab on it when there is none.
    func load(_ text: String) {
        guard let url = AddressInput.url(from: text) else { return }
        guard let id = tabs.selectedID, let view = selectedView else {
            open(BrowserTab(url: url), load: url)
            return
        }
        update(id) { $0.url = url }
        view.load(URLRequest(url: url))
        view.window?.makeFirstResponder(view)
    }

    func goBack() { selectedView?.goBack() }

    func goForward() { selectedView?.goForward() }

    func reload() {
        guard let id = tabs.selectedID, let view = selectedView else { return }
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
