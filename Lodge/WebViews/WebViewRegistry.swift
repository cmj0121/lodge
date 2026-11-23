import AppKit
import LodgeKit
import WebKit

/// Owns every tab's WKWebView (D8), for every workspace. SwiftUI only ever shows what this hands out.
@MainActor
final class WebViewRegistry {
    private var stores: [StoreRef: WKWebsiteDataStore] = [:]
    private var views: [TabID: LodgeWebView] = [:]
    /// The store each view was made on.
    private var viewStores: [TabID: StoreRef] = [:]
    /// Which tabs (a released one too) and running downloads keep each store alive.
    private var holders = StoreHolders()
    /// Each anonymous tab's store's favicon session, invalidated when the store is dropped.
    private var faviconSessions: [StoreRef: URLSession] = [:]
    /// Each anonymous tab's store's fingerprint key and exceptions (D3), in memory only, shared with its popups and
    /// dropped with the store.
    private var fingerprints: [StoreRef: FingerprintSettings] = [:]
    /// The plain-http hosts each store's tabs load without a warning (D8), in memory only until Lodge quits; an
    /// anonymous tab's go with its store.
    private var plainHTTPHosts: [StoreRef: Set<String>] = [:]
    /// Called with an anonymous tab's store once it is dropped, so what was kept for it goes too.
    var storeDropped: @MainActor (StoreRef) -> Void = { _ in }

    /// The installed Safari's version, read once; nil when Safari cannot be read.
    static let installedSafariVersion =
        Bundle(url: URL(filePath: "/Applications/Safari.app"))?.infoDictionary?["CFBundleShortVersionString"]
        as? String
    /// What every page's User-Agent ends in, so sites treat Lodge as the installed Safari (D1). A popup gets it with
    /// the configuration WebKit copies from its opener.
    static let userAgentApplicationName = SafariUserAgent.applicationName(safariVersion: installedSafariVersion)

    func webView(for tab: TabID) -> LodgeWebView? { views[tab] }

    /// A new web view for `tab` on `store`, or on `configuration` when WebKit hands one over in
    /// `createWebViewWith` (the popup keeps its opener's store, D3), shown at the tab's page `zoom`. Every view owns
    /// its content controller (D7): a handed-over configuration gets a fresh one, with handlers of its own, before the
    /// view is made, so the opener's scripts stay the opener's. Its user scripts are its `TabController`'s; what the
    /// page reports goes to `model`.
    func make(
        for tab: TabID, store: StoreRef, configuration: WKWebViewConfiguration? = nil, zoom: Double = PageZoom.actual,
        model: BrowserModel
    ) -> LodgeWebView {
        let config: WKWebViewConfiguration
        if let configuration {
            configuration.userContentController = WKUserContentController()
            Self.addHandlers(to: configuration.userContentController, model: model)
            config = configuration
        } else {
            config = newConfiguration(for: store, model: model)
        }
        let view = LodgeWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.pageZoom = zoom
        views[tab] = view
        viewStores[tab] = store
        return view
    }

    /// The tab now runs on `store` and keeps it alive until `detach(tab:)`.
    func attach(tab: TabID, to store: StoreRef) {
        if let left = holders.attach(.tab(tab), to: store) { dropIfEphemeral(left) }
    }

    /// The tab has closed: its view goes, and when it was the last holder of an anonymous tab's store, that store's
    /// data is removed and the store dropped.
    func detach(tab: TabID) {
        destroy(tab)
        if let left = holders.detach(.tab(tab)) { dropIfEphemeral(left) }
    }

    /// `detach(tab:)` for each tab, at once.
    func detach(tabs: [TabID]) {
        for tab in tabs { detach(tab: tab) }
    }

    /// A running download keeps an anonymous tab's store alive past its tab; other stores need no hold.
    func hold(download: UUID, on store: StoreRef) {
        guard case .ephemeral = store else { return }
        holders.attach(.download(download), to: store)
    }

    /// The download has ended; its store goes when nothing else holds it.
    func releaseHold(download: UUID) {
        if let left = holders.detach(.download(download)) { dropIfEphemeral(left) }
    }

    func isHeld(_ store: StoreRef) -> Bool { holders.isHeld(store) }

    /// The store's data store when one was made and not dropped since; never makes one.
    func existingDataStore(for ref: StoreRef) -> WKWebsiteDataStore? { stores[ref] }

    /// The session a tab on `ref` fetches favicons on: an anonymous tab's store has one of its own, every other
    /// store shares `FaviconLoader.shared`.
    func faviconSession(for ref: StoreRef) -> URLSession {
        guard case .ephemeral = ref else { return FaviconLoader.shared }
        if let session = faviconSessions[ref] { return session }
        let session = FaviconLoader.makeSession()
        faviconSessions[ref] = session
        return session
    }

    private func dropIfEphemeral(_ ref: StoreRef) {
        guard case .ephemeral = ref else { return }
        faviconSessions.removeValue(forKey: ref)?.invalidateAndCancel()
        fingerprints[ref] = nil
        plainHTTPHosts[ref] = nil
        if let store = stores.removeValue(forKey: ref) {
            Task {
                await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            }
        }
        storeDropped(ref)
    }

    /// Destroys the tab's view like `destroy`, returning its `interactionState` first so a rebuilt view can pick
    /// up where it was.
    func release(_ tab: TabID) -> Any? {
        let state = views[tab]?.interactionState
        destroy(tab)
        return state
    }

