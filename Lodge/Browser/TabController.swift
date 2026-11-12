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
    /// Set when the context menu's "Open Link in New Tab" was chosen; the next popup opens in the
    /// background, and any other navigation clears it.
    private var pendingBackgroundOpen = false

    init(tab: TabID, webView: LodgeWebView, model: BrowserModel) {
        self.tab = tab
        self.model = model
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.onBackgroundOpenChange = { [weak self] in self?.pendingBackgroundOpen = $0 }
        observations = [
            mirror(webView, \.title) { $0.title = $1.title ?? "" },
            mirror(webView, \.url) { if let url = $1.url { $0.url = url } },
            mirror(webView, \.isLoading) { $0.isLoading = $1.isLoading },
            mirror(webView, \.canGoBack) { $0.canGoBack = $1.canGoBack },
            mirror(webView, \.canGoForward) { $0.canGoForward = $1.canGoForward },
            webView.observe(\.estimatedProgress) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.model?.setProgress(view.estimatedProgress, for: self.tab)
                }
            },
        ]
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
        if navigationAction.targetFrame != nil { pendingBackgroundOpen = false }
        if navigationAction.navigationType == .linkActivated, navigationAction.modifierFlags.contains(.command),
            let url = navigationAction.request.url, BackgroundOpenPolicy.allows(url)
        {
            model?.open(url: url, after: tab, inBackground: !navigationAction.modifierFlags.contains(.shift))
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        pendingBackgroundOpen = false
        model?.update(tab) { $0.hasCrashed = false }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url = webView.url { dialogGate.commit(origin: Origin(url: url)) }
        model?.update(tab) { $0.hasCrashed = false }
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
        let background = pendingBackgroundOpen
        pendingBackgroundOpen = false
        return model?.openPopup(from: tab, configuration: configuration, inBackground: background)
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
