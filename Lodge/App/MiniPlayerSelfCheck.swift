#if DEBUG
    import AppKit
    import LodgeKit
    import SwiftUI
    import WebKit

    extension LayoutRenderer {
        /// The mini player (#36) in real WebKit, off screen, printing ok or FAILED for each. Pages come from the local
        /// `VideoCheckScheme`, a canvas `captureStream` as the video, so nothing goes out and nothing is heard (the
        /// stream has no sound track). The browser window is never ordered in and the panel opens far off screen, so
        /// nothing shows and nothing takes focus. Checked: a playing video's tab reports it; leaving the tab moves its
        /// view to the panel still playing and filling it, held awake, the panel a borderless widget titled with the
        /// page's site, with Lodge's own close button and site caption, resizing at the video's aspect ratio, nothing
        /// the page can see naming Lodge; showing the tab brings it back still playing; a video in a transformed,
        /// clipped player under page chrome shows alone and whole, and the page's layout comes back exactly;
        /// a muted or paused video stays; a video in a cross-origin iframe pops out with its iframe filling the page and
        /// its own video filling the iframe, the top page told nothing naming Lodge; closing the panel pauses and
        /// leaves the tab, closing the tab or its window closes the panel; the page in the panel changing its URL in
        /// the same document stays, as does a navigation that never commits (a 204, a failure), and committing another
        /// document goes back to its tab, shown nowhere, and closes the panel; a sandboxed iframe's video pops out too; switching workspace pops out and holds it, switching back returns it; Anonymous does the
        /// same; deleting a workspace whose tab is in the panel closes the panel, and deleting the active one pops
        /// nothing out. The player's controls: hovering shows them, next only when the page has one; ±5 s seeks within
        /// the video, clamped; play/pause, and mute, which keeps a playing video playing; dragging the bar seeks once,
        /// on letting go; next advances to the page's new video, which the panel keeps showing; and the controls take
        /// their own clicks, the edges and the rest of the video staying the panel's. The stores of the workspaces it
        /// deletes are removed once nothing of the check holds them.
        static func checkMiniPlayer() {
            func report(_ name: String, _ passed: Bool) { print("Mini player: \(name): \(passed ? "ok" : "FAILED")") }
            report(
                "a page's absurd time reads as the longest one, never trapping",
                MiniPlayerControls.time(1e300) == "2777:46:40" && MiniPlayerControls.time(-1) == "0:00"
                    && MiniPlayerControls.time(.infinity) == "0:00")
            let stores = autoreleasepool { checkMiniPlayerInWebKit() }
            var isEveryStoreRemoved = true
            for id in stores {
                var removed = false
                for _ in 0..<20 where !removed {
                    var done = false
                    Task {
                        removed = (try? await WebViewRegistry.removeWebsiteData(for: id)) != nil
                        done = true
                    }
                    while !done { autoreleasepool { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3)) } }
                }
                isEveryStoreRemoved = isEveryStoreRemoved && removed
            }
            report("the deleted workspaces' stores are removed", isEveryStoreRemoved)
        }

        /// The `tube` page's video's box and its player's, as the page lays them out.
        private static let videoBox = """
            (() => {
              const r = (e) => { const b = e.getBoundingClientRect(); return [b.x, b.y, b.width, b.height].join(','); };
              return r(document.getElementById('v')) + ' ' + r(document.getElementById('player'));
            })()
            """

        /// `checkMiniPlayer` in WebKit; returns the workspaces whose store deleting them left behind.
        private static func checkMiniPlayerInWebKit() -> [UUID] {
            func report(_ name: String, _ passed: Bool) { print("Mini player: \(name): \(passed ? "ok" : "FAILED")") }
            func settle(_ seconds: Double = 0.3) {
                autoreleasepool { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
            }
            func waitUntil(_ seconds: Double = 8, _ done: () -> Bool) -> Bool {
                let deadline = Date.now.addingTimeInterval(seconds)
                while !done(), Date.now < deadline { settle(0.05) }
                return done()
            }
            /// The script's value in `frame` (the main frame for nil), in the page's world.
            func pageValue(_ view: WKWebView, _ script: String, in frame: WKFrameInfo? = nil) -> String? {
                var answer: String?
                var done = false
                view.evaluateJavaScript(script, in: frame, in: .page) { result in
                    MainActor.assumeIsolated {
                        answer = (try? result.get()).map { "\($0)" }
                        done = true
                    }
                }
                _ = waitUntil(3) { done }
                return answer
            }
            func isPlaying(_ view: WKWebView) -> Bool {
                waitUntil(3) { pageValue(view, "String(!document.getElementById('v').paused)") == "true" }
            }
            /// The element is fixed over the whole viewport, the document holds no `<style>` element, and none of its
            /// attributes (but the check pages' own `src`) nor its style sheets' rules name Lodge.
            func isFilled(_ view: WKWebView, _ selector: String = "#v", in frame: WKFrameInfo? = nil) -> Bool {
                let script = """
                    (() => {
                      const el = document.querySelector('\(selector)');
                      const box = el.getBoundingClientRect();
                      const named = Array.from(document.querySelectorAll('*')).some((e) =>
                        Array.from(e.attributes).some((a) => /lodge/i.test(a.name === 'src' ? a.name : a.name + a.value)))
                        || Array.from(document.styleSheets).some((s) =>
                          Array.from(s.cssRules).some((r) => /lodge/i.test(r.cssText)));
                      return String(getComputedStyle(el).position === 'fixed' && !named
                        && document.querySelectorAll('style').length === 0 && box.x === 0 && box.y === 0
                        && Math.abs(box.width - innerWidth) < 2 && Math.abs(box.height - innerHeight) < 2);
                    })()
                    """
                return pageValue(view, script, in: frame) == "true"
            }

            /// What the view shows is the `tube` page's video frame alone and whole: its white border at every edge,
            /// its four coloured quadrants where they belong, and none of the page's magenta chrome anywhere.
            func showsOnlyTheCheckVideo(_ view: WKWebView) -> Bool {
                var bitmap: NSBitmapImageRep?
                var done = false
                view.takeSnapshot(with: nil) { image, _ in
                    MainActor.assumeIsolated {
                        bitmap = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                            .map(NSBitmapImageRep.init(cgImage:))
                        done = true
                    }
                }
                guard waitUntil(3, { done }), let bitmap, bitmap.pixelsWide > 0 else { return false }
                typealias RGB = (r: Double, g: Double, b: Double)
                func color(_ x: Double, _ y: Double) -> RGB {
                    let c = bitmap.colorAt(
                        x: Int(x * Double(bitmap.pixelsWide - 1)), y: Int(y * Double(bitmap.pixelsHigh - 1))
                    )?.usingColorSpace(.sRGB)
                    return (Double(c?.redComponent ?? 0), Double(c?.greenComponent ?? 0), Double(c?.blueComponent ?? 0))
                }
                func isWhite(_ c: RGB) -> Bool { c.r > 0.75 && c.g > 0.75 && c.b > 0.75 }
                func isMagenta(_ c: RGB) -> Bool { c.r > 0.6 && c.b > 0.6 && c.g < 0.4 }
                func hue(_ c: RGB) -> String {
                    if c.r > 0.6, c.g > 0.6, c.b < 0.4 { return "yellow" }
                    if c.r > 0.6, c.g < 0.4, c.b < 0.4 { return "red" }
                    if c.g > 0.6, c.r < 0.4, c.b < 0.4 { return "green" }
                    if c.b > 0.6, c.r < 0.4, c.g < 0.4 { return "blue" }
                    return "other"
                }
                let edges = [(0.008, 0.5), (0.992, 0.5), (0.5, 0.012), (0.5, 0.988)]
                let border = edges.allSatisfy { isWhite(color($0.0, $0.1)) }
                let quadrants = hue(color(0.25, 0.25)) == "red" && hue(color(0.75, 0.25)) == "green"
                    && hue(color(0.25, 0.75)) == "blue" && hue(color(0.75, 0.75)) == "yellow"
                let grid = (0...10).flatMap { x in (0...10).map { y in color(Double(x) / 10, Double(y) / 10) } }
                if !(border && quadrants) || grid.contains(where: isMagenta) {
                    print("Mini player: snapshot \(edges.map { color($0.0, $0.1) }) \(hue(color(0.25, 0.25)))")
                }
                return border && quadrants && !grid.contains(where: isMagenta)
            }

            let scheme = VideoCheckScheme()
            WebViewRegistry.selfCheckScheme = (VideoCheckScheme.name, scheme)
            MiniPlayer.selfCheckOrigin = NSPoint(x: -12_000, y: -12_000)
            defer {
                WebViewRegistry.selfCheckScheme = nil
                MiniPlayer.selfCheckOrigin = nil
            }
            let coordinator = WorkspaceCoordinator(restoring: nil, session: nil, appDirectory: nil, downloads: nil)
            coordinator.bringForwardHook = { _ in }
            let player = coordinator.miniPlayer
            let window = coordinator.windows[0]
            let hostWindow = NSWindow(
                contentRect: NSRect(x: -10_000, y: -10_000, width: 1000, height: 700),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            hostWindow.isReleasedWhenClosed = false
            hostWindow.contentView = NSHostingView(rootView: BrowserRoot(coordinator: coordinator, window: window))
            hostWindow.setFrame(NSRect(x: -10_000, y: -10_000, width: 1000, height: 700), display: false)
            var isHostOpen = true
            defer {
                player.close()
                if isHostOpen { hostWindow.close() }
            }
            settle()
            let pane = coordinator.pane(for: window)

            /// Opens `mode`'s page in a new tab of the window's workspace, shown, once loaded.
            func open(_ mode: String, host: String = "top") -> (id: TabID, view: LodgeWebView)? {
                let model = coordinator.active
                let tab = BrowserTab(
                    store: model.newTabStore(), url: URL(string: "\(VideoCheckScheme.name)://\(host)/\(mode)"))
                _ = model.append(tab, load: true)
                coordinator.opened(tab.id, in: model, window: window)
                guard let view = model.view(for: tab.id),
                    waitUntil(8, { view.title == "video-\(mode)" && !view.isLoading && view.window === hostWindow })
                else { return nil }
                return (tab.id, view)
            }
            func reported(_ id: TabID, playing: Bool) -> Bool {
                waitUntil { coordinator.active.video(of: id).hasVideo && coordinator.active.video(of: id).isPlaying == playing }
            }
            func inPanel(_ tab: (id: TabID, view: LodgeWebView)) -> Bool {
                player.tab == tab.id && tab.view.window is MiniPlayerPanel
            }
            /// The tab with no video the window leaves for.
            var rest: TabID?
            /// Leaves the shown tab for `rest`.
            func leave() {
                rest.map(pane.select)
                settle()
            }
            func held(_ model: BrowserModel, _ id: TabID) -> Bool {
                var isAnyHeld: Bool?
                Task { isAnyHeld = await model.release(candidates: [id]) { coordinator.isShown($0) } }
                _ = waitUntil { isAnyHeld != nil }
                return isAnyHeld == true && coordinator.registry.webView(for: id) != nil
            }

            rest = open("still")?.id
            guard rest != nil else {
                report("a page with no video opens", false)
                return []
            }
            guard let sound = open("sound"), reported(sound.id, playing: true) else {
                report("a playing video reports to its tab", false)
                return []
            }
            let state = coordinator.active.video(of: sound.id)
            report("a playing video reports to its tab", !state.isMuted && state.width == 320 && state.height == 180)

            leave()
            report(
                "leaving the tab moves its playing video to the panel, filling it",
                inPanel(sound) && isPlaying(sound.view) && waitUntil(3) { isFilled(sound.view) }
                    && sound.view.window?.isVisible == true && sound.view.window?.isKeyWindow == false
                    && (sound.view.window?.contentAspectRatio).map { abs($0.width / $0.height - 16.0 / 9) < 0.01 } == true)
            report("the tab in the panel is held awake", held(coordinator.active, sound.id) && inPanel(sound))
            let title = sound.view.window?.title ?? ""
            report(
                "the panel's title and accessibility label name the page's site",
                title == MiniPlayer.title(for: sound.view.url) && title.hasSuffix(" top")
                    && title != String(localized: "Mini Player")
                    && sound.view.window?.accessibilityLabel() == title)
            if let panel = sound.view.window {
                report(
                    "the panel is one borderless widget, its own close button and site caption shown as it opens",
                    !panel.styleMask.contains(.titled) && panel.standardWindowButton(.closeButton) == nil
                        && !panel.canBecomeKey && player.areControlsShown && player.closeButton?.isHidden == false
                        && player.caption == MiniPlayer.site(of: sound.view.url) && player.caption == "top")
                let start = panel.frame
                player.resize(from: start, edges: .right, by: CGVector(dx: 160, dy: 0))
                let wider = panel.frame
                player.resize(from: wider, edges: [.left, .bottom], by: CGVector(dx: 160, dy: 90))
                report(
                    "dragging an edge resizes it at the video's aspect ratio, the opposite edges staying put",
                    wider.width == start.width + 160 && wider.minX == start.minX && wider.maxY == start.maxY
                        && abs(wider.width / wider.height - 16.0 / 9) < 0.01
                        && panel.frame.size == start.size && panel.frame.maxX == wider.maxX
                        && panel.frame.maxY == wider.maxY && waitUntil(3) { isFilled(sound.view) })
                panel.setFrame(start, display: false)
            }

            pane.select(sound.id)
            settle()
            report(
                "showing the tab brings its video back, still playing",
                player.tab == nil && waitUntil(3) { sound.view.window === hostWindow } && isPlaying(sound.view)
                    && waitUntil(3) { !isFilled(sound.view) })

            for mode in ["muted", "paused"] {
                guard let tab = open(mode), reported(tab.id, playing: mode == "muted") else {
                    report("a \(mode) video stays in its tab", false)
                    continue
                }
                leave()
                report("a \(mode) video stays in its tab", player.tab != tab.id && tab.view.window == nil)
                coordinator.active.close(tab.id)
            }

            if let framed = open("framed"), reported(framed.id, playing: true) {
                _ = pageValue(
                    framed.view,
                    "window.seen = []; addEventListener('message', (e) => seen.push(JSON.stringify(e.data))); 'ok'")
                leave()
                report(
                    "a video in a cross-origin iframe pops out, its iframe filling the page",
                    inPanel(framed) && waitUntil(3) { isFilled(framed.view, "iframe") })
                let child = coordinator.active.videoFrame(of: framed.id)
                report(
                    "the iframe's own video fills the iframe",
                    child?.isMainFrame == false && waitUntil(3) { isFilled(framed.view, in: child) })
                report(
                    "the top page is posted one hop, naming nothing",
                    pageValue(framed.view, "String(seen.length === 1 && !/lodge/i.test(seen[0]))") == "true")
                pane.select(framed.id)
                settle()
                report(
                    "the iframe's video comes back",
                    framed.view.window === hostWindow && waitUntil(3) { !isFilled(framed.view, "iframe") })
                coordinator.active.close(framed.id)
            } else {
                report("a video in a cross-origin iframe pops out, its iframe filling the page", false)
            }

            if let sandboxed = open("sandboxed"), reported(sandboxed.id, playing: true) {
                leave()
                let child = coordinator.active.videoFrame(of: sandboxed.id)
                report(
                    "a video in a sandboxed iframe pops out, its iframe filling the page",
                    inPanel(sandboxed) && child?.isMainFrame == false && waitUntil(3) { isFilled(sandboxed.view, "iframe") }
                        && waitUntil(3) { isFilled(sandboxed.view, in: child) })
                pane.select(sandboxed.id)
                settle()
                coordinator.active.close(sandboxed.id)
            } else {
                report("a video in a sandboxed iframe pops out, its iframe filling the page", false)
            }

            let alone = "a video in a transformed, clipped player under page chrome shows alone and whole in the panel"
            if let tube = open("tube"), reported(tube.id, playing: true) {
                let before = pageValue(tube.view, Self.videoBox)
                leave()
                report(
                    alone,
                    inPanel(tube) && waitUntil(3) { isFilled(tube.view) }
                        && waitUntil(5) { showsOnlyTheCheckVideo(tube.view) })
                pane.select(tube.id)
                settle()
                report(
                    "the page's layout comes back exactly",
                    before != nil && tube.view.window === hostWindow
                        && waitUntil(3) { pageValue(tube.view, Self.videoBox) == before })
                coordinator.active.close(tube.id)
            } else {
                report(alone, false)
            }

            /// The player's controls on the `seek` page (a silent 30 s file) and the `next` page (one with YouTube's next
            /// button, which swaps in a 20 s video), clicked as a click on them would, the bar dragged by mouse events
            /// sent to it alone.
            func checkControls() {
                let shows = "hovering the panel shows the player's controls, next hidden on a page without one"
                guard let seek = open("seek"), reported(seek.id, playing: true) else { return report(shows, false) }
                leave()
                guard inPanel(seek), let controls = player.controlBar, let panel = seek.view.window else {
                    return report(shows, false)
                }
                func time() -> Double? {
                    pageValue(seek.view, "String(document.getElementById('v').currentTime)").flatMap(Double.init)
                }
                func set(_ script: String) {
                    _ = pageValue(seek.view, "(() => { const v = document.getElementById('v'); \(script); return 'ok'; })()")
                }
                func press(_ button: NSButton) {
                    controls.reveal()
                    button.performClick(nil)
                    settle(0.4)
                }
                func isPaused() -> Bool? {
                    pageValue(seek.view, "String(document.getElementById('v').paused)").map { $0 == "true" }
                }
                func isMuted() -> Bool { pageValue(seek.view, "String(document.getElementById('v').muted)") == "true" }
                controls.reveal()
                let shown = waitUntil(3) { controls.playback?.canSeek == true }
                report(
                    shows,
                    shown && controls.playback?.duration.map { abs($0 - 30) < 0.5 } == true
                        && [controls.backButton, controls.playButton, controls.forwardButton, controls.muteButton]
                            .allSatisfy { !$0.isHidden } && !controls.bar.isHidden && !controls.elapsedLabel.isHidden
                        && controls.nextButton.isHidden && controls.playback?.hasNext == false)

                set("v.currentTime = 10")
                press(controls.forwardButton)
                let forward = time()
                press(controls.backButton)
                press(controls.backButton)
                let back = time()
                set("v.currentTime = 1")
                press(controls.backButton)
                let start = time()
                set("v.currentTime = 28")
                press(controls.forwardButton)
                let end = time()
                let seeks = forward.map { (14.8...16.2).contains($0) } == true && back.map { (4.8...7).contains($0) } == true
                    && start.map { (0...0.8).contains($0) } == true && end.map { (29.5...30.01).contains($0) } == true
                if !seeks { print("Mini player: seeks \(String(describing: [forward, back, start, end]))") }
                report("±5 s seeks the video, clamped to its start and end", seeks)
                set("v.currentTime = 5; v.play()")
                _ = waitUntil(3) { isPaused() == false }

                press(controls.playButton)
                let paused = waitUntil(3) { isPaused() == true }
                press(controls.playButton)
                report("the play button pauses and plays", paused && waitUntil(3) { isPaused() == false })

                press(controls.muteButton)
                let muted = waitUntil(3) { isMuted() } && isPaused() == false && controls.playback?.isMuted == true
                press(controls.muteButton)
                settle(0.5)
                report(
                    "mute toggles, and a playing video keeps playing after unmuting",
                    muted && !isMuted() && isPaused() == false && controls.playback?.isMuted == false)

                set("v.currentTime = 2")
                controls.reveal()
                controls.layoutSubtreeIfNeeded()
                let frame = panel.frame
                let bar = controls.bar
                func event(_ type: NSEvent.EventType, at fraction: Double, in view: NSView? = nil) -> NSEvent? {
                    let view = view ?? bar
                    let point = view.convert(NSPoint(x: view.bounds.width * fraction, y: view.bounds.midY), to: nil)
                    return NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                }
                event(.leftMouseDown, at: 0.25).map(bar.mouseDown)
                event(.leftMouseDragged, at: 0.5).map(bar.mouseDragged)
                settle(0.6)
                let during = time()
                let held = controls.scrub.map { abs($0 - 15) < 0.01 } == true
                    && controls.elapsedLabel.stringValue == "0:15" && controls.playback?.time == 15
                event(.leftMouseUp, at: 0.5).map(bar.mouseUp)
                report(
                    "dragging the bar moves it alone, then seeks once on letting go, the video still playing",
                    held && during.map { $0 < 5 } == true && waitUntil(3) { time().map { abs($0 - 15) < 1 } == true }
                        && controls.scrub == nil && isPaused() == false && panel.frame == frame)

                controls.reveal()
                event(.leftMouseDown, at: 0.6).map(bar.mouseDown)
                settle(3)
                let keptWhileScrubbing = controls.isRevealed && player.isPolling
                event(.leftMouseUp, at: 0.6).map(bar.mouseUp)
                let hidAfterScrub = !controls.isRevealed && !player.isPolling
                controls.reveal()
                let edge = 3 / controls.bounds.width
                event(.leftMouseDown, at: edge, in: controls).map(controls.mouseDown)
                settle(3)
                let keptWhileResizing = controls.isRevealed && player.isPolling
                event(.leftMouseUp, at: edge, in: controls).map(controls.mouseUp)
                report(
                    "a scrub or resize ending with the pointer outside hides the controls and stops asking for playback",
                    keptWhileScrubbing && hidAfterScrub && keptWhileResizing && !controls.isRevealed
                        && !player.isPolling && isPaused() == false && panel.frame == frame)

                controls.reveal()
                controls.layoutSubtreeIfNeeded()
                let superview = controls.superview
                func center(_ view: NSView) -> NSPoint {
                    controls.convert(NSPoint(x: view.frame.midX, y: view.frame.midY), to: superview)
                }
                let bounds = controls.bounds
                let buttons: [NSView] = [
                    controls.playButton, controls.backButton, controls.forwardButton, controls.muteButton,
                    controls.closeButton, bar,
                ]
                report(
                    "the controls take their own clicks; the edges and the rest of the video stay the panel's",
                    buttons.allSatisfy { controls.hitTest(center($0)) === $0 }
                        && controls.hitTest(controls.convert(NSPoint(x: bounds.midX, y: 3), to: superview)) === controls
                        && controls.hitTest(controls.convert(NSPoint(x: bounds.width * 0.1, y: bounds.midY), to: superview))
                            === controls
                        && controls.hitTest(center(controls.elapsedLabel)) === controls)
                pane.select(seek.id)
                settle()
                coordinator.active.close(seek.id)

                let advances = "next shows on a page with one and advances it, the panel showing the new video"
                guard let next = open("next", host: "www.youtube.com"), reported(next.id, playing: true) else {
                    return report(advances, false)
                }
                leave()
                controls.reveal()
                let offered = inPanel(next) && waitUntil(3) { controls.playback?.hasNext == true }
                    && !controls.nextButton.isHidden
                if let narrow = next.view.window {
                    let wide = narrow.frame
                    narrow.setContentSize(NSSize(width: MiniPlayer.minWidth, height: MiniPlayer.minWidth * 9 / 16))
                    controls.reveal()
                    controls.layoutSubtreeIfNeeded()
                    let inside = controls.bounds.insetBy(dx: 8, dy: 8)
                    let shown: [NSView] = [
                        controls.closeButton, controls.backButton, controls.playButton, controls.forwardButton,
                        controls.nextButton, controls.muteButton, controls.bar,
                    ]
                    report(
                        "at the narrowest, every control stays clear of the edges, the times dropped",
                        controls.bounds.width == MiniPlayer.minWidth && shown.allSatisfy { !$0.isHidden }
                            && shown.allSatisfy { inside.contains($0.frame) } && controls.elapsedLabel.isHidden)
                    narrow.setFrame(wide, display: false)
                }
                press(controls.nextButton)
                let swapped = "String(!!document.getElementById('v2') && !document.getElementById('v2').paused)"
                report(
                    advances,
                    offered && waitUntil(3) { pageValue(next.view, swapped) == "true" }
                        && waitUntil(3) { isFilled(next.view, "#v2") } && inPanel(next)
                        && waitUntil(3) { controls.playback?.duration.map { abs($0 - 20) < 0.5 } == true })
                pane.select(next.id)
                settle()
                coordinator.active.close(next.id)
            }
            checkControls()

            pane.select(sound.id)
            settle()
            sound.view.evaluateJavaScript("document.getElementById('v').play()")
            _ = isPlaying(sound.view) && reported(sound.id, playing: true)
            leave()
            let panel = sound.view.window
            player.closeButton?.performClick(nil)
            settle()
            report(
                "closing the panel pauses the video and leaves the tab",
                panel is MiniPlayerPanel && player.tab == nil && panel?.isVisible == false && sound.view.window == nil
                    && coordinator.active.tabs[sound.id] != nil
                    && pageValue(sound.view, "String(document.getElementById('v').paused)") == "true")
            report(
                "a tab out of the panel can rest again", !held(coordinator.active, sound.id))

            guard let closing = open("sound"), reported(closing.id, playing: true) else {
                report("closing the tab closes the panel", false)
                return []
            }
            leave()
            let wasIn = inPanel(closing)
            coordinator.active.close(closing.id)
            settle()
            report("closing the tab closes the panel", wasIn && player.tab == nil)

            if let moving = open("sound"), reported(moving.id, playing: true) {
                leave()
                let wasIn = inPanel(moving)
                _ = pageValue(moving.view, "location.hash = 'later'; history.pushState({}, '', 'sound-pushed'); 'ok'")
                settle(0.5)
                report(
                    "a same-document change keeps the page in the panel",
                    wasIn && inPanel(moving) && moving.view.url?.lastPathComponent == "sound-pushed")
                for mode in ["nocontent", "fail"] {
                    moving.view.evaluateJavaScript("location.href = '\(VideoCheckScheme.name)://top/\(mode)'")
                    settle(1)
                    report(
                        "a navigation that never commits (\(mode)) keeps the video playing in the panel",
                        inPanel(moving) && !moving.view.isLoading && isPlaying(moving.view)
                            && moving.view.url?.lastPathComponent == "sound-pushed")
                }
                moving.view.evaluateJavaScript("location.href = '\(VideoCheckScheme.name)://top/still'")
                report(
                    "going to another document takes the view back, shown nowhere, and closes the panel",
                    waitUntil { player.tab == nil } && moving.view.window == nil && !coordinator.isShown(moving.id)
                        && coordinator.active.tabs[moving.id] != nil)
                coordinator.active.close(moving.id)
            } else {
                report("a same-document change keeps the page in the panel", false)
            }

            let made: Workspace? = autoreleasepool { try? coordinator.create(name: "Video", symbol: "film") }
            coordinator.switchTo(Workspace.defaultID)
            settle()
            let home = coordinator.active
            if let made, let switching = open("sound"), reported(switching.id, playing: true) {
                coordinator.switchTo(made.id)
                settle(1.5)
                report(
                    "switching workspace moves the playing video to the panel and keeps its tab",
                    inPanel(switching) && coordinator.registry.webView(for: switching.id) === switching.view
                        && isPlaying(switching.view))
                coordinator.switchTo(Workspace.defaultID)
                settle()
                report(
                    "switching back brings it back",
                    player.tab == nil && waitUntil(3) { switching.view.window === hostWindow })
                home.close(switching.id)
            } else {
                report("switching workspace moves the playing video to the panel and keeps its tab", false)
            }

            coordinator.switchTo(Workspace.anonymousID)
            settle()
            if let anonymous = open("sound"), reported(anonymous.id, playing: true) {
                let anonymousRest = coordinator.active.tabs.tabs.first { $0.id != anonymous.id }?.id
                anonymousRest.map(pane.select)
                settle()
                let popped = inPanel(anonymous) && isPlaying(anonymous.view)
                pane.select(anonymous.id)
                settle()
                report(
                    "Anonymous pops out and brings back the same",
                    anonymousRest != nil && popped && player.tab == nil
                        && waitUntil(3) { anonymous.view.window === hostWindow })
                coordinator.active.close(anonymous.id)
            } else {
                report("Anonymous pops out and brings back the same", false)
            }

            /// A new workspace, active, showing a playing video's tab; nil when it does not come up. Only ids are
            /// kept, so its web views can go and its store be removed when it is deleted.
            func playingWorkspace(_ name: String) -> (workspace: Workspace, tab: TabID)? {
                autoreleasepool {
                    let made = try? coordinator.create(name: name, symbol: "film")
                    settle()
                    guard let made, coordinator.activeWorkspaceID == made.id, let tab = open("sound")?.id,
                        reported(tab, playing: true)
                    else { return nil }
                    return (made, tab)
                }
            }
            func isInPanel(_ id: TabID) -> Bool {
                player.tab == id && coordinator.registry.webView(for: id)?.window is MiniPlayerPanel
            }
            /// Deletes the workspace; true once it has left the list. A store WebKit still held for a view freed late
            /// is removed again once the check is over.
            var deletedStores: [UUID] = []
            func delete(_ workspace: Workspace) -> Bool {
                var deleted: Bool?
                Task { deleted = await coordinator.delete(workspace.id) }
                let left = waitUntil(10) { deleted != nil } && coordinator.workspaces[workspace.id] == nil
                if deleted != true { deletedStores.append(workspace.id) }
                return left
            }

            if let doomed = playingWorkspace("Doomed") {
                let still = autoreleasepool { open("still")?.id }
                let popped = isInPanel(doomed.tab)
                coordinator.switchTo(Workspace.defaultID)
                settle()
                let stayed = isInPanel(doomed.tab)
                report(
                    "deleting a workspace whose tab is in the panel closes the panel first",
                    still != nil && popped && stayed && delete(doomed.workspace) && player.tab == nil
                        && coordinator.registry.webView(for: doomed.tab) == nil)
            } else {
                report("deleting a workspace whose tab is in the panel closes the panel first", false)
            }
            if let shown = playingWorkspace("Shown") {
                player.close()
                report(
                    "deleting the active workspace pops nothing out",
                    delete(shown.workspace) && player.tab == nil && coordinator.activeWorkspaceID == Workspace.defaultID)
            } else {
                report("deleting the active workspace pops nothing out", false)
            }

            coordinator.switchTo(Workspace.defaultID)
            settle()
            if let quitting = open("sound"), reported(quitting.id, playing: true) {
                leave()
                let wasIn = inPanel(quitting)
                coordinator.prepareForQuit()
                settle()
                report(
                    "quitting closes the panel and gives the view back to its tab",
                    wasIn && player.tab == nil && quitting.view.window == nil
                        && coordinator.registry.webView(for: quitting.id) === quitting.view)
                coordinator.cancelQuitForSelfCheck()
                coordinator.active.close(quitting.id)
                settle()
            } else {
                report("quitting closes the panel and gives the view back to its tab", false)
            }
            let lastWindow = "closing the last window, the one the tab was left in, closes the panel and gives the view back"
            if let last = open("sound"), reported(last.id, playing: true) {
                leave()
                let wasIn = inPanel(last)
                hostWindow.close()
                isHostOpen = false
                settle()
                report(
                    lastWindow,
                    wasIn && coordinator.windows.isEmpty && player.tab == nil && last.view.window == nil
                        && coordinator.registry.webView(for: last.id) === last.view)
            } else {
                report(lastWindow, false)
            }
            if let made { _ = delete(made) }
            return deletedStores
        }
    }

    /// Layout self-checks only: a local `lodge-video:` scheme serving the mini player check's pages. `top` serves a
    /// page per mode (`still` has no video; `seek` and `next`, served on any host, play a silent file with a duration,
    /// and `next` has a YouTube-style next button that swaps the video), `frame` the video page a `framed` page holds in a cross-origin iframe. The video is a canvas's
    /// `captureStream`, with no sound track.
    @MainActor
    final class VideoCheckScheme: NSObject, WKURLSchemeHandler {
        static let name = "lodge-video"

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            guard let url = task.request.url else { return }
            let mode = url.lastPathComponent
            if mode == "nocontent" {
                task.didReceive(HTTPURLResponse(url: url, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: [:])!)
                task.didFinish()
                return
            }
            if mode == "fail" { return task.didFailWithError(URLError(.cannotConnectToHost)) }
            let body: String =
                if mode == "still" {
                    ""
                } else if mode == "tube" {
                    """
                    <header style='position:fixed;top:0;left:0;right:0;height:56px;background:#f0f;z-index:2020'></header>
                    <div style='opacity:0.99;isolation:isolate;padding-top:56px'>
                    <div id=player style='position:relative;width:640px;height:300px;overflow:hidden;contain:strict;\
                    transform:translateZ(0);translate:12px 0;container-type:size'>
                    <video id=v playsinline style='position:absolute;left:-90px;top:-40px;width:820px;height:460px;\
                    object-fit:cover'></video>
                    <div style='position:absolute;inset:0;background:rgba(255,0,255,.6);z-index:10'></div>
                    </div>
                    <aside style='height:1400px;background:#f0f;visibility:visible'></aside>
                    </div>
                    <canvas id=c width=320 height=180 style='display:none'></canvas>
                    <script>
                    const g = document.getElementById('c').getContext('2d');
                    const paint = () => {
                      g.fillStyle = '#fff'; g.fillRect(0, 0, 320, 180);
                      g.fillStyle = '#f00'; g.fillRect(10, 10, 150, 80);
                      g.fillStyle = '#0f0'; g.fillRect(160, 10, 150, 80);
                      g.fillStyle = '#00f'; g.fillRect(10, 90, 150, 80);
                      g.fillStyle = '#ff0'; g.fillRect(160, 90, 150, 80);
                    };
                    paint();
                    setInterval(paint, 50);
                    const v = document.getElementById('v');
                    v.srcObject = document.getElementById('c').captureStream(20);
                    v.play().catch(() => {});
                    </script>
                    """
                } else if mode == "seek" || mode == "next" {
                    """
                    <div id=box><video id=v playsinline style='width:640px;height:360px'></video></div>
                    <a class=ytp-next-button href='#next' style='display:\(mode == "next" ? "inline-block" : "none")'>next</a>
                    <script>
                    const wav = (seconds) => {
                      const rate = 8000, n = rate * seconds, b = new DataView(new ArrayBuffer(44 + n));
                      const text = (at, t) => { for (let i = 0; i < t.length; i++) { b.setUint8(at + i, t.charCodeAt(i)); } };
                      text(0, 'RIFF'); b.setUint32(4, 36 + n, true); text(8, 'WAVE'); text(12, 'fmt ');
                      b.setUint32(16, 16, true); b.setUint16(20, 1, true); b.setUint16(22, 1, true);
                      b.setUint32(24, rate, true); b.setUint32(28, rate, true); b.setUint16(32, 1, true);
                      b.setUint16(34, 8, true); text(36, 'data'); b.setUint32(40, n, true);
                      for (let i = 0; i < n; i++) { b.setUint8(44 + i, 128); }
                      return URL.createObjectURL(new Blob([b], { type: 'audio/wav' }));
                    };
                    const v = document.getElementById('v');
                    v.src = wav(30);
                    v.play().catch(() => {});
                    document.querySelector('.ytp-next-button').addEventListener('click', (e) => {
                      e.preventDefault();
                      const n = document.createElement('video');
                      n.id = 'v2';
                      n.playsInline = true;
                      n.style.cssText = 'width:640px;height:360px';
                      n.src = wav(20);
                      document.getElementById('box').replaceChild(n, document.getElementById('v'));
                      n.play().catch(() => {});
                    });
                    </script>
                    """
                } else if mode == "framed" || mode == "sandboxed" {
                    "<iframe src='\(Self.name)://frame/sound' \(mode == "sandboxed" ? "sandbox='allow-scripts'" : "")"
                        + " style='width:700px;height:420px;border:0'></iframe>"
                } else {
                    """
                    <canvas id=c width=320 height=180 style='display:none'></canvas>
                    <video id=v playsinline style='width:640px;height:360px'></video>
                    <script>
                    const g = document.getElementById('c').getContext('2d');
                    let n = 0;
                    setInterval(() => { g.fillStyle = 'hsl(' + (n++ % 360) + ',80%,50%)'; g.fillRect(0, 0, 320, 180); }, 50);
                    const v = document.getElementById('v');
                    v.srcObject = document.getElementById('c').captureStream(20);
                    v.muted = \(mode == "muted");
                    if (\(mode != "paused")) { v.play().catch(() => {}); }
                    </script>
                    """
                }
            let html = "<!doctype html><title>video-\(mode)</title><body style='margin:0'>\(body)</body>"
            let data = Data(html.utf8)
            task.didReceive(
                URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
    }
#endif
