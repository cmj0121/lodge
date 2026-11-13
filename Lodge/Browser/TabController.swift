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
    /// The next main-frame commit is a restore from saved interaction state, so it is not a visit.
    var expectsRestoreCommit = false
    /// Each recent navigation action's gesture and site, for the download its response may become.
    private var gestures = NavigationGestures()
    /// The next main-frame action is a load the browser started (`browserWillLoad()`).
    private var nextLoadIsBrowserInitiated = false

    init(tab: TabID, webView: LodgeWebView, model: BrowserModel, faviconSession: URLSession) {
        self.tab = tab
        self.model = model
        history = HistoryEventFilter(tab: tab)
        favicons = FaviconLoader(session: faviconSession) { [weak model] image in model?.setFavicon(image, for: tab) }
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
            holdState(webView, \.cameraCaptureState),
            holdState(webView, \.microphoneCaptureState),
            holdState(webView, \.fullscreenState),
        ]
    }

    /// Tells the model when a state that keeps a background tab's view alive changes.
    private func holdState<Value>(_ webView: WKWebView, _ keyPath: KeyPath<WKWebView, Value>) -> NSKeyValueObservation {
        webView.observe(keyPath) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model?.holdStateChanged(self.tab)
            }
        }
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

    /// Called just before the browser loads a URL into the tab (address bar, bookmark, history, restore): that
    /// navigation's downloads count against the URL's site, not the page it replaces.
    func browserWillLoad() {
        nextLoadIsBrowserInitiated = true
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
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let browserInitiated = isMainFrame && nextLoadIsBrowserInitiated
        if isMainFrame { nextLoadIsBrowserInitiated = false }
        gestures.record(
            Self.gestureRecord(of: navigationAction, browserInitiated: browserInitiated),
            url: navigationAction.request.url, isMainFrame: isMainFrame)
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        if navigationAction.navigationType == .linkActivated, navigationAction.modifierFlags.contains(.command),
            let url = navigationAction.request.url, NewTabPolicy.allows(url)
        {
            model?.open(url: url, from: tab)
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")
        let action = gestures.record(
            for: navigationResponse.response.url, isMainFrame: navigationResponse.isForMainFrame)
        let download = DownloadPolicy.shouldDownload(
            mimeCanShow: navigationResponse.canShowMIMEType, contentDisposition: disposition,
            isMainFrame: navigationResponse.isForMainFrame, userInitiated: action?.userInitiated ?? false)
        return download ? .download : .allow
    }

    /// A link click (an `<a download>` included) or a form submission counts as user-initiated: WebKit has no public
    /// user-gesture flag, so the navigation type is the closest signal (see `DownloadGate`). The site is the source
    /// frame's origin, else (or for a `browserInitiated` load) the target URL's.
    private static func gestureRecord(
        of action: WKNavigationAction, browserInitiated: Bool = false
    ) -> NavigationGestures.Record {
        let source = action.sourceFrame.securityOrigin
        return NavigationGestures.Record(
            userInitiated: action.navigationType == .linkActivated || action.navigationType == .formSubmitted,
            site: DownloadGate.site(
                source: Origin(scheme: source.protocol, host: source.host, port: source.port),
                target: action.request.url, browserInitiated: browserInitiated))
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        let isMainFrame =
            navigationAction.sourceFrame.isMainFrame && (navigationAction.targetFrame?.isMainFrame ?? true)
        startDownload(download, action: Self.gestureRecord(of: navigationAction), isMainFrame: isMainFrame)
    }

    /// The response's action is looked up by URL and frame; without one it counts as not user-initiated and
    /// without a site.
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        let isMainFrame = navigationResponse.isForMainFrame
        let action = gestures.record(for: navigationResponse.response.url, isMainFrame: isMainFrame)
        startDownload(
            download, action: action ?? NavigationGestures.Record(userInitiated: false, site: nil),
            isMainFrame: isMainFrame)
    }

    /// Hands the download to the manager with the tab's store and its action's gesture and site; without a store
    /// it does not run.
    private func startDownload(_ download: WKDownload, action: NavigationGestures.Record, isMainFrame: Bool) {
        guard let manager = model?.downloads, let store else {
            download.cancel(nil)
            return
        }
        manager.start(
            download, store: store, site: action.site, userInitiated: action.userInitiated, isMainFrame: isMainFrame)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        model?.update(tab) { $0.hasCrashed = false }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        let isRestore = (navigation != nil && navigation === restoreNavigation) || expectsRestoreCommit
        if isRestore { restoreNavigation = nil }
        expectsRestoreCommit = false
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
        guard dismissSheet == nil, model?.placement?.isShown(tab) == true else { return nil }
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
