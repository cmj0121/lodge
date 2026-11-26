import LodgeKit
import UIKit
import WebKit
import os

/// The web views of the tabs that have one, and the website data stores they sit on. A tab whose view is released
/// keeps its `interactionState`, so a rebuilt view picks up its history where it was.
@MainActor
final class WebViewPool {
    private static let logger = Logger(subsystem: "dev.lodge", category: "web")

    /// What iPhone and iPad Safari name in their User-Agent, so sites serve Lodge their mobile pages as they do Safari
    /// (the Mac app names desktop Safari, `SafariUserAgent`); Safari's version follows the system's.
    static let userAgentApplicationName: String = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "Version/\(version.majorVersion).\(version.minorVersion) Mobile/15E148 Safari/604.1"
    }()

    private weak var model: AppModel?
    private var views: [TabID: WKWebView] = [:]
    private var states: [TabID: Any] = [:]
    private var observers: [TabID: [NSKeyValueObservation]] = [:]
    private var stores: [StoreRef: WKWebsiteDataStore] = [:]
    private lazy var delegate = WebViewDelegate(pool: self)
    /// Told every frame's video reports, asked before any release, and told of a tab closing.
    weak var pictureInPicture: PictureInPicture?

    init(model: AppModel) {
        self.model = model
    }

    // MARK: - Views

    func hasView(_ tab: TabID) -> Bool { views[tab] != nil }

    func liveTabs(in tabs: [BrowserTab]) -> [TabID] { tabs.map(\.id).filter { views[$0] != nil } }

    func tab(of view: WKWebView) -> TabID? { views.first { $0.value === view }?.key }

    /// The tab's web view, when it has one; never builds one.
    func existingView(for id: TabID) -> WKWebView? { views[id] }

    /// The tab's web view, built (and its page restored or loaded) when it has none.
    func view(for id: TabID) -> WKWebView {
        if let view = views[id] { return view }
        let store = model?.tab(id)?.store ?? .global
        let view = makeView(configuration: configuration(for: store))
        register(view, for: id)
        if let state = states.removeValue(forKey: id) {
            view.interactionState = state
        } else if let url = model?.tab(id)?.url, NewTabPolicy.allows(url) {
            view.load(URLRequest(url: url))
        }
        return view
    }

    /// A view WebKit asked for (a popup), shown by the new tab `tab`.
    func adopt(_ view: WKWebView, for tab: BrowserTab) {
        register(view, for: tab.id)
    }

    func load(_ url: URL, in id: TabID) {
        view(for: id).load(URLRequest(url: url))
    }

    /// A view on `configuration` with Lodge's settings; WebKit requires a popup's to be built on the one it hands over.
    func makeView(configuration: WKWebViewConfiguration) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.allowsLinkPreview = true
        view.isInspectable = true
        view.navigationDelegate = delegate
        view.uiDelegate = delegate
        view.scrollView.refreshControl = UIRefreshControl(
            frame: .zero, primaryAction: UIAction { [weak view] _ in view?.reload() })
        return view
    }

    private func configuration(for ref: StoreRef) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore(for: ref)
        config.applicationNameForUserAgent = Self.userAgentApplicationName
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.preferences.isElementFullscreenEnabled = true
        let world = WKContentWorld.world(name: VideoPopOutScript.worldName)
        config.userContentController.addUserScript(
            WKUserScript(
                source: VideoPopOutScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world))
        config.userContentController.add(VideoHandler(pool: self), contentWorld: world, name: VideoPopOutScript.handlerName)
        return config
    }

    private func register(_ view: WKWebView, for id: TabID) {
        views[id] = view
        observers[id] = [
            view.observe(\.url) { [weak self] view, _ in MainActor.assumeIsolated { self?.sync(id, view) } },
            view.observe(\.title) { [weak self] view, _ in MainActor.assumeIsolated { self?.sync(id, view) } },
            view.observe(\.isLoading) { [weak self] view, _ in MainActor.assumeIsolated { self?.sync(id, view) } },
            view.observe(\.canGoBack) { [weak self] view, _ in MainActor.assumeIsolated { self?.sync(id, view) } },
            view.observe(\.canGoForward) { [weak self] view, _ in MainActor.assumeIsolated { self?.sync(id, view) } },
            view.observe(\.estimatedProgress) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.model?.setProgress(view.estimatedProgress, for: id) }
            },
        ]
        // Built while SwiftUI lays out the page; the tab learns it is live just after.
        Task { [weak self] in self?.sync(id, view) }
    }

    private func sync(_ id: TabID, _ view: WKWebView) {
        guard views[id] === view else { return }
        if !view.isLoading { view.scrollView.refreshControl?.endRefreshing() }
        model?.update(id) { tab in
            if let url = view.url { tab.url = url }
            if let title = view.title, !title.isEmpty || view.url != nil { tab.title = title }
            tab.isLoading = view.isLoading
            tab.canGoBack = view.canGoBack
            tab.canGoForward = view.canGoForward
            tab.hasCrashed = false
            tab.isLive = true
        }
    }

    /// Gives up the tab's view, keeping where it was; a tab held in Picture in Picture keeps it.
    func release(_ id: TabID) {
        guard pictureInPicture?.isHolding(id) != true, let view = views[id] else { return }
        states[id] = view.interactionState
        drop(id)
        model?.update(id) { $0.isLive = false }
    }

    /// Gives up the tab's view and where it was: the tab is closing.
    func destroy(_ id: TabID) {
        pictureInPicture?.closing(id)
        states[id] = nil
        drop(id)
    }

    private func drop(_ id: TabID) {
        observers[id] = nil
        guard let view = views.removeValue(forKey: id) else { return }
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.removeFromSuperview()
    }

    /// A workspace left the screen: its tabs give up their views, but for one playing media or held in Picture in
    /// Picture, which is asked again in 30 seconds while `stillBackground` holds (as on the Mac, `ViewRelease`).
    func releaseBackground(_ ids: [TabID], stillBackground: @escaping @MainActor () -> Bool) {
        Task { [weak self] in
            var held: [TabID] = []
            for id in ids {
                guard let self, stillBackground() else { return }
                guard let view = self.views[id] else { continue }
                let playing = await view.requestMediaPlaybackState() == .playing
                guard stillBackground() else { return }
                let isHeld = playing || self.pictureInPicture?.isHolding(id) == true
                switch ViewRelease.step(isShown: false, hasView: self.views[id] != nil, isHeld: isHeld) {
                case .skip: continue
                case .hold: held.append(id)
                case .release: self.release(id)
                }
            }
            guard ViewRelease.needsRetry(isShown: !stillBackground(), isAnyHeld: !held.isEmpty) else { return }
            try? await Task.sleep(for: .seconds(30))
            self?.releaseBackground(held, stillBackground: stillBackground)
        }
    }

    /// A tab's web content process ended: the page reloads.
    fileprivate func didCrash(_ view: WKWebView) {
        Self.logger.info("A web content process ended; reloading its page")
        view.reload()
    }

    // MARK: - Stores

    func dataStore(for ref: StoreRef) -> WKWebsiteDataStore {
        if let cached = stores[ref] { return cached }
        let store: WKWebsiteDataStore =
            switch ref {
            case .global: .default()
            case .workspace(let id): WKWebsiteDataStore(forIdentifier: id)
            case .ephemeral: .nonPersistent()
            }
        stores[ref] = store
        return store
    }

    /// No tab uses `ref` any more: its cached store goes, and an Anonymous tab's data with it. Default's stays.
    func forget(store ref: StoreRef) {
        guard ref != .global, let store = stores.removeValue(forKey: ref) else { return }
        if case .ephemeral = ref {
            Task { await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) }
        }
    }

    // MARK: - Delegate hand-offs

    fileprivate func openPopup(configuration: WKWebViewConfiguration, from opener: WKWebView) -> WKWebView? {
        guard let model, let source = tab(of: opener) else { return nil }
        let view = makeView(configuration: configuration)
        model.openPopup(view, from: source)
        return view
    }

    fileprivate func close(_ view: WKWebView) {
        guard let id = tab(of: view) else { return }
        model?.close(id)
    }

    fileprivate func didReceiveVideo(_ message: VideoPopOutScript.Message, in frame: WKFrameInfo, from view: WKWebView) {
        guard let id = tab(of: view) else { return }
        pictureInPicture?.receive(message, frame: frame, from: id)
    }
}

