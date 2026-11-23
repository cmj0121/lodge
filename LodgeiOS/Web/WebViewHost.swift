import LodgeKit
import SwiftUI
import WebKit

/// Shows one tab's web view, built by the pool when the tab has none yet.
struct WebViewHost: UIViewRepresentable {
    let tab: TabID
    let pool: WebViewPool

    func makeUIView(context: Context) -> WebViewContainer {
        WebViewContainer()
    }

    func updateUIView(_ container: WebViewContainer, context: Context) {
        let pool = pool
        let tab = tab
        container.source = { pool.view(for: tab) }
        container.claim()
    }
}

/// Holds a tab's web view while it is on screen. A web view has one superview, and SwiftUI may build more than one
/// host for the same page (a split view keeps hidden columns), so only a container in a window takes the view.
final class WebViewContainer: UIView {
    var source: (() -> WKWebView)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        claim()
    }

    func claim() {
        guard window != nil, let view = source?(), view.superview !== self else { return }
        subviews.forEach { $0.removeFromSuperview() }
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
