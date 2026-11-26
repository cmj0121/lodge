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
/// Lodge's own close button, a caption naming the page's site and the player's controls (D5), which also show for a
/// moment whenever the panel opens; the caption is its accessibility label and (unshown) title. The controls reach the
/// video through `perform(_:_:)`, polling its playback only while they show. With the page leaving its document sending the view back
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
    /// Asks the video for its playback while the controls show.
    private var poll: Timer?
    /// The video's size as last known, which the panel's aspect ratio follows.
    private var videoSize: NSSize?
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
        let span = Performance.begin("miniPlayerShow")
        defer { span.end() }
        if self.tab != nil { close() }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let ratio = aspect.flatMap(MiniPlayerFrame.aspect(of:)) ?? NSSize(width: 16, height: 9)
        let size = MiniPlayerFrame.sized(
            width: Self.width, aspect: ratio, minHeight: panel.contentMinSize.height,
            within: screenBounds(of: screen ?? NSScreen.main, around: panel.frame))
        panel.contentAspectRatio = ratio
        videoSize = ratio
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
        filled = [frame]
        let first = VideoPopOutScript.Hop(childOrigin: Self.origin(of: frame))
        hop = first
        run(VideoPopOutScript.fill, ["key": first.key, "nonce": first.token], in: frame, of: view, for: tab)
        controls?.reveal()
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
        let span = Performance.begin("miniPlayerTakeBack")
        defer { span.end() }
        guard let tab else { return nil }
        let view = self.view
        detach()
        didRelease(tab)
        return view
    }

    /// Pauses the video and closes the panel; the view goes back to its tab, shown nowhere until the tab is.
    func close() {
        let span = Performance.begin("miniPlayerClose")
        defer { span.end() }
        guard let tab else { return }
        view?.pauseAllMediaPlayback()
        detach()
        didRelease(tab)
    }

    /// A click on the video: it plays or pauses, in the frame it plays in.
    fileprivate func togglePlayback() { perform(VideoPopOutScript.togglePlayback) }

    /// Runs a control call (`VideoPopOutScript`) in the frame the video plays in and hands the playback it answers
    /// with to the controls; none hides their transport. A frame that no longer exists is told about.
    func perform(_ body: String, _ arguments: [String: Any] = [:]) {
        guard let tab, let view, let frame = filled.first else { return }
        view.callAsyncJavaScript(body, arguments: arguments, in: frame, in: Self.world) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.tab == tab, self.view === view else { return }
                switch result {
                case .success(let value): self.apply(VideoPopOutScript.Playback.from(value))
                case .failure(let error):
                    self.apply(nil)
                    if (error as? WKError)?.code == .javaScriptInvalidFrameTarget { self.didFindFrameGone(tab, frame) }
                }
            }
        }
    }

    /// Shows `playback` on the controls; a new video size sets the panel's aspect ratio (`MiniPlayerFrame.aspect`),
    /// keeping its width where its screen allows and moving it back onto that screen where its new height would
    /// leave it.
    private func apply(_ playback: VideoPopOutScript.Playback?) {
        controls?.update(playback)
        guard let playback, let panel,
            let size = MiniPlayerFrame.aspect(of: NSSize(width: playback.width, height: playback.height)),
            size != videoSize
        else { return }
        videoSize = size
        panel.contentAspectRatio = size
        var frame = panel.frame
        let bounds = screenBounds(around: frame)
        frame.size = MiniPlayerFrame.sized(
            width: frame.width, aspect: size, minHeight: panel.contentMinSize.height, within: bounds)
        frame.origin.x = max(bounds.minX, min(frame.minX, bounds.maxX - frame.width))
        frame.origin.y = max(bounds.minY, min(frame.minY, bounds.maxY - frame.height))
        panel.setFrame(frame, display: true)
    }

    /// The visible frame of the panel's screen, which the panel keeps within.
    private func screenBounds(around frame: NSRect) -> NSRect {
        screenBounds(of: panel?.screen ?? NSScreen.main, around: frame)
    }

    private func screenBounds(of screen: NSScreen?, around frame: NSRect) -> NSRect {
        #if DEBUG
            // A self-check's panel stays where it opened, off screen.
            if Self.selfCheckOrigin != nil { return frame.insetBy(dx: -10_000, dy: -10_000) }
        #endif
        return screen?.visibleFrame ?? frame.insetBy(dx: -10_000, dy: -10_000)
    }

    /// The controls showed or hid: their playback is asked for every quarter second while they show.
    fileprivate func controlsDidReveal(_ shown: Bool) {
        poll?.invalidate()
        poll = nil
        guard shown, tab != nil else { return }
        perform(VideoPopOutScript.playback)
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.perform(VideoPopOutScript.playback) }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    /// The panel's frame dragged by `edges` through `delta` from `start`, at the panel's aspect ratio, on its screen.
    func resize(from start: NSRect, edges: MiniPlayerFrame.Edges, by delta: CGVector) {
        guard let panel else { return }
        let frame = MiniPlayerFrame.resized(
            start, edges: edges, by: delta, aspect: panel.contentAspectRatio, minWidth: Self.minWidth,
            within: screenBounds(around: start))
        panel.setFrame(frame, display: true)
    }

    #if DEBUG
        /// Layout self-checks: the panel's own close button, the site caption's text and whether both show.
        var closeButton: NSButton? { controls?.closeButton }
        var caption: String? { controls?.site }
        var areControlsShown: Bool { controls?.isRevealed == true }
        /// Control self-checks: the controls themselves.
        var controlBar: MiniPlayerControls? { controls }
        var isPolling: Bool { poll != nil }
    #endif

    private func detach() {
        poll?.invalidate()
        poll = nil
        controls?.conceal()
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
        videoSize = nil
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
/// an edge; a click plays or pauses. Hovering shows the close button, the site caption and the player's controls (D5)
/// over a dark scrim at the top and bottom, so white glyphs read over any video, which fade out again after the
/// pointer leaves, and show for `revealTime` whenever the panel opens. The centre row seeks back 5 s, plays or pauses,
/// seeks forward 5 s and, when the page has one, goes to the next video; the bottom row shows the elapsed time, a bar
/// to click or drag to a time, the total time and a mute toggle. Without a duration (live) the seek controls and the
/// bar hide; when narrow the times go first. The controls take their own clicks, but within `margin` of an edge,
/// which stays resize.
@MainActor
final class MiniPlayerControls: NSView {
    private weak var player: MiniPlayer?
    let closeButton: NSButton
    let backButton = MiniPlayerControls.button("gobackward.5", size: 17, label: String(localized: "Back 5 Seconds"))
    let playButton = MiniPlayerControls.button("pause.fill", size: 26, label: String(localized: "Pause"))
    let forwardButton = MiniPlayerControls.button(
        "goforward.5", size: 17, label: String(localized: "Forward 5 Seconds"))
    let nextButton = MiniPlayerControls.button("forward.end.fill", size: 15, label: String(localized: "Next Video"))
    let muteButton = MiniPlayerControls.button("speaker.wave.2.fill", size: 12, label: String(localized: "Mute"))
    let bar = MiniPlayerScrubBar()
    let elapsedLabel = MiniPlayerControls.timeLabel()
    let totalLabel = MiniPlayerControls.timeLabel()
    private let caption = NSTextField(labelWithString: "")
    private let captionBackground = NSVisualEffectView()
    private let topScrim = MiniPlayerScrim(fromTop: true)
    private let bottomScrim = MiniPlayerScrim(fromTop: false)
    private var isHovered = false
    private var revealUntil = Date.distantPast
    private var drag: (start: NSPoint, frame: NSRect, edges: MiniPlayerFrame.Edges, moved: Bool)?
    /// The video's playback as last shown; nil hides the transport.
    private(set) var playback: VideoPopOutScript.Playback?
    /// The time the bar is being dragged to; while set, polls move neither the bar nor the elapsed time.
    private(set) var scrub: Double?
    /// The time a scrub sought to: polls are not shown until one is within a second of it, or a second has passed.
    private var seekTarget: (time: Double, until: Date)?
    /// What the play and mute buttons show, so a poll redraws them only when it changes.
    private var isPausedShown = false
    private var isMutedShown = false
    private static let margin: CGFloat = 8
    private static let revealTime: TimeInterval = 2.5
    /// The narrowest panel that still shows the times beside the bar.
    private static let timesMinWidth: CGFloat = 300

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
        closeButton = Self.button("xmark.circle.fill", size: 17, label: String(localized: "Close Mini Player"))
        super.init(frame: .zero)
        topScrim.autoresizingMask = [.width, .minYMargin]
        bottomScrim.autoresizingMask = [.width]
        addSubview(topScrim)
        addSubview(bottomScrim)
        for (button, action) in [
            (closeButton, #selector(closePanel)), (backButton, #selector(seekBack)), (playButton, #selector(playOrPause)),
            (forwardButton, #selector(seekForward)), (nextButton, #selector(goToNext)), (muteButton, #selector(toggleMute)),
        ] {
            button.target = self
            button.action = action
            addSubview(button)
        }
        closeButton.frame = NSRect(x: 8, y: 0, width: 22, height: 22)
        bar.controls = self
        addSubview(bar)
        elapsedLabel.alignment = .right
        addSubview(elapsedLabel)
        addSubview(totalLabel)
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

    /// A borderless white SF Symbol button with a soft shadow, so it reads over a bright frame too; it takes the first
    /// click, as the panel is never key.
    private static func button(_ symbol: String, size: CGFloat, label: String) -> NSButton {
        let button = MiniPlayerButton(image: NSImage(), target: nil, action: nil)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.shadowColor = NSColor.black.cgColor
        button.layer?.shadowOpacity = 0.5
        button.layer?.shadowRadius = 3
        button.layer?.shadowOffset = CGSize(width: 0, height: -0.5)
        setSymbol(symbol, size: size, label: label, of: button)
        return button
    }

    private static func setSymbol(_ symbol: String, size: CGFloat, label: String, of button: NSButton) {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(configuration)
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }

    private static func timeLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.88)
        label.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = 2
            return shadow
        }()
        return label
    }

    /// "1:05" or "1:02:05".
    static func time(_ seconds: Double) -> String {
        let total = Int(min(max(0, seconds.isFinite ? seconds : 0), VideoPopOutScript.Playback.maximumSeconds))
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        topScrim.frame = NSRect(x: 0, y: height - 56, width: width, height: 56)
        bottomScrim.frame = NSRect(x: 0, y: 0, width: width, height: max(72, height * 0.55))
        closeButton.frame = NSRect(x: 8, y: height - 30, width: 22, height: 22)
        let size = caption.intrinsicContentSize
        let captionWidth = max(0, min(ceil(size.width) + 2, width - 54))
        captionBackground.frame = NSRect(
            x: 36, y: height - 19 - (size.height + 6) / 2, width: captionWidth + 12, height: size.height + 6)
        caption.frame = NSRect(x: 6, y: 3, width: captionWidth, height: size.height)

        // Play stays centred; with next showing, the buttons close up so next stays clear of the right edge's margin.
        let middle = NSPoint(x: bounds.midX, y: bounds.midY + 4)
        let step = nextButton.isHidden ? 58 : min(58, (width / 2 - Self.margin - 2 - 16) / 2)
        playButton.frame = NSRect(x: middle.x - 22, y: middle.y - 22, width: 44, height: 44)
        backButton.frame = NSRect(x: middle.x - step - 16, y: middle.y - 16, width: 32, height: 32)
        forwardButton.frame = NSRect(x: middle.x + step - 16, y: middle.y - 16, width: 32, height: 32)
        nextButton.frame = NSRect(x: middle.x + 2 * step - 16, y: middle.y - 16, width: 32, height: 32)

        let row: CGFloat = 14
        muteButton.frame = NSRect(x: width - 14 - 22, y: row - 3, width: 22, height: 22)
        let timeWidth = ceil(totalLabel.intrinsicContentSize.width)
        let times = !elapsedLabel.isHidden
        let labelHeight = elapsedLabel.intrinsicContentSize.height
        elapsedLabel.frame = NSRect(x: 14, y: row + 8 - labelHeight / 2, width: timeWidth, height: labelHeight)
        let barStart = times ? elapsedLabel.frame.maxX + 8 : 14
        let barEnd = muteButton.frame.minX - (times ? timeWidth + 16 : 10)
        bar.frame = NSRect(x: barStart, y: row, width: max(0, barEnd - barStart), height: 16)
        totalLabel.frame = NSRect(x: bar.frame.maxX + 8, y: elapsedLabel.frame.minY, width: timeWidth, height: labelHeight)
    }

    /// Shows the video's playback, unless the bar is being dragged (the bar and elapsed time stay on the scrub) or a
    /// scrub's seek has yet to land; nil hides the transport.
    func update(_ playback: VideoPopOutScript.Playback?) {
        var shown = playback
        if let target = seekTarget {
            if let playback, abs(playback.time - target.time) > 1, Date.now < target.until {
                shown?.time = target.time
            } else {
                seekTarget = nil
            }
        }
        if let scrub { shown?.time = scrub }
        self.playback = shown
        refresh()
    }

    /// The bar was pressed or dragged to `fraction` of the video: the bar and elapsed time follow, with no seek yet.
    func moveScrub(to fraction: Double) {
        guard let duration = playback?.duration, playback?.canSeek == true else { return }
        scrub = min(1, max(0, fraction)) * duration
        playback?.time = scrub ?? 0
        refresh()
    }

    /// The bar was let go at `fraction`: one seek there.
    func endScrub(at fraction: Double) {
        moveScrub(to: fraction)
        guard let time = scrub else { return }
        scrub = nil
        seekTarget = (time, Date.now.addingTimeInterval(1))
        player?.perform(VideoPopOutScript.seekTo, ["time": time])
        hideUnlessHovered()
    }

    private func refresh() {
        let transport = isRevealed && playback != nil
        let canSeek = transport && playback?.canSeek == true
        playButton.isHidden = !transport
        muteButton.isHidden = !transport
        backButton.isHidden = !canSeek
        forwardButton.isHidden = !canSeek
        bar.isHidden = !canSeek
        nextButton.isHidden = !(transport && playback?.hasNext == true)
        let times = canSeek && bounds.width >= Self.timesMinWidth
        elapsedLabel.isHidden = !times
        totalLabel.isHidden = !times
        if let playback {
            if playback.isPaused != isPausedShown {
                isPausedShown = playback.isPaused
                Self.setSymbol(
                    isPausedShown ? "play.fill" : "pause.fill", size: 26,
                    label: isPausedShown ? String(localized: "Play") : String(localized: "Pause"), of: playButton)
            }
            if playback.isMuted != isMutedShown {
                isMutedShown = playback.isMuted
                Self.setSymbol(
                    isMutedShown ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 12,
                    label: isMutedShown ? String(localized: "Unmute") : String(localized: "Mute"), of: muteButton)
            }
            let duration = playback.duration ?? 0
            elapsedLabel.stringValue = Self.time(playback.time)
            totalLabel.stringValue = Self.time(duration)
            bar.fraction = duration > 0 ? min(1, playback.time / duration) : 0
            bar.setAccessibilityValue(Self.time(playback.time))
        }
        needsLayout = true
    }

    /// A control takes its own click; within `margin` of an edge, and anywhere else, the panel's drag, resize and
    /// click-to-pause do.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        let local = convert(point, from: superview)
        if !MiniPlayerFrame.edges(at: local, in: bounds.size, margin: Self.margin).isEmpty { return self }
        return hit is NSButton || hit === bar ? hit : self
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

    /// The arrow over a control, else `cursor(for:)`.
    private func updateCursor(at locationInWindow: NSPoint) {
        guard drag == nil else { return }
        if let superview, hitTest(superview.convert(locationInWindow, from: nil)) !== self {
            return NSCursor.arrow.set()
        }
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

    /// Shows the close button, caption and controls now, for `revealTime` even without the pointer over the panel.
    func reveal() {
        revealUntil = Date.now.addingTimeInterval(Self.revealTime)
        isHovered = isPointerInside
        setRevealed(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealTime + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.hideUnlessHovered() }
        }
    }

    /// Hides everything and forgets the playback, as the panel closes.
    func conceal() {
        isHovered = false
        revealUntil = .distantPast
        scrub = nil
        seekTarget = nil
        playback = nil
        setRevealed(false)
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
        hideUnlessHovered()
    }

    @objc private func closePanel() { player?.close() }
    @objc private func seekBack() { player?.perform(VideoPopOutScript.seek, ["by": -5.0]) }
    @objc private func seekForward() { player?.perform(VideoPopOutScript.seek, ["by": 5.0]) }
    @objc private func playOrPause() { player?.perform(VideoPopOutScript.togglePlayback) }
    @objc private func goToNext() { player?.perform(VideoPopOutScript.next) }
    @objc private func toggleMute() { player?.perform(VideoPopOutScript.toggleMute) }

    private func hideUnlessHovered() {
        if !isHovered, Date.now >= revealUntil, drag == nil, scrub == nil { setRevealed(false) }
    }

    private func setRevealed(_ shown: Bool) {
        let changed = shown != isRevealed
        closeButton.isHidden = !shown
        captionBackground.isHidden = !shown
        topScrim.isHidden = !shown
        bottomScrim.isHidden = !shown
        refresh()
        if changed { player?.controlsDidReveal(shown) }
    }
}

