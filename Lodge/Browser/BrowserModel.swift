import AppKit
import LodgeKit
import Observation
import WebKit

/// State and actions of the browser window: the tab list, the web views behind it, find in page.
@MainActor
@Observable
final class BrowserModel {
    private(set) var tabs = TabList()
    /// Load progress per tab, kept apart from `tabs` so progress ticks redraw only the progress line.
    private(set) var loadProgress: [TabID: Double] = [:]
    var findText = ""
    var isFindVisible = false
    private(set) var findMissed = false
    /// Bumped to ask the window to focus the address bar or the find field.
    private(set) var addressFocusRequest = 0
    private(set) var findFocusRequest = 0
    /// The text the last search ran for, so the typing debounce does not search it again.
    @ObservationIgnored private var lastSearchedText = ""

    @ObservationIgnored let registry = WebViewRegistry()
    @ObservationIgnored private var controllers: [TabID: TabController] = [:]

    /// The window always has a tab: one opens here, and closing the last one opens another.
    init() {
        open(BrowserTab(), load: nil)
    }

    var selected: BrowserTab? { tabs.selected }

    // MARK: Tabs

    func newTab() {
        open(BrowserTab(), load: nil)
        addressFocusRequest += 1
    }

    func open(url: URL, after source: TabID?, inBackground: Bool) {
        let store = source.flatMap { tabs[$0]?.store } ?? .global
        open(BrowserTab(store: store, url: url), after: source, select: !inBackground, load: url)
    }

    func select(_ id: TabID) { changeTabs { $0.select(id) } }

    func selectNextTab() { changeTabs { $0.selectNext() } }

    func selectPreviousTab() { changeTabs { $0.selectPrevious() } }

    func close(_ id: TabID) {
        guard tabs[id] != nil else { return }
        changeTabs { $0.close(id) }
        controllers[id] = nil
        loadProgress[id] = nil
        registry.destroy(id)
        if tabs.tabs.isEmpty { newTab() }
    }

    func closeSelectedTab() {
        if let id = tabs.selectedID { close(id) }
    }

    /// Called by WebKit for popups and `target=_blank`: the new tab runs on the configuration it hands over.
    func openPopup(from source: TabID, configuration: WKWebViewConfiguration, inBackground: Bool) -> WKWebView? {
        guard let opener = tabs[source] else { return nil }
        return open(
            BrowserTab(store: opener.store), after: source, select: !inBackground, configuration: configuration,
            load: nil)
    }

    @discardableResult
    private func open(
        _ tab: BrowserTab, after source: TabID? = nil, select: Bool = true,
        configuration: WKWebViewConfiguration? = nil, load url: URL?
    ) -> LodgeWebView {
        let view = registry.make(for: tab.id, store: tab.store, configuration: configuration)
        controllers[tab.id] = TabController(tab: tab.id, webView: view, model: self)
        changeTabs { $0.open(tab, after: source, select: select) }
        if let url { view.load(URLRequest(url: url)) }
        return view
    }

    /// Every change to `tabs` that can move the selection goes through here: leaving a tab hides
    /// find and ends any sheet the tab had open.
    private func changeTabs(_ change: (inout TabList) -> Void) {
        let previous = tabs.selectedID
        change(&tabs)
        guard tabs.selectedID != previous else { return }
        isFindVisible = false
        findMissed = false
        if let previous { controllers[previous]?.didDeselect() }
    }

    /// Writes to `tabs` only when the tab really changes, so unchanged KVO ticks do not redraw the window.
    func update(_ id: TabID, _ change: (inout BrowserTab) -> Void) {
        guard let old = tabs[id] else { return }
        var tab = old
        change(&tab)
        if tab != old { tabs.update(id) { $0 = tab } }
    }

    func setProgress(_ progress: Double, for id: TabID) {
        if loadProgress[id] != progress { loadProgress[id] = progress }
    }

    // MARK: Navigation

    private var selectedView: LodgeWebView? { tabs.selectedID.flatMap { registry.webView(for: $0) } }

    func load(_ text: String) {
        guard let url = AddressInput.url(from: text), let id = tabs.selectedID, let view = selectedView else { return }
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
        findMissed = false
        findFocusRequest += 1
    }

    func hideFind() {
        isFindVisible = false
        findMissed = false
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
            findMissed = false
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
}
