import AppKit
import LodgeKit
import WebKit

/// Navigation and UI delegate of one tab's web view; mirrors the view's state into the tab model.
@MainActor
final class TabController: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let tab: TabID
    private weak var model: BrowserModel?
    private var observations: [NSKeyValueObservation] = []
    private var dialogGate = DialogGate()
    /// Ends the dialog or file panel sheet this tab has open, answering it with its default.
    private var dismissSheet: (() -> Void)?
    private let favicons: FaviconLoader
    private var history: HistoryEventFilter
    /// The load that restored the tab; its commit is not a visit.
    var restoreNavigation: WKNavigation?

    init(tab: TabID, webView: LodgeWebView, model: BrowserModel) {
        self.tab = tab
        self.model = model
        history = HistoryEventFilter(tab: tab)
        favicons = FaviconLoader { [weak model] image in model?.setFavicon(image, for: tab) }
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.title) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.model?.update(self.tab) { $0.title = view.title ?? "" }
                    self.sendHistory(
                        self.history.titleChanged(view.title ?? "", url: view.url, store: self.store))
                }
            },
            webView.observe(\.url, options: .initial) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let url = view.url { self.model?.update(self.tab) { $0.url = url } }
                    self.updateSecurity(of: view)
                    self.sendHistory(
                        self.history.urlChanged(
                            view.url, title: view.title ?? "", store: self.store, isLoading: view.isLoading))
                }
            },
            webView.observe(\.isLoading) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.model?.update(self.tab) { $0.isLoading = view.isLoading }
                    guard !view.isLoading else { return }
                    self.sendHistory(self.history.loadFinished(view.url, title: view.title ?? "", store: self.store))
                }
            },
            mirror(webView, \.canGoBack) { $0.canGoBack = $1.canGoBack },
            mirror(webView, \.canGoForward) { $0.canGoForward = $1.canGoForward },
            webView.observe(\.estimatedProgress) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.model?.setProgress(view.estimatedProgress, for: self.tab)
                }
            },
            webView.observe(\.hasOnlySecureContent, options: .initial) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.updateSecurity(of: view) }
            },
        ]
    }

    /// Reclassifies the page's security from the view's current URL and content.
    private func updateSecurity(of view: WKWebView) {
        model?.setSecurity(SiteSecurity(url: view.url, hasOnlySecureContent: view.hasOnlySecureContent), for: tab)
    }

    /// The tab's store; nil once the tab is gone.
    private var store: StoreRef? { model?.tabs[tab]?.store }

    private func sendHistory(_ event: HistoryRecorder.Event?) {
        if let event { model?.historyRecorder?.send(event) }
    }

    /// Copies a web view property into the tab whenever it changes; `apply` reads the current
    /// value off the view, so a property that turns nil is copied too.
    private func mirror<Value>(
        _ webView: WKWebView, _ keyPath: KeyPath<WKWebView, Value>,
        _ apply: @escaping @MainActor @Sendable (inout BrowserTab, WKWebView) -> Void
    ) -> NSKeyValueObservation {
        webView.observe(keyPath) { [weak self] view, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model?.update(self.tab) { apply(&$0, view) }
            }
        }
    }

    /// Called when another tab is selected: ends this tab's open sheet.
    func didDeselect() {
        dismissSheet?()
    }

    // MARK: WKNavigationDelegate

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.navigationType == .linkActivated, navigationAction.modifierFlags.contains(.command),
            let url = navigationAction.request.url, NewTabPolicy.allows(url)
        {
            model?.open(url: url, from: tab)
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        model?.update(tab) { $0.hasCrashed = false }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        let isRestore = navigation != nil && navigation === restoreNavigation
        if isRestore { restoreNavigation = nil }
        if let url = webView.url {
            dialogGate.commit(origin: Origin(url: url))
            sendHistory(history.committed(url, title: webView.title ?? "", store: store, isRestore: isRestore))
        }
        favicons.pageCommitted(webView.url)
        model?.update(tab) { $0.hasCrashed = false }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        favicons.pageFinished(in: webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        model?.update(tab) {
            $0.hasCrashed = true
            $0.isLoading = false
        }
    }

    // MARK: WKUIDelegate

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        model?.openPopup(from: tab, configuration: configuration)
    }

    func webViewDidClose(_ webView: WKWebView) {
        model?.close(tab)
    }

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async {
        await presentDialog(message: message, from: frame, in: webView, buttons: [])
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        await presentDialog(message: message, from: frame, in: webView, buttons: ["OK", "Cancel"])
            == .alertFirstButtonReturn
    }

    func webView(
        _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        guard let window = visibleWindow(of: webView) else { return nil }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        let response = await whileSelected(dismiss: { panel.cancel(nil) }) { await panel.beginSheetModal(for: window) }
        return response == .OK ? panel.urls : nil
    }

    /// The window to hang a sheet on, only while this tab is the one on screen and has no sheet open.
    private func visibleWindow(of webView: WKWebView) -> NSWindow? {
        guard dismissSheet == nil, model?.tabs.selectedID == tab else { return nil }
        return webView.window
    }

    /// Shows a page's dialog as a sheet; a background tab's dialog, or one past the page's rate
    /// limit, is answered at once with `nil`, which callers read as dismissed (confirm → false).
    @discardableResult
    private func presentDialog(
        message: String, from frame: WKFrameInfo, in webView: WKWebView, buttons: [String]
    ) async -> NSApplication.ModalResponse? {
        guard let window = visibleWindow(of: webView), dialogGate.admit() else { return nil }
        let origin = frame.securityOrigin
        let alert = NSAlert()
        alert.messageText = DialogGate.title(for: Origin(scheme: origin.protocol, host: origin.host, port: origin.port))
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Block further dialogs from this page"
        let response = await whileSelected(dismiss: { window.endSheet(alert.window, returnCode: .abort) }) {
            await alert.beginSheetModal(for: window)
        }
        if alert.suppressionButton?.state == .on { dialogGate.block() }
        return response
    }

    /// Runs a sheet that `didDeselect()` ends through `dismiss`.
    private func whileSelected(
        dismiss: @escaping () -> Void, _ sheet: () async -> NSApplication.ModalResponse
    ) async -> NSApplication.ModalResponse {
        dismissSheet = dismiss
        defer { dismissSheet = nil }
        return await sheet()
    }
}
