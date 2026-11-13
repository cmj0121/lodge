import AppKit
import LodgeKit
import SwiftUI
import WebKit

/// Hosts at most one registry-owned web view; showing another one reparents it here. A view another window's
/// container has taken since is never pulled back out of it by this one letting go.
final class WebViewContainer: NSView {
    private weak var current: WKWebView?

    func show(_ view: WKWebView?) {
        if let current, current !== view, current.superview === self { current.removeFromSuperview() }
        current = view
        guard let view, view.superview !== self else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

/// SwiftUI face of a tab's web view: it wraps a `WebViewContainer` and never creates or frees the view.
struct WebViewHost: NSViewRepresentable {
    let tab: TabID
    @Environment(\.webViewRegistry) private var registry

    func makeNSView(context: Context) -> WebViewContainer { WebViewContainer() }

    func updateNSView(_ container: WebViewContainer, context: Context) {
        container.show(registry?.webView(for: tab))
    }
}

extension EnvironmentValues {
    @Entry var webViewRegistry: WebViewRegistry?
}
