import AppKit
import LodgeKit
import WebKit

/// The mini player's floating panel; `WebViewContainer` never takes a view out of one.
final class MiniPlayerPanel: NSPanel {}

/// Lodge's own picture in picture (#36, D3): one floating panel, at most, holding the web view of a tab that was left
/// while its video played, the video filling the panel (`VideoPopOutScript`). The tab keeps its view, never reloaded;
/// while here it is held awake (`BrowserModel.isHeldNow`) and shown in no window. Its title names the page's site, and
/// the page leaving its document sends the view back (`BrowserModel.mainFrameLeavesDocument`), so the panel, above
/// every window, never shows a page other than the one the video played on.
@MainActor
final class MiniPlayer: NSObject, NSWindowDelegate {
    /// The tab whose view the panel holds; nil while the panel is closed.
    private(set) var tab: TabID?
    private weak var view: WKWebView?
    /// The frames that marked an element while filling, to unfill.
    private var filled: [WKFrameInfo] = []
    /// The hop the next relay must carry, from the frame that posted it; nil once accepted, or when none is due.
    private var hop: VideoPopOutScript.Hop?
    private var panel: MiniPlayerPanel?
    /// Told with the tab once its view has left the panel, by `takeBack()` or `close()`, so its hold is looked at
    /// again.
    var didRelease: (TabID) -> Void = { _ in }
    /// Told with the tab and a frame a fill found no longer exists, so its report goes.
    var didFindFrameGone: (TabID, WKFrameInfo) -> Void = { _, _ in }
    private static var world: WKContentWorld { .world(name: VideoPopOutScript.worldName) }
    #if DEBUG
        /// Layout self-checks: where the panel opens in place of a screen corner, so a check stays off screen.
        static var selfCheckOrigin: NSPoint?
    #endif

    static let width: CGFloat = 480
    private static let inset: CGFloat = 20

    /// Moves `view` into the panel and has the video in `frame` fill it, keeping `aspect` (the video's size) when
    /// known; a tab already here is closed first. The panel opens in the bottom-right corner of `screen` and never
    /// takes focus.
    func show(view: WKWebView, for tab: TabID, frame: WKFrameInfo, aspect: NSSize? = nil, on screen: NSScreen? = nil) {
        if self.tab != nil { close() }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let ratio = aspect.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? NSSize(width: 16, height: 9)
        let size = NSSize(width: Self.width, height: (Self.width * ratio.height / ratio.width).rounded())
        panel.contentAspectRatio = ratio
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: panel.frame.size, on: screen))
        self.tab = tab
        self.view = view
        let title = Self.title(for: view.url)
        panel.title = title
        panel.setAccessibilityLabel(title)
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = panel.contentView?.bounds ?? NSRect(origin: .zero, size: size)
        view.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(view)
        panel.orderFront(nil)
        filled = [frame]
        let first = VideoPopOutScript.Hop(childOrigin: Self.origin(of: frame))
        hop = first
        run(VideoPopOutScript.fill, ["key": first.key, "nonce": first.token], in: frame, of: view, for: tab)
    }

    /// "Mini Player — example.com": the panel names the registrable domain of the page in it (any other scheme's
    /// host), or nothing when it has none.
    static func title(for url: URL?) -> String {
        guard let url, let site = RegistrableDomain.of(url) ?? url.host(), !site.isEmpty else {
            return String(localized: "Mini Player")
        }
        return String(localized: "Mini Player — \(site)")
    }

    /// A frame of the view in the panel relayed the hop its iframe posted (`VideoPopOutScript`): accepted once, when
    /// it carries the due hop's token from the frame that posted it, that frame marks the iframe and posts a fresh hop
    /// on up.
    func relay(token: String, from origin: String, in frame: WKFrameInfo, of view: WKWebView) {
        guard let tab, view === self.view, let due = hop, due.accepts(token: token, from: origin) else { return }
        let next = VideoPopOutScript.Hop(childOrigin: Self.origin(of: frame))
        hop = next
        filled.append(frame)
        run(
            VideoPopOutScript.pass, ["token": token, "key": next.key, "nonce": next.token], in: frame, of: view,
            for: tab)
    }

    /// Runs a fill step in `frame`; a frame that no longer exists is told about.
    private func run(_ body: String, _ arguments: [String: Any], in frame: WKFrameInfo, of view: WKWebView, for tab: TabID) {
        view.callAsyncJavaScript(body, arguments: arguments, in: frame, in: Self.world) { [weak self] result in
            MainActor.assumeIsolated {
                guard case .failure(let error) = result, (error as? WKError)?.code == .javaScriptInvalidFrameTarget
                else { return }
                self?.didFindFrameGone(tab, frame)
            }
        }
    }

    private static func origin(of frame: WKFrameInfo) -> String {
        let origin = frame.securityOrigin
        return VideoPopOutScript.Hop.origin(protocol: origin.protocol, host: origin.host, port: origin.port)
    }

    /// The tab is shown again: its view leaves the panel with its page as it was, still playing, for its window to
    /// take; nil when the panel holds none.
    @discardableResult
    func takeBack() -> WKWebView? {
        guard let tab else { return nil }
        let view = self.view
        detach()
        didRelease(tab)
        return view
    }

    /// Pauses the video and closes the panel; the view goes back to its tab, shown nowhere until the tab is.
    func close() {
        guard let tab else { return }
        view?.pauseAllMediaPlayback()
        detach()
        didRelease(tab)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    private func detach() {
        if let view {
            for frame in filled {
                view.callAsyncJavaScript(VideoPopOutScript.unfill, arguments: [:], in: frame, in: Self.world)
            }
            if view.window === panel { view.removeFromSuperview() }
        }
        view = nil
        filled = []
        hop = nil
        tab = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> MiniPlayerPanel {
        let panel = MiniPlayerPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 270),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered,
            defer: true)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentMinSize = NSSize(width: 200, height: 112)
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.black.cgColor
        panel.delegate = self
        return panel
    }

    private func origin(for size: NSSize, on screen: NSScreen?) -> NSPoint {
        #if DEBUG
            if let origin = Self.selfCheckOrigin { return origin }
        #endif
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        return NSPoint(x: visible.maxX - size.width - Self.inset, y: visible.minY + Self.inset)
    }
}
