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
        /// view to the panel still playing and filling it, held awake, the panel titled with the page's site, nothing
        /// the page can see naming Lodge; showing the tab brings it back still playing;
        /// a muted or paused video stays; a video in a cross-origin iframe pops out with its iframe filling the page and
        /// its own video filling the iframe, the top page told nothing naming Lodge; closing the panel pauses and
        /// leaves the tab, closing the tab or its window closes the panel; the page in the panel changing its URL in
        /// the same document stays, as does a navigation that never commits (a 204, a failure), and committing another
        /// document goes back to its tab, shown nowhere, and closes the panel; a sandboxed iframe's video pops out too; switching workspace pops out and holds it, switching back returns it; Anonymous does the
        /// same; deleting a workspace whose tab is in the panel closes the panel, and deleting the active one pops
        /// nothing out. The stores of the workspaces it deletes are removed once nothing of the check holds them.
        static func checkMiniPlayer() {
            func report(_ name: String, _ passed: Bool) { print("Mini player: \(name): \(passed ? "ok" : "FAILED")") }
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
            func open(_ mode: String) -> (id: TabID, view: LodgeWebView)? {
                let model = coordinator.active
                let tab = BrowserTab(store: model.newTabStore(), url: URL(string: "\(VideoCheckScheme.name)://top/\(mode)"))
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
                "the panel's title names the page's site",
                title == MiniPlayer.title(for: sound.view.url) && title.hasSuffix(" top")
                    && title != String(localized: "Mini Player"))

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

            pane.select(sound.id)
            settle()
            sound.view.evaluateJavaScript("document.getElementById('v').play()")
            _ = isPlaying(sound.view) && reported(sound.id, playing: true)
            leave()
            let panel = sound.view.window
            panel?.performClose(nil)
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
            if let last = open("sound"), reported(last.id, playing: true) {
                leave()
                let wasIn = inPanel(last)
                hostWindow.close()
                isHostOpen = false
                settle()
                report("closing the window the tab was left in closes the panel", wasIn && player.tab == nil)
            } else {
                report("closing the window the tab was left in closes the panel", false)
            }
            if let made { _ = delete(made) }
            return deletedStores
        }
    }

    /// Layout self-checks only: a local `lodge-video:` scheme serving the mini player check's pages. `top` serves a
    /// page per mode (`still` has no video), `frame` the video page a `framed` page holds in a cross-origin iframe. The video is a canvas's
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