    /// Destroys the tab's view only; the tab still holds its store (a released tab).
    func destroy(_ tab: TabID) {
        viewStores[tab] = nil
        guard let view = views.removeValue(forKey: tab) else { return }
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.removeFromSuperview()
    }

    func hasViews(on store: StoreRef) -> Bool { viewStores.values.contains(store) }

    /// Drops the cached data store of a workspace whose tabs and views are all gone; Default's stays.
    func forget(store: StoreRef) {
        guard store != .global, !isHeld(store), !hasViews(on: store) else { return }
        stores[store] = nil
    }

    /// Deletes a custom workspace's website data store from disk; it must not be in use.
    static func removeWebsiteData(for id: UUID) async throws {
        try await WKWebsiteDataStore.remove(forIdentifier: id)
    }

    #if DEBUG
        /// Layout self-checks only: a local scheme every new configuration serves, so a check can send a form with no
        /// network. Never set outside a self-check, and absent from release builds.
        static var selfCheckScheme: (name: String, handler: any WKURLSchemeHandler)?
    #endif

    /// An anonymous tab's store's fingerprint settings, made fresh the first time they are asked for and kept until
    /// the store is dropped; nil for every other store, whose settings are its workspace's (D3).
    func fingerprint(for ref: StoreRef) -> FingerprintSettings? {
        guard case .ephemeral = ref else { return nil }
        if let settings = fingerprints[ref] { return settings }
        let settings = FingerprintSettings.fresh()
        fingerprints[ref] = settings
        return settings
    }

    /// Turns an anonymous tab's store's protection off (or back on) for `site` (D7), in memory only, for the tab and
    /// its popups; every other store changes nothing, its exceptions being its workspace's.
    func setFingerprint(off: Bool, _ site: String, for ref: StoreRef) {
        guard case .ephemeral = ref, var settings = fingerprint(for: ref) else { return }
        settings.setOff(off, site)
        fingerprints[ref] = settings
    }

    /// The plain-http hosts tabs on `ref` load without a warning (D8).
    func plainHTTPHosts(for ref: StoreRef) -> Set<String> { plainHTTPHosts[ref] ?? [] }

    /// Tabs on `ref` load plain-http pages at `host` without a warning until Lodge quits, or for an anonymous tab's
    /// store until it is dropped; a store nothing holds any more keeps nothing.
    func allowPlainHTTP(_ host: String, for ref: StoreRef) {
        if case .ephemeral = ref, !isHeld(ref) { return }
        plainHTTPHosts[ref, default: []].insert(host)
    }

    /// A configuration on the store's data store, with the work and fingerprint handlers (`addHandlers`).
    private func newConfiguration(for ref: StoreRef, model: BrowserModel) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore(for: ref)
        config.preferences.isElementFullscreenEnabled = true
        config.applicationNameForUserAgent = Self.userAgentApplicationName
        #if DEBUG
            if let check = Self.selfCheckScheme { config.setURLSchemeHandler(check.handler, forURLScheme: check.name) }
        #endif
        Self.addHandlers(to: config.userContentController, model: model)
        return config
    }

    /// Registers, once per content controller, the work script's handler (D3), the fingerprint relay's (D4) and the
    /// video probe's (#36), each in its script's content world, all reporting to `model`. Removing user scripts keeps
    /// them.
    private static func addHandlers(to controller: WKUserContentController, model: BrowserModel) {
        controller.add(
            PageWorkHandler(model: model), contentWorld: .world(name: PageWorkScript.worldName),
            name: PageWorkScript.handlerName)
        controller.add(
            FingerprintHandler(model: model), contentWorld: .world(name: FingerprintScript.worldName),
            name: FingerprintScript.handlerName)
        controller.add(
            VideoHandler(model: model), contentWorld: .world(name: VideoPopOutScript.worldName),
            name: VideoPopOutScript.handlerName)
    }

    /// The store's data store, cached until `forget(store:)` or, for an anonymous tab's, until its last holder goes.
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
}

/// Hands the work script's messages to the model of the tab whose view sent them, its place messages only from the
/// main frame. The content controller keeps its
/// handlers alive as long as the configuration, so the model is held weakly.
@MainActor
private final class PageWorkHandler: NSObject, WKScriptMessageHandler {
    private weak var model: BrowserModel?

    init(model: BrowserModel) {
        self.model = model
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let view = message.webView else { return }
        if let signal = PageWorkScript.signal(from: message.body) {
            model?.didReceiveWork(signal, from: view)
        } else if message.frameInfo.isMainFrame, let place = PageWorkScript.place(from: message.body) {
            model?.didReceivePlace(place, from: view)
        }
    }
}

/// Hands the fingerprint relay's reports (D4), from any frame, to the model of the tab whose view sent them, held
/// weakly like `PageWorkHandler`'s.
@MainActor
private final class FingerprintHandler: NSObject, WKScriptMessageHandler {
    private weak var model: BrowserModel?

    init(model: BrowserModel) {
        self.model = model
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let view = message.webView, let api = FingerprintScript.api(from: message.body) else { return }
        model?.didReadFingerprint(api, from: view)
    }
}

/// Hands the video probe's reports (#36), from any frame, with that frame, to the model of the tab whose view sent
/// them, held weakly like `PageWorkHandler`'s.
@MainActor
private final class VideoHandler: NSObject, WKScriptMessageHandler {
    private weak var model: BrowserModel?

    init(model: BrowserModel) {
        self.model = model
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let view = message.webView, let video = VideoPopOutScript.message(from: message.body) else { return }
        model?.didReceiveVideo(video, in: message.frameInfo, from: view)
    }
}
