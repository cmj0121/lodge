import LodgeKit
import SwiftUI
import WebKit

/// Shows one tab's web view, built by the pool when the tab has none yet. `obscuredBottom` is how much of the view's
/// foot floating chrome covers: the page scrolls under it, but its end and its fixed footers stay above it.
struct WebViewHost: UIViewRepresentable {
    let tab: TabID
    let pool: WebViewPool
    var obscuredBottom: CGFloat = 0

    func makeUIView(context: Context) -> WebViewContainer {
        WebViewContainer()
    }

    func updateUIView(_ container: WebViewContainer, context: Context) {
        let pool = pool
        let tab = tab
        container.source = { pool.view(for: tab) }
        container.obscuredBottom = obscuredBottom
        container.claim()
    }
}

/// Holds a tab's web view while it is on screen. A web view has one superview, and SwiftUI may build more than one
/// host for the same page (a split view keeps hidden columns), so only a container in a window takes the view.
final class WebViewContainer: UIView {
    var source: (() -> WKWebView)?
    var obscuredBottom: CGFloat = 0 {
        didSet { applyInsets() }
    }

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
        Self.inset(view, by: obscuredBottom)
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// The obscured inset moves the layout viewport, so fixed footers sit above the chrome; the scroll inset lets
    /// the page's end scroll up past it.
    private static func inset(_ view: WKWebView, by bottom: CGFloat) {
        view.obscuredContentInsets.bottom = bottom
        view.scrollView.contentInset.bottom = bottom
        view.scrollView.verticalScrollIndicatorInsets.bottom = bottom
    }

    private func applyInsets() {
        guard let view = subviews.first as? WKWebView, view.obscuredContentInsets.bottom != obscuredBottom else { return }
        Self.inset(view, by: obscuredBottom)
    }
}
