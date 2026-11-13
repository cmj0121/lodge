import AppKit
import LodgeKit
import WebKit

/// Owns every tab's WKWebView (D8). SwiftUI only ever shows what this hands out.
@MainActor
final class WebViewRegistry {
    private var stores: [StoreRef: WKWebsiteDataStore] = [:]
    private var views: [TabID: LodgeWebView] = [:]

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
        return view
    }

    func destroy(_ tab: TabID) {
        guard let view = views.removeValue(forKey: tab) else { return }
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.removeFromSuperview()
    }

    private func newConfiguration(for ref: StoreRef) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore(for: ref)
        config.preferences.isElementFullscreenEnabled = true
        return config
    }

    private func dataStore(for ref: StoreRef) -> WKWebsiteDataStore {
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
