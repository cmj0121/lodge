import AppKit
import LodgeKit
import WebKit

/// The mini player's floating panel: borderless and never key, so it takes no focus; `WebViewContainer` never takes a
/// view out of one.
final class MiniPlayerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lodge's own picture in picture (#36, D3): one floating panel, at most, holding the web view of a tab that was left
/// while its video played, only the video showing, whole (`VideoPopOutScript`). The tab keeps its view, never
/// reloaded; while here it is held awake (`BrowserModel.isHeldNow`) and shown in no window.
///
/// The panel is one borderless widget with no system chrome (`MiniPlayerControls`): dragging the video moves it,
/// dragging an edge or corner resizes it at the video's aspect ratio, a click plays or pauses, and hovering shows
/// Lodge's own close button and a caption naming the page's site, which also shows for a moment whenever the panel
/// opens and is its accessibility label and (unshown) title. With the page leaving its document sending the view back
/// (`BrowserModel.mainFrameLeavesDocument`), the panel, above every window, never shows a page other than the one the
/// video played on, nor without saying whose it is.
@MainActor
final class MiniPlayer: NSObject {
    /// The tab whose view the panel holds; nil while the panel is closed.
    private(set) var tab: TabID?
    private weak var view: WKWebView?
    /// The frames that marked an element while filling, to unfill.
    private var filled: [WKFrameInfo] = []
    /// The hop the next relay must carry, from the frame that posted it; nil once accepted, or when none is due.
    private var hop: VideoPopOutScript.Hop?
    private var panel: MiniPlayerPanel?
    private var controls: MiniPlayerControls?
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
    static let minWidth: CGFloat = 240
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
        controls?.site = Self.site(of: view.url) ?? title
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = panel.contentView?.bounds ?? NSRect(origin: .zero, size: size)
        view.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(view, positioned: .below, relativeTo: controls)
        panel.orderFront(nil)
        controls?.reveal()
        filled = [frame]
        let first = VideoPopOutScript.Hop(childOrigin: Self.origin(of: frame))
        hop = first
        run(VideoPopOutScript.fill, ["key": first.key, "nonce": first.token], in: frame, of: view, for: tab)
    }

    /// "Mini Player — example.com": the panel names the registrable domain of the page in it (any other scheme's
    /// host), or nothing when it has none.
    static func title(for url: URL?) -> String {
        guard let site = site(of: url) else { return String(localized: "Mini Player") }
        return String(localized: "Mini Player — \(site)")
    }

    /// The registrable domain of `url` (any other scheme's host); nil when it has none.
    static func site(of url: URL?) -> String? {
        guard let url, let site = RegistrableDomain.of(url) ?? url.host(), !site.isEmpty else { return nil }
        return site
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

    /// A click on the video: it plays or pauses, in the frame it plays in.
    fileprivate func togglePlayback() {
        guard let tab, let view, let frame = filled.first else { return }
        run(VideoPopOutScript.togglePlayback, [:], in: frame, of: view, for: tab)
    }

    /// The panel's frame dragged by `edges` through `delta` from `start`, at the panel's aspect ratio, on its screen.
    func resize(from start: NSRect, edges: MiniPlayerFrame.Edges, by delta: CGVector) {
        guard let panel else { return }
        var bounds = (panel.screen ?? NSScreen.main)?.visibleFrame ?? start.insetBy(dx: -10_000, dy: -10_000)
        #if DEBUG
            // A self-check's panel stays where it opened, off screen.
            if Self.selfCheckOrigin != nil { bounds = start.insetBy(dx: -10_000, dy: -10_000) }
        #endif
        let frame = MiniPlayerFrame.resized(
            start, edges: edges, by: delta, aspect: panel.contentAspectRatio, minWidth: Self.minWidth, within: bounds)
        panel.setFrame(frame, display: true)
    }

    #if DEBUG
        /// Layout self-checks: the panel's own close button, the site caption's text and whether both show.
        var closeButton: NSButton? { controls?.closeButton }
        var caption: String? { controls?.site }
        var areControlsShown: Bool { controls?.isRevealed == true }
    #endif

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
            styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentMinSize = NSSize(width: Self.minWidth, height: 135)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        content.layer?.cornerRadius = 10
        content.layer?.masksToBounds = true
        panel.contentView = content
        let controls = MiniPlayerControls(player: self)
        controls.frame = content.bounds
        controls.autoresizingMask = [.width, .height]
        content.addSubview(controls)
        self.controls = controls
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

/// The mini player's own controls, over the whole video: a drag moves the panel, or resizes it from within `margin` of
/// an edge; a click plays or pauses. Hovering shows the close button and the site caption, which fade out again
/// after the pointer leaves, and show for `revealTime` whenever the panel opens.
@MainActor
final class MiniPlayerControls: NSView {
    private weak var player: MiniPlayer?
    let closeButton: NSButton
    private let caption = NSTextField(labelWithString: "")
    private let captionBackground = NSVisualEffectView()
    private var isHovered = false
    private var revealUntil = Date.distantPast
    private var drag: (start: NSPoint, frame: NSRect, edges: MiniPlayerFrame.Edges, moved: Bool)?
    private static let margin: CGFloat = 8
    private static let revealTime: TimeInterval = 2.5

    var site: String {
        get { caption.stringValue }
        set {
            caption.stringValue = newValue
            caption.setAccessibilityLabel(newValue)
            needsLayout = true
        }
    }

    var isRevealed: Bool { !closeButton.isHidden }

    init(player: MiniPlayer) {
        self.player = player
        let image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil) ?? NSImage()
        closeButton = NSButton(image: image, target: nil, action: nil)
        super.init(frame: .zero)
        closeButton.isBordered = false
        closeButton.imageScaling = .scaleProportionallyUpOrDown
        closeButton.contentTintColor = .white
        closeButton.setAccessibilityLabel(String(localized: "Close Mini Player"))
        closeButton.toolTip = String(localized: "Close Mini Player")
        closeButton.target = self
        closeButton.action = #selector(closePanel)
        closeButton.frame = NSRect(x: 8, y: 0, width: 22, height: 22)
        closeButton.autoresizingMask = [.minYMargin]
        addSubview(closeButton)
        captionBackground.material = .hudWindow
        captionBackground.blendingMode = .withinWindow
        captionBackground.state = .active
        captionBackground.wantsLayer = true
        captionBackground.layer?.cornerRadius = 6
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        caption.textColor = .white
        caption.lineBreakMode = .byTruncatingMiddle
        captionBackground.addSubview(caption)
        addSubview(captionBackground)
        setRevealed(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        closeButton.setFrameOrigin(NSPoint(x: 8, y: bounds.height - 30))
        let size = caption.intrinsicContentSize
        let width = min(size.width, bounds.width - 32)
        captionBackground.frame = NSRect(x: 8, y: 8, width: width + 12, height: size.height + 6)
        caption.frame = NSRect(x: 6, y: 3, width: width, height: size.height)
    }

    /// The panel is never key, where AppKit's cursor rects apply, so the area is active always, sets the cursor
    /// itself (`cursorUpdate`, `mouseMoved`) and starts inside when the pointer already is.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        var options: NSTrackingArea.Options = [
            .mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect,
        ]
        if isPointerInside { options.insert(.assumeInside) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self))
    }

    private var isPointerInside: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// The cursor for the point: a resize cursor at an edge or corner, an open hand over the rest of the video.
    static func cursor(for edges: MiniPlayerFrame.Edges) -> NSCursor {
        let position: NSCursor.FrameResizePosition? =
            switch edges {
            case [.left, .top]: .topLeft
            case [.right, .top]: .topRight
            case [.left, .bottom]: .bottomLeft
            case [.right, .bottom]: .bottomRight
            case .left: .left
            case .right: .right
            case .top: .top
            case .bottom: .bottom
            default: nil
            }
        return position.map { NSCursor.frameResize(position: $0, directions: .all) } ?? .openHand
    }

    private func updateCursor(at locationInWindow: NSPoint) {
        guard drag == nil else { return }
        let point = convert(locationInWindow, from: nil)
        Self.cursor(for: MiniPlayerFrame.edges(at: point, in: bounds.size, margin: Self.margin)).set()
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(at: event.locationInWindow) }

    override func mouseMoved(with event: NSEvent) {
        if !isHovered {
            isHovered = true
            setRevealed(true)
        }
        updateCursor(at: event.locationInWindow)
    }

    /// Shows the close button and caption now, for `revealTime` even without the pointer over the panel.
    func reveal() {
        revealUntil = Date.now.addingTimeInterval(Self.revealTime)
        isHovered = isPointerInside
        setRevealed(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealTime + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.hideUnlessHovered() }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        setRevealed(true)
        updateCursor(at: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        if drag == nil { NSCursor.arrow.set() }
        hideUnlessHovered()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        let edges = MiniPlayerFrame.edges(at: point, in: bounds.size, margin: Self.margin)
        drag = (NSEvent.mouseLocation, window.frame, edges, false)
        if edges.isEmpty { NSCursor.closedHand.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard var drag, let window else { return }
        let now = NSEvent.mouseLocation
        let delta = CGVector(dx: now.x - drag.start.x, dy: now.y - drag.start.y)
        if !drag.moved, hypot(delta.dx, delta.dy) < 3 { return }
        drag.moved = true
        self.drag = drag
        if drag.edges.isEmpty {
            window.setFrameOrigin(NSPoint(x: drag.frame.minX + delta.dx, y: drag.frame.minY + delta.dy))
        } else {
            player?.resize(from: drag.frame, edges: drag.edges, by: delta)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if drag?.moved == false, drag?.edges.isEmpty == true { player?.togglePlayback() }
        drag = nil
        updateCursor(at: event.locationInWindow)
    }

    @objc private func closePanel() { player?.close() }

    private func hideUnlessHovered() {
        if !isHovered, Date.now >= revealUntil { setRevealed(false) }
    }

    private func setRevealed(_ shown: Bool) {
        closeButton.isHidden = !shown
        captionBackground.isHidden = !shown
        needsLayout = true
    }
}
