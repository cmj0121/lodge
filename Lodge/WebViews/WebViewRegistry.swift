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

    /// Destroys the tab's view like `destroy`, returning its `interactionState` first so a rebuilt view can pick
    /// up where it was.
    func release(_ tab: TabID) -> Any? {
        let state = views[tab]?.interactionState
        destroy(tab)
        return state
    }

    func destroy(_ tab: TabID) {
        viewStores[tab] = nil
        guard let view = views.removeValue(forKey: tab) else { return }
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.removeFromSuperview()
    }

    func destroyAll(on store: StoreRef) {
        for (tab, ref) in viewStores where ref == store { destroy(tab) }
    }

    func hasViews(on store: StoreRef) -> Bool { viewStores.values.contains(store) }

    /// Drops the cached data store of a workspace whose views are all gone; Default's stays.
    func forget(store: StoreRef) {
        guard store != .global, !hasViews(on: store) else { return }
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

    /// The store's data store, cached until `forget(store:)`.
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