/// Hands the video probe's messages (`VideoPopOutScript`), from any frame, with that frame, to the pool for the tab
/// whose view sent them. The content controller keeps its handlers alive as long as the configuration, so the pool is
/// held weakly.
@MainActor
private final class VideoHandler: NSObject, WKScriptMessageHandler {
    private weak var pool: WebViewPool?

    init(pool: WebViewPool) {
        self.pool = pool
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let view = message.webView, let video = VideoPopOutScript.message(from: message.body) else { return }
        pool?.didReceiveVideo(video, in: message.frameInfo, from: view)
    }
}

/// The navigation and UI delegate of every web view: popups open as tabs, links to other apps leave Lodge, and a
/// crashed page reloads.
@MainActor
private final class WebViewDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    private weak var pool: WebViewPool?

    /// Schemes the web view handles itself; any other (mail, phone, App Store…) goes to the app that owns it.
    private static let webSchemes: Set<String> = ["http", "https", "about", "blob", "data", "javascript", "file"]

    init(pool: WebViewPool) {
        self.pool = pool
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
            !Self.webSchemes.contains(scheme)
        else { return .allow }
        await UIApplication.shared.open(url)
        return .cancel
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        pool?.openPopup(configuration: configuration, from: webView)
    }

    func webViewDidClose(_ webView: WKWebView) {
        pool?.close(webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pool?.didCrash(webView)
    }
}
