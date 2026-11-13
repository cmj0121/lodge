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
    /// Called with an anonymous tab's store once it is dropped, so what was kept for it goes too.
    var storeDropped: @MainActor (StoreRef) -> Void = { _ in }

    func webView(for tab: TabID) -> LodgeWebView? { views[tab] }

    /// A new web view for `tab` on `store`, or on `configuration` when WebKit hands one over in
    /// `createWebViewWith` (the popup keeps its opener's store, D3), shown at the tab's page `zoom`.
    func make(
        for tab: TabID, store: StoreRef, configuration: WKWebViewConfiguration? = nil, zoom: Double = PageZoom.actual
    ) -> LodgeWebView {
        let config = configuration ?? newConfiguration(for: store)
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

    private func newConfiguration(for ref: StoreRef) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore(for: ref)
        config.preferences.isElementFullscreenEnabled = true
        return config
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