/// A mini player button: it takes the first click, as the panel is never key.
private final class MiniPlayerButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The dark wash behind the controls, from the top or bottom edge fading to clear; it takes no clicks.
private final class MiniPlayerScrim: NSView {
    init(fromTop: Bool) {
        super.init(frame: .zero)
        let gradient = CAGradientLayer()
        let black = NSColor.black
        gradient.colors = [
            black.withAlphaComponent(fromTop ? 0.42 : 0.62).cgColor, black.withAlphaComponent(fromTop ? 0.14 : 0.24).cgColor,
            black.withAlphaComponent(0).cgColor,
        ]
        gradient.locations = [0, 0.45, 1]
        gradient.startPoint = CGPoint(x: 0.5, y: fromTop ? 1 : 0)
        gradient.endPoint = CGPoint(x: 0.5, y: fromTop ? 0 : 1)
        layer = gradient
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The mini player's progress bar: a thin track filled to the elapsed time, thicker with a thumb while the pointer is
/// over it or drags it. Pressing or dragging scrubs (`MiniPlayerControls.moveScrub(to:)`), letting go seeks once
/// (`endScrub(at:)`); its clicks never reach the panel.
@MainActor
final class MiniPlayerScrubBar: NSView {
    weak var controls: MiniPlayerControls?
    var fraction: Double = 0 { didSet { needsLayout = true } }
    private let track = CALayer()
    private let fill = CALayer()
    private let thumb = CALayer()
    private var isActive = false { didSet { needsLayout = true } }
    private var isDragging = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        track.backgroundColor = NSColor.white.withAlphaComponent(0.3).cgColor
        fill.backgroundColor = NSColor.white.withAlphaComponent(0.95).cgColor
        thumb.backgroundColor = NSColor.white.cgColor
        thumb.shadowColor = NSColor.black.cgColor
        thumb.shadowOpacity = 0.4
        thumb.shadowRadius = 2
        thumb.shadowOffset = .zero
        for sublayer in [track, fill, thumb] { layer?.addSublayer(sublayer) }
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(String(localized: "Playback Position"))
        toolTip = String(localized: "Playback Position")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let thickness: CGFloat = isActive ? 5 : 3
        let y = (bounds.height - thickness) / 2
        track.frame = NSRect(x: 0, y: y, width: bounds.width, height: thickness)
        track.cornerRadius = thickness / 2
        let filled = bounds.width * fraction
        fill.frame = NSRect(x: 0, y: y, width: filled, height: thickness)
        fill.cornerRadius = thickness / 2
        thumb.frame = NSRect(x: filled - 5, y: bounds.midY - 5, width: 10, height: 10)
        thumb.cornerRadius = 5
        thumb.isHidden = !isActive
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isActive = true }
    override func mouseExited(with event: NSEvent) { isActive = isDragging }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func fraction(of event: NSEvent) -> Double {
        guard bounds.width > 0 else { return 0 }
        return Double(min(1, max(0, convert(event.locationInWindow, from: nil).x / bounds.width)))
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        isActive = true
        controls?.moveScrub(to: fraction(of: event))
    }

    override func mouseDragged(with event: NSEvent) { controls?.moveScrub(to: fraction(of: event)) }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        controls?.endScrub(at: fraction(of: event))
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isActive = inside
    }
}
