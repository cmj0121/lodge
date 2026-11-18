#if DEBUG
    import AppKit
    import LodgeKit
    import Network
    import WebKit

    extension LayoutRenderer {
        /// Fingerprint protection (D1, D3, D6, D7) in real WebKit, off screen, printing ok or FAILED for each: models
        /// with no coordinator get their keys from `FingerprintCheckPlacement`, and pages come from
        /// `FingerprintCheckServer` on the loopback interface, reached as two sites, `localhost` and `127.0.0.1`
        /// (Debug builds may accept incoming connections for it). A read in the page world is compared with the same
        /// read in an isolated world, which the patch never touches, to tell a noised answer from the real one. Every
        /// model but Anonymous runs on Default's store, since the seed comes from the workspace's key, not its store;
        /// every tab closes and the server stops when the check ends.
        static func checkFingerprint() {
            func report(_ name: String, _ passed: Bool) { print("Fingerprint: \(name): \(passed ? "ok" : "FAILED")") }
            func settle(_ seconds: Double = 0.3) {
                autoreleasepool { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
            }
            func waitUntil(_ seconds: Double = 8, _ done: () -> Bool) -> Bool {
                let deadline = Date.now.addingTimeInterval(seconds)
                while !autoreleasepool(invoking: done), Date.now < deadline { settle(0.02) }
                return autoreleasepool(invoking: done)
            }

            let server = FingerprintCheckServer(script: FingerprintCheckJS.library)
            guard server.start() else { return report("the loopback server starts", false) }
            defer { server.stop() }
            let one = "localhost"
            let other = "127.0.0.1"
            func url(_ host: String, _ name: String) -> URL { server.url(host, "/p/\(name)") }

            /// Runs `body`, the check library before it, as an async function in `world`; its string result.
            func js(_ view: WKWebView, _ body: String, in world: WKContentWorld = .page) -> String? {
                var answer: String?
                var done = false
                view.callAsyncJavaScript(
                    FingerprintCheckJS.library + body, arguments: [:], in: nil, in: world
                ) { result in
                    switch result {
                    case .success(let value): answer = value as? String
                    case .failure(let error): print("Fingerprint: script failed: \(error)")
                    }
                    done = true
                }
                _ = waitUntil(15) { done }
                return answer
            }
            func loaded(_ view: WKWebView, _ title: String) -> Bool {
                waitUntil { view.title == title && !view.isLoading }
            }
            typealias Tab = (id: TabID, view: LodgeWebView)
            /// A new tab of `model` on the page `name` at `host`, once it has loaded.
            func open(_ model: BrowserModel, _ host: String, _ name: String) -> Tab? {
                let tab = BrowserTab(store: model.newTabStore(), url: url(host, name))
                guard let view = model.append(tab, load: true), loaded(view, name) else { return nil }
                return (tab.id, view)
            }
            /// Loads the page `name` at `host` in the tab: a new document, whose reads start afresh.
            func go(_ model: BrowserModel, _ tab: Tab, _ host: String, _ name: String) -> Bool {
                model.load(url(host, name), in: tab.id) && loaded(tab.view, name)
            }
            /// The popup tab `model` gains while `action` runs, once its page is titled `title`.
            func popup(_ model: BrowserModel, titled title: String?, _ action: () -> Void) -> Tab? {
                let before = Set(model.tabs.tabs.map(\.id))
                action()
                var found: (TabID, LodgeWebView)?
                _ = waitUntil {
                    guard let id = model.tabs.tabs.map(\.id).first(where: { !before.contains($0) }),
                        let view = model.registry.webView(for: id),
                        title.map({ view.title == $0 && !view.isLoading }) ?? true
                    else { return false }
                    found = (id, view)
                    return true
                }
                return found
            }
            /// Canvas, WebGL and audio reads of the tab's page, each hashed.
            func read(_ view: WKWebView, in world: WKContentWorld = .page) -> [String]? {
                js(view, "return await readAll();", in: world)?.components(separatedBy: "|")
            }
            func allDiffer(_ a: [String]?, _ b: [String]?) -> Bool {
                guard let a, let b, a.count == 3, b.count == 3 else { return false }
                return zip(a, b).allSatisfy { $0 != $1 }
            }
            func same(_ a: [String]?, _ b: [String]?) -> Bool { a != nil && a?.count == 3 && a == b }
            /// The page world's reads when every one differs from the real one, read in an isolated world; else nil,
            /// so a page left unseeded never passes a comparison.
            func noisedRead(_ view: WKWebView) -> [String]? {
                let page = read(view)
                return allDiffer(page, read(view, in: .defaultClient)) ? page : nil
            }
            /// The page reads with `body` in the page world and in an isolated one: the two answers, `|`-separated.
            func both(_ view: WKWebView, _ body: String) -> (page: [String], real: [String])? {
                guard let page = js(view, body), let real = js(view, body, in: .defaultClient) else { return nil }
                return (page.components(separatedBy: "|"), real.components(separatedBy: "|"))
            }
            /// Every part of the page world's answer differs from the real one.
            func noised(_ answer: (page: [String], real: [String])?) -> Bool {
                guard let answer, answer.page.count == answer.real.count else { return false }
                return zip(answer.page, answer.real).allSatisfy { $0 != $1 }
            }
            /// The tab's reads, once `apis` were reported and a moment more passed for any other report.
            func reads(_ model: BrowserModel, _ id: TabID, _ apis: Set<FingerprintAPI>) -> Set<FingerprintAPI> {
                _ = waitUntil { model.fingerprintReads[id]?.isSuperset(of: apis) == true }
                settle(0.3)
                return model.fingerprintReads[id] ?? []
            }

            let placement = FingerprintCheckPlacement()
            let customID = UUID()
            placement.settings = [Workspace.defaultID: .fresh(), customID: .fresh()]
            let registry = WebViewRegistry()
            func model(_ workspace: UUID, store: StoreRef? = .global, registry: WebViewRegistry = registry)
                -> BrowserModel
            {
                let model = BrowserModel(workspace: workspace, store: store, registry: registry)
                model.placement = placement
                return model
            }
            let defaultModel = model(Workspace.defaultID)
            let customModel = model(customID)
            let freshModel = model(Workspace.defaultID, registry: WebViewRegistry())
            let anonymousModel = model(Workspace.anonymousID, store: nil)
            let models = [defaultModel, customModel, freshModel, anonymousModel]
            /// Reports `test` on a new Default tab on the page `page` at `localhost`; failed when it does not load.
            func onPage(_ name: String, _ page: String, _ test: (Tab) -> Bool) {
                report(name, open(defaultModel, one, page).map(test) == true)
            }
            defer {
                for model in models {
                    for id in model.tabs.tabs.map(\.id) { autoreleasepool { model.close(id) } }
                }
                settle()
            }

            // Workspaces, stores and sites (D1, D3).
            guard let home = open(defaultModel, one, "home"), let away = open(defaultModel, other, "away") else {
                return report("pages load from the loopback server", false)
            }
            let homeRead = noisedRead(home.view)
            let awayRead = noisedRead(away.view)
            report(
                "the isolated world reads the string detail and the relay reports canvas, WebGL and audio",
                reads(defaultModel, home.id, [.canvas, .webgl, .audio]) == [.canvas, .webgl, .audio])
            report("a read is noised in the page world on either site", homeRead != nil && awayRead != nil)
            // Every check below compares with the home page's noised canvas read, so without one none can pass.
            guard let homeCanvas = homeRead?.first else { return }
            report(
                "the view is seeded for its main-frame site",
                defaultModel.fingerprintSite(home.id) == one && defaultModel.fingerprintSite(away.id) == other)
            report("a read differs across two sites", allDiffer(homeRead, awayRead))
            report(
                "a read is equal across two loads",
                go(defaultModel, home, one, "home-again") && same(noisedRead(home.view), homeRead))
            report(
                "a read differs between Default and a custom workspace",
                allDiffer(open(customModel, one, "custom").flatMap { noisedRead($0.view) }, homeRead))
            report(
                "a fresh registry with the same key reads the same",
                same(open(freshModel, one, "fresh").flatMap { noisedRead($0.view) }, homeRead))
            let anonymous = open(anonymousModel, one, "anonymous-1")
            let anonymousRead = anonymous.flatMap { noisedRead($0.view) }
            report(
                "a read differs between two Anonymous tabs",
                allDiffer(anonymousRead, open(anonymousModel, one, "anonymous-2").flatMap { noisedRead($0.view) }))
            let anonymousPopup = anonymous.flatMap { anonymous in
                popup(anonymousModel, titled: "anonymous-popup") {
                    anonymous.view.evaluateJavaScript("window.open('\(url(one, "anonymous-popup"))')")
                }
            }
            report(
                "an Anonymous popup shares its opener's store and key",
                anonymousPopup.flatMap { anonymousModel.tabs[$0.id]?.store } != nil
                    && anonymousPopup.flatMap { anonymousModel.tabs[$0.id]?.store }
                        == anonymous.flatMap { anonymousModel.tabs[$0.id]?.store }
                    && same(anonymousPopup.flatMap { noisedRead($0.view) }, anonymousRead))

            // Popups (D7): a fresh controller each, seeded for its own site, or its opener's when it opens blank.
            let otherSite = popup(defaultModel, titled: "popup-away") {
                home.view.evaluateJavaScript("window.open('\(url(other, "popup-away"))')")
            }
            report(
                "a popup on another site gets that site's seed",
                otherSite.map { defaultModel.fingerprintSite($0.id) == other } == true
                    && same(otherSite.flatMap { noisedRead($0.view) }, awayRead))
            let blank = popup(defaultModel, titled: nil) {
                home.view.evaluateJavaScript("window.blankPopup = window.open('')")
            }
            report(
                "a window.open('') popup gets its opener's seed",
                blank.map { defaultModel.fingerprintSite($0.id) == one } == true
                    && js(home.view, "return readCanvas(window.blankPopup);") == homeCanvas)
            home.view.evaluateJavaScript("window.blankPopup.location = '\(url(other, "popup-moved"))'")
            report(
                "a window.open('') popup re-seeds when it navigates, its opener does not",
                blank.map { loaded($0.view, "popup-moved") && defaultModel.fingerprintSite($0.id) == other } == true
                    && same(blank.flatMap { noisedRead($0.view) }, awayRead)
                    && defaultModel.fingerprintSite(home.id) == one)

            // Redirects and cancelled navigations (D7).
            let redirect = BrowserTab(url: server.url(one, "/r?to=\(url(other, "redirected"))"))
            let redirected = defaultModel.append(redirect, load: true)
            report(
                "a cross-site redirect leaves the final site's seed",
                redirected.map { loaded($0, "redirected") } == true
                    && defaultModel.fingerprintSite(redirect.id) == other
                    && same(redirected.flatMap { noisedRead($0) }, awayRead))
            /// A blank frame the page adds now reads with the scripts installed now (D6).
            let frameRead =
                "const f = document.createElement('iframe'); document.body.append(f); "
                + "return readCanvas(frames[frames.length - 1]);"
            /// The tab stayed on `page` at `one`, seeded for it.
            func stayed(_ tab: Tab, on page: String) -> Bool {
                tab.view.url == url(one, page) && defaultModel.fingerprintSite(tab.id) == one
                    && js(tab.view, frameRead) == homeCanvas
            }
            onPage("a cross-site navigation whose response is cancelled leaves the seed", "cancel") { tab in
                let hits = server.hits("/download")
                tab.view.evaluateJavaScript("location.href = '\(server.url(other, "/download"))'")
                let asked = waitUntil { server.hits("/download") > hits }
                settle(1)
                return asked && stayed(tab, on: "cancel")
            }
            onPage("a cross-site navigation stopped before its response leaves the seed", "stop") { tab in
                let hits = server.hits("/hang")
                _ = defaultModel.load(server.url(other, "/hang"), in: tab.id)
                let reached = waitUntil { server.hits("/hang") > hits }
                tab.view.stopLoading()
                settle(1)
                return reached && stayed(tab, on: "stop")
            }
            onPage(
                "a frame the old page adds once the next site's response re-seeded reads neither its seed nor real",
                "held"
            ) { tab in
                let hits = server.hits("/held")
                _ = defaultModel.load(server.url(other, "/held"), in: tab.id)
                let reseeded = waitUntil { server.hits("/held") > hits && defaultModel.fingerprintSite(tab.id) == other }
                let framed = reseeded ? both(tab.view, frameRead) : nil
                let still = js(tab.view, "return document.title;") == "held"
                tab.view.stopLoading()
                settle()
                guard let framed, let away = awayRead?.first, framed.page.count == 1 else { return false }
                return still && framed.page[0] != away && noised(framed) && framed.page[0] != homeCanvas
            }

            // Frames (D1, D6): every frame of the view reads with its main frame's seed; reaching a cross-origin one
            // stays harmless.
            let framesName = "blank, written, srcdoc and cross-site frames and blank and opened popups read its seed"
            onPage(framesName, "frames") { tab in
                let answer = js(
                    tab.view,
                    FingerprintCheckJS.frames(sameSite: url(one, "frames-opened"), crossSite: url(other, "frame-read")))
                let parts = (answer ?? "").components(separatedBy: "|")
                let names = [
                    "the page", "no-src frame via frames[i]", "document.write frame", "srcdoc frame", "window.open('')",
                    "window.open(url) before it loads", "cross-site frame", "reaching the cross-site frame",
                ]
                let expected = Array(repeating: homeCanvas, count: names.count - 1) + ["harmless"]
                let failed = zip(names, zip(parts, expected)).filter { $0.1.0 != $0.1.1 }.map(\.0)
                if !failed.isEmpty { print("Fingerprint: frames not as decided: \(failed.joined(separator: ", "))") }
                settle()
                return parts.count == names.count && failed.isEmpty
            }

            // Canvas (b, d, e).
            onPage("an opaque getImageData → putImageData loop stays equal and noised", "canvas-loop") { tab in
                both(tab.view, FingerprintCheckJS.canvasLoop).map {
                    $0.page.count == 2 && $0.page[1] == "stable" && $0.page[0] != $0.real[0]
                } == true
            }
            onPage("translucent pixels are noised, their alpha kept", "canvas-translucent") { tab in
                both(tab.view, FingerprintCheckJS.translucent).map {
                    let page = $0.page[0].split(separator: ",")
                    let real = $0.real[0].split(separator: ",")
                    return page.count == 1024 && page.count == real.count && page != real
                        && stride(from: 3, to: page.count, by: 4).allSatisfy { page[$0] == real[$0] }
                } == true
            }
            onPage("a display-p3 canvas's copy is not clamped to sRGB", "canvas-p3") { tab in
                both(tab.view, FingerprintCheckJS.displayP3).map {
                    let page = $0.page[0].split(separator: ",").compactMap { Int($0) }
                    let real = $0.real[0].split(separator: ",").compactMap { Int($0) }
                    return page.count == 4 && real.count == 4 && real[0] >= 250 && real[1] <= 5
                        && zip(page, real).allSatisfy { abs($0 - $1) <= 1 }
                } == true
            }
            onPage("a tainted canvas throws SecurityError", "canvas-tainted") { tab in
                js(tab.view, FingerprintCheckJS.tainted(image: server.url(other, "/img.png")))
                    == "SecurityError,SecurityError,SecurityError,SecurityError"
            }
            onPage("OffscreenCanvas.convertToBlob is noised and reported as canvas", "offscreen") { tab in
                noised(both(tab.view, FingerprintCheckJS.offscreen))
                    && reads(defaultModel, tab.id, [.canvas]) == [.canvas]
            }

            // WebGL (c).
            onPage("a WebGL canvas's toDataURL and toBlob are noised and reported as webgl", "webgl-copy") { tab in
                noised(both(tab.view, FingerprintCheckJS.webGLCopy))
                    && reads(defaultModel, tab.id, [.webgl]) == [.webgl]
            }
            onPage("readPixels on WebGL 1 and 2 is noised, pixels with alpha 0 included", "webgl-pixels") { tab in
                let versions = both(tab.view, FingerprintCheckJS.readPixels).map {
                    zip($0.page, $0.real).map { ($0.split(separator: ","), $1.split(separator: ",")) }
                }
                let noisedAtAlphaZero = versions.map { versions in
                    versions.count == 2
                        && versions.allSatisfy { page, real in
                            page.count == 256 && page.count == real.count && page != real
                                && stride(from: 3, to: 256, by: 4).allSatisfy { page[$0] == "0" && real[$0] == "0" }
                        }
                }
                return noisedAtAlphaZero == true && reads(defaultModel, tab.id, [.webgl]) == [.webgl]
            }

            // Audio (f).
            onPage("startRendering, oncomplete and decodeAudioData are noised and reported as audio", "audio") { tab in
                noised(both(tab.view, FingerprintCheckJS.audio)) && reads(defaultModel, tab.id, [.audio]) == [.audio]
            }

            // Names and lengths (h).
            onPage("every patched method keeps its real name and length", "names") { tab in
                both(tab.view, FingerprintCheckJS.names).map { answer in
                    answer.page.count > 1 && answer.page.allSatisfy { $0.hasSuffix("/wrapped") }
                        && answer.page.map { $0.replacingOccurrences(of: "/wrapped", with: "/native") } == answer.real
                } == true
            }

            // document.open/write (i).
            onPage("the relay survives document.open and write", "written") { tab in
                js(tab.view, FingerprintCheckJS.documentWrite) == homeCanvas
                    && reads(defaultModel, tab.id, [.canvas]) == [.canvas]
            }

            // The back/forward cache (j).
            onPage("a back/forward cache restore is seeded for its site and re-reports its reads", "cached") { tab in
                _ = js(tab.view, "window.kept = 'kept'; return readCanvas();")
                let readBefore = reads(defaultModel, tab.id, [.canvas])
                // The page away reads nothing, so reads after going back are the restored page's report.
                let left =
                    go(defaultModel, tab, other, "cached-away") && defaultModel.fingerprintSite(tab.id) == other
                    && defaultModel.fingerprintReads[tab.id] == nil
                tab.view.goBack()
                let restored = loaded(tab.view, "cached") && js(tab.view, "return String(window.kept);") == "kept"
                return readBefore == [.canvas] && left && restored
                    && reads(defaultModel, tab.id, [.canvas]) == [.canvas] && stayed(tab, on: "cached")
            }

            // The indicator and the protection page (D5, D7), through a coordinator and its window's pane as the app
            // runs them. An excepted page gets no patch, so reads nothing that reports; its reads equal an isolated
            // world's, the real value.
            let coordinator = WorkspaceCoordinator(
                restoring: nil, session: nil, appDirectory: nil, downloads: nil, defaultLibrary: LinkLibrary())
            coordinator.bringForwardHook = { _ in }
            coordinator.windows[0].locationPrompt = nil
            func pane() -> BrowserPane { coordinator.pane(for: coordinator.windows[0]) }
            defer {
                for workspace in [Workspace.defaultID, Workspace.anonymousID] {
                    guard let model = coordinator.model(for: workspace) else { continue }
                    for id in model.tabs.tabs.map(\.id) { autoreleasepool { model.close(id) } }
                }
                settle()
            }
            /// The window's shown tab, its blank one the first time, once it loaded the page `name` at `host`.
            func shown(_ host: String, _ name: String) -> Tab? {
                pane().load(url(host, name).absoluteString)
                guard let id = pane().selectedID, let view = pane().model.registry.webView(for: id), loaded(view, name)
                else { return nil }
                return (id, view)
            }
            /// Whether each view's document was loaded again while `change` ran: a mark left in it is gone.
            func reloaded(_ views: [WKWebView], by change: () -> Void) -> [Bool] {
                for view in views { _ = js(view, "window.kept = 'kept'; return 'kept';") }
                change()
                return views.map { view in
                    waitUntil(4) { !view.isLoading && js(view, "return String(window.kept);") == "undefined" }
                }
            }
            func real(_ view: WKWebView) -> Bool { same(read(view), read(view, in: .defaultClient)) }
            func indicator(_ id: TabID) -> (site: String, isOff: Bool)? {
                pane().select(id)
                return pane().selectedFingerprint
            }
            func exception(_ workspace: UUID) -> Set<String>? {
                coordinator.snapshot.workspaces.first { $0.workspace.id == workspace }?.fingerprint?.offSites
            }

            let workModel = coordinator.active
            guard let web = shown(one, "indicator"), let webStore = workModel.tabs[web.id]?.store else {
                return report("a coordinator's window loads a page", false)
            }
            let unread = pane().selectedFingerprint == nil
            let firstRead = noisedRead(web.view)
            report(
                "the indicator shows only after the page on screen read a fingerprint, in the on look",
                unread && firstRead != nil && reads(workModel, web.id, [.canvas, .webgl, .audio]).count == 3
                    && indicator(web.id).map { $0.site == one && !$0.isOff } == true)
            pane().openProtection()
            let page = workModel.tab(showing: .protection)
            report(
                "the indicator opens the one protection page at lodge://protection for its site and tab",
                page != nil && pane().selectedID == page?.id && page?.url?.absoluteString == "lodge://protection"
                    && page.flatMap { workModel.protectionTarget(for: $0.id) }
                        == ProtectionTarget(site: one, tab: web.id, store: webStore)
                    && pane().selectedFingerprint == nil)
            pane().select(web.id)
            pane().load("lodge://protection")
            let typed = workModel.tab(showing: .protection)
            report(
                "a typed lodge://protection shows the same page with no site, until the indicator opens it again",
                typed?.id == page?.id && pane().selectedID == typed?.id
                    && typed.flatMap { workModel.protectionTarget(for: $0.id) } == nil
                    && {
                        pane().select(web.id)
                        pane().openProtection()
                        return typed.flatMap { workModel.protectionTarget(for: $0.id) }?.site == one
                    }())
            let sibling = open(workModel, one, "sibling")
            let elsewhere = open(workModel, other, "elsewhere")
            let offReloads = reloaded([web.view] + [sibling, elsewhere].compactMap { $0?.view }) {
                workModel.setFingerprintProtection(false, for: one, on: webStore)
            }
            report(
                "switching off saves the workspace's exception with the session and reloads its tabs on that site only",
                exception(Workspace.defaultID) == [one] && sibling != nil && elsewhere != nil
                    && offReloads == [true, true, false])
            report(
                "an excepted site reads the real value, as an isolated world does, and reports no read",
                real(web.view) && sibling.map { real($0.view) } == true && reads(workModel, web.id, []).isEmpty
                    && elsewhere.flatMap { noisedRead($0.view) } != nil)
            report(
                "the indicator shows the off look on an excepted site, read or not",
                indicator(web.id).map { $0.site == one && $0.isOff } == true)
            let onReloads = reloaded([web.view]) { workModel.setFingerprintProtection(true, for: one, on: webStore) }
            report(
                "switching on drops the exception, reloads and restores the same noise",
                exception(Workspace.defaultID) == [] && onReloads == [true] && same(noisedRead(web.view), firstRead)
                    && reads(workModel, web.id, [.canvas]).contains(.canvas)
                    && indicator(web.id).map { $0.site == one && !$0.isOff } == true)

            if let gone = open(workModel, one, "gone"), let protection = workModel.tab(showing: .protection) {
                pane().select(gone.id)
                pane().openProtection()
                let had = workModel.protectionTarget(for: protection.id)?.tab == gone.id
                workModel.close(gone.id)
                report(
                    "the page shows no site once the tab it was opened from has closed",
                    had && workModel.protectionTarget(for: protection.id) == nil)
            } else {
                report("the page shows no site once the tab it was opened from has closed", false)
            }

            coordinator.switchTo(Workspace.anonymousID)
            let anonymousWork = coordinator.active
            if let tab = shown(one, "anonymous-protect"), let store = anonymousWork.tabs[tab.id]?.store,
                let twin = open(anonymousWork, one, "anonymous-twin")
            {
                _ = noisedRead(tab.view)
                pane().openProtection()
                let targeted =
                    anonymousWork.tab(showing: .protection).flatMap { anonymousWork.protectionTarget(for: $0.id) }?
                    .store == store
                let anonymousReloads = reloaded([tab.view, twin.view]) {
                    anonymousWork.setFingerprintProtection(false, for: one, on: store)
                }
                report(
                    "in Anonymous an exception stays with the tab's store in memory and reloads that tab only",
                    targeted && anonymousReloads == [true, false]
                        && anonymousWork.fingerprintSettings(on: store)?.isOff(one) == true
                        && exception(Workspace.anonymousID) == nil && exception(Workspace.defaultID) == [])
                report(
                    "an Anonymous exception reads the real value in its tab and leaves another tab noised",
                    real(tab.view) && noisedRead(twin.view) != nil
                        && indicator(tab.id).map { $0.site == one && $0.isOff } == true)
            } else {
                report("an Anonymous window loads a page", false)
            }
            report(
                "no switch puts up a prompt, alert or sheet",
                NSApp.modalWindow == nil && coordinator.windows.allSatisfy { $0.nsWindow?.attachedSheet == nil })
        }
    }

    /// Fingerprint self-check only: supplies each workspace's fingerprint settings where a coordinator would (D3).
    @MainActor
    final class FingerprintCheckPlacement: WindowPlacement {
        var settings: [UUID: FingerprintSettings] = [:]
        func isShown(_ tab: TabID) -> Bool { false }
        func didOpen(_ tab: TabID, in workspace: UUID, from source: TabID?) {}
        func willClose(_ tabs: Set<TabID>, of model: BrowserModel) {}
        func fingerprint(for workspaceID: UUID) -> FingerprintSettings? { settings[workspaceID] }
        func setFingerprint(off: Bool, _ site: String, for workspaceID: UUID) {
            settings[workspaceID]?.setOff(off, site)
        }
    }

    /// Fingerprint self-check only: an HTTP server on the loopback interface, so pages load from two registrable
    /// domains (`localhost`, `127.0.0.1`), which a custom scheme cannot give. `/p/<name>` is a page titled `name`
    /// (`frame-read` posts its canvas read to its parent), `/r?to=<url>` redirects there with a 302, `/download` is a
    /// file WebKit cannot show, `/hang` never answers, `/held` sends a page's headers but never its body, `/img.png` is a
    /// small image. Nothing is cached.
    @MainActor
    final class FingerprintCheckServer {
        private let script: String
        private var listener: NWListener?
        private var connections: [ObjectIdentifier: NWConnection] = [:]
        private var port: UInt16?
        private var failed = false
        private var counts: [String: Int] = [:]

        /// `script` is the check library `frame-read` runs.
        init(script: String) {
            self.script = script
        }

        /// Listens on a free port; false when it cannot.
        func start() -> Bool {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            guard let listener = try? NWListener(using: parameters, on: .any) else { return false }
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch state {
                    case .ready: self.port = self.listener?.port?.rawValue
                    case .failed(let error):
                        print("Fingerprint: the loopback server failed: \(error)")
                        self.failed = true
                    case .cancelled: self.failed = true
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
            let deadline = Date.now.addingTimeInterval(5)
            while port == nil, !failed, Date.now < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            }
            return port != nil
        }

        func stop() {
            listener?.cancel()
            listener = nil
            for connection in connections.values { connection.cancel() }
            connections = [:]
        }

        func url(_ host: String, _ path: String) -> URL {
            URL(string: "http://\(host):\(port ?? 0)\(path)")!
        }

        /// How many requests reached `path`.
        func hits(_ path: String) -> Int { counts[path, default: 0] }

        private func accept(_ connection: NWConnection) {
            connections[ObjectIdentifier(connection)] = connection
            connection.start(queue: .main)
            receive(on: connection, Data())
        }

        private func receive(on connection: NWConnection, _ received: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let all = received + (data ?? Data())
                    if all.range(of: Data("\r\n\r\n".utf8)) != nil {
                        self.answer(String(decoding: all, as: UTF8.self), on: connection)
                    } else if !done, error == nil {
                        self.receive(on: connection, all)
                    } else {
                        self.close(connection)
                    }
                }
            }
        }

        private func close(_ connection: NWConnection) {
            connection.cancel()
            connections[ObjectIdentifier(connection)] = nil
        }

        private func answer(_ request: String, on connection: NWConnection) {
            let target = request.split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init) ?? "/"
            let components = URLComponents(string: target)
            let path = components?.path ?? target
            counts[path, default: 0] += 1
            var status = "200 OK"
            var type = "text/html; charset=utf-8"
            var headers: [String] = []
            var body = Data()
            switch path {
            case "/hang":
                return
            case "/held":
                let head = ["HTTP/1.1 200 OK", "Content-Type: text/html; charset=utf-8", "Content-Length: 4096",
                    "Cache-Control: no-cache"].joined(separator: "\r\n") + "\r\n\r\n"
                connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
                return
            case "/r":
                status = "302 Found"
                headers.append("Location: \(components?.queryItems?.first { $0.name == "to" }?.value ?? "/")")
            case "/download":
                type = "application/octet-stream"
                body = Data("lodge".utf8)
            case "/img.png":
                type = "image/png"
                body = Self.image
            case let page where page.hasPrefix("/p/"):
                let name = String(page.dropFirst(3))
                let extra =
                    name == "frame-read"
                    ? "<script>\(script) parent.postMessage({ canvas: readCanvas() }, '*');</script>" : ""
                body = Data("<!doctype html><title>\(name)</title><body><p>\(name)</p>\(extra)</body>".utf8)
            default:
                status = "404 Not Found"
            }
            let head = (["HTTP/1.1 \(status)", "Content-Type: \(type)", "Content-Length: \(body.count)",
                "Cache-Control: no-cache", "Connection: close"] + headers).joined(separator: "\r\n") + "\r\n\r\n"
            connection.send(
                content: Data(head.utf8) + body,
                completion: .contentProcessed { [weak self] _ in
                    MainActor.assumeIsolated { self?.close(connection) }
                })
        }

        /// A 4×4 opaque PNG.
        private static let image: Data = {
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let teal = NSColor(deviceRed: 0.2, green: 0.6, blue: 0.7, alpha: 1)
            for x in 0..<4 { for y in 0..<4 { rep.setColor(teal, atX: x, y: y) } }
            return rep.representation(using: .png, properties: [:]) ?? Data()
        }()
    }

    /// Fingerprint self-check only: the scripts its pages run. Each body ends in a string, parts joined by `|`.
    enum FingerprintCheckJS {
        /// Hashing and the canvas, WebGL and audio reads, each made in the realm of the window it is given.
        static let library = """
            const fnvFrom = (length, at) => {
              let h = 0x811c9dc5 | 0;
              for (let i = 0; i < length; i++) { h = Math.imul(h ^ at(i), 0x01000193); }
              return (h >>> 0).toString(16);
            };
            const fnv = (s) => fnvFrom(s.length, (i) => s.charCodeAt(i));
            const fnvBytes = (v) => {
              const u = ArrayBuffer.isView(v)
                ? new Uint8Array(v.buffer, v.byteOffset, v.byteLength) : new Uint8Array(v);
              return fnvFrom(u.length, (i) => u[i]);
            };
            const draw = (c) => {
              c.width = 64; c.height = 32;
              const x = c.getContext('2d');
              x.fillStyle = '#fff'; x.fillRect(0, 0, 64, 32);
              x.fillStyle = '#c33'; x.font = '14px sans-serif'; x.fillText('Lodge fp', 2, 20);
              x.fillStyle = 'rgba(20,120,200,0.7)'; x.fillRect(30, 4, 24, 24);
              return x;
            };
            const readCanvas = (w = window) => fnv(draw(w.document.createElement('canvas')).canvas.toDataURL());
            const readGL = (w = window) => {
              const c = w.document.createElement('canvas'); c.width = 16; c.height = 16;
              const g = c.getContext('webgl');
              if (!g) { return 'no-webgl'; }
              g.clearColor(0.2, 0.4, 0.6, 1); g.clear(g.COLOR_BUFFER_BIT);
              const p = new Uint8Array(1024);
              g.readPixels(0, 0, 16, 16, g.RGBA, g.UNSIGNED_BYTE, p);
              return fnvBytes(p);
            };
            const audioGraph = (w = window) => {
              const ctx = new w.OfflineAudioContext(1, 4410, 44100);
              const o = ctx.createOscillator(); o.type = 'triangle'; o.frequency.value = 1000;
              const k = ctx.createDynamicsCompressor();
              o.connect(k); k.connect(ctx.destination); o.start(0);
              return ctx;
            };
            const readAudio = async (w = window) => fnvBytes((await audioGraph(w).startRendering()).getChannelData(0));
            const readAll = async (w = window) => [readCanvas(w), readGL(w), await readAudio(w)].join('|');

            """

        /// The page's canvas read, then reads through frames and popups WebKit patches natively (no-src, written,
        /// `window.open('')`) or the page script patches on first reach (`srcdoc`, `window.open(url)`) (D6), then a
        /// cross-site frame's own read, then whether reaching that frame and opening a popup on its site threw.
        static func frames(sameSite: URL, crossSite: URL) -> String {
            """
            const top = readCanvas();
            const add = (f) => { document.body.append(f); return f; };
            add(document.createElement('iframe'));
            const noSrc = readCanvas(frames[frames.length - 1]);
            add(document.createElement('iframe'));
            const target = frames[frames.length - 1];
            target.document.open(); target.document.write('<body>written</body>'); target.document.close();
            const written = readCanvas(target);
            const s = document.createElement('iframe');
            s.srcdoc = '<body>srcdoc</body>';
            const srcdocLoaded = new Promise((r) => { s.onload = r; });
            add(s);
            await srcdocLoaded;
            const srcdoc = readCanvas(s.contentWindow);
            const blank = window.open('');
            const blankRead = readCanvas(blank);
            const opened = window.open('\(sameSite)');
            const openedRead = readCanvas(opened);
            blank.close(); opened.close();
            const message = new Promise((r) => addEventListener('message', (e) => r(e.data.canvas), { once: true }));
            const cross = document.createElement('iframe');
            cross.src = '\(crossSite)';
            add(cross);
            const crossRead = await message;
            let harmless = 'harmless';
            try {
              const w = cross.contentWindow;
              if (w !== frames[frames.length - 1] || cross.contentDocument !== null) { harmless = 'changed'; }
              const far = window.open('\(crossSite)');
              if (!far) { harmless = 'no popup'; } else { far.close(); }
            } catch (e) { harmless = String(e); }
            return [top, noSrc, written, srcdoc, blankRead, openedRead, crossRead, harmless].join('|');
            """
        }

        /// An opaque canvas's first `getImageData`, then whether five put → get rounds kept it.
        static let canvasLoop = """
            const x = draw(document.createElement('canvas'));
            let image = x.getImageData(0, 0, 64, 32);
            const first = fnvBytes(image.data);
            for (let i = 0; i < 5; i++) {
              x.putImageData(image, 0, 0);
              image = x.getImageData(0, 0, 64, 32);
              if (fnvBytes(image.data) !== first) { return first + '|drift'; }
            }
            return first + '|stable';
            """

        /// The bytes of a half-transparent canvas, as premultiplied alpha gives them back.
        static let translucent = """
            const c = document.createElement('canvas'); c.width = 16; c.height = 16;
            const x = c.getContext('2d');
            x.fillStyle = 'rgba(200,100,50,0.5)'; x.fillRect(0, 0, 16, 16);
            return Array.from(x.getImageData(0, 0, 16, 16).data).join(',');
            """

        /// A display-p3 red, through `toDataURL` and back into a display-p3 canvas: its first pixel.
        static let displayP3 = """
            const p3 = { colorSpace: 'display-p3' };
            const c = document.createElement('canvas'); c.width = 4; c.height = 4;
            const x = c.getContext('2d', p3);
            x.fillStyle = 'color(display-p3 1 0 0)'; x.fillRect(0, 0, 4, 4);
            const img = new Image(); img.src = c.toDataURL(); await img.decode();
            const d = document.createElement('canvas'); d.width = 4; d.height = 4;
            const y = d.getContext('2d', p3);
            y.drawImage(img, 0, 0);
            return Array.from(y.getImageData(0, 0, 1, 1, p3).data).join(',');
            """

        /// What `toDataURL`, `toBlob`, `getImageData` and `convertToBlob` throw on canvases holding a cross-site image.
        static func tainted(image: URL) -> String {
            """
            const img = new Image(); img.src = '\(image)'; await img.decode();
            const c = document.createElement('canvas'); c.width = 4; c.height = 4;
            c.getContext('2d').drawImage(img, 0, 0);
            const thrown = (f) => { try { f(); return 'none'; } catch (e) { return e.name; } };
            const o = new OffscreenCanvas(4, 4); o.getContext('2d').drawImage(img, 0, 0);
            let blob = 'none';
            try { await o.convertToBlob(); } catch (e) { blob = e.name; }
            return [thrown(() => c.toDataURL()), thrown(() => c.toBlob(() => {})),
              thrown(() => c.getContext('2d').getImageData(0, 0, 1, 1)), blob].join(',');
            """
        }

        static let offscreen = """
            const o = new OffscreenCanvas(32, 16); const x = o.getContext('2d');
            x.fillStyle = '#fff'; x.fillRect(0, 0, 32, 16); x.fillStyle = '#36c'; x.fillRect(4, 4, 10, 8);
            x.fillStyle = 'rgba(200,30,30,0.6)'; x.fillRect(10, 2, 12, 12);
            return fnvBytes(new Uint8Array(await (await o.convertToBlob()).arrayBuffer()));
            """

        /// A WebGL canvas without a preserved drawing buffer, copied by `toDataURL` and `toBlob` in the task that
        /// drew it.
        static let webGLCopy = """
            const c = document.createElement('canvas'); c.width = 16; c.height = 16;
            const g = c.getContext('webgl', { preserveDrawingBuffer: false });
            g.clearColor(0.2, 0.4, 0.6, 1); g.clear(g.COLOR_BUFFER_BIT);
            const url = c.toDataURL();
            const blob = await new Promise((r) => c.toBlob(r));
            return fnv(url) + '|' + fnvBytes(new Uint8Array(await blob.arrayBuffer()));
            """

        /// `readPixels` of an 8×8 WebGL 1 and WebGL 2 canvas cleared to a colour with alpha 0: every byte.
        static let readPixels = """
            const out = [];
            for (const version of ['webgl', 'webgl2']) {
              const c = document.createElement('canvas'); c.width = 8; c.height = 8;
              const g = c.getContext(version, { premultipliedAlpha: false });
              g.clearColor(0.6, 0.4, 0.2, 0); g.clear(g.COLOR_BUFFER_BIT);
              const p = new Uint8Array(256); g.readPixels(0, 0, 8, 8, g.RGBA, g.UNSIGNED_BYTE, p);
              out.push(Array.from(p).join(','));
            }
            return out.join('|');
            """

        /// Rendered audio from `startRendering`'s promise and from `oncomplete`, and a WAV decoded by
        /// `decodeAudioData`'s promise and its callback.
        static let audio = """
            const channel = (b) => fnvBytes(b.getChannelData(0));
            const viaPromise = channel(await audioGraph().startRendering());
            const viaEvent = await new Promise((r) => {
              const ctx = audioGraph();
              ctx.oncomplete = (e) => r(channel(e.renderedBuffer));
              ctx.startRendering();
            });
            const wav = () => {
              const n = 800, rate = 8000, b = new ArrayBuffer(44 + n * 2), v = new DataView(b);
              const text = (o, t) => [...t].forEach((ch, i) => v.setUint8(o + i, ch.charCodeAt(0)));
              text(0, 'RIFF'); v.setUint32(4, 36 + n * 2, true); text(8, 'WAVE');
              text(12, 'fmt '); v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true);
              v.setUint32(24, rate, true); v.setUint32(28, rate * 2, true); v.setUint16(32, 2, true);
              v.setUint16(34, 16, true); text(36, 'data'); v.setUint32(40, n * 2, true);
              for (let i = 0; i < n; i++) { v.setInt16(44 + i * 2, Math.round(Math.sin(i / 5) * 12000), true); }
              return b;
            };
            const context = () => new OfflineAudioContext(1, 1, 8000);
            const decoded = channel(await context().decodeAudioData(wav()));
            const viaCallback = await new Promise((r, j) => context().decodeAudioData(wav(), (b) => r(channel(b)), j));
            return [viaPromise, viaEvent, decoded, viaCallback].join('|');
            """

        /// Each patched method or getter on its real prototype, and `window.open`: `name/length/native|wrapped`.
        static let names = """
            const list = [
              ['HTMLCanvasElement', 'toDataURL'], ['HTMLCanvasElement', 'toBlob'], ['HTMLCanvasElement', 'getContext'],
              ['OffscreenCanvas', 'convertToBlob'], ['OffscreenCanvas', 'getContext'],
              ['CanvasRenderingContext2D', 'getImageData'], ['OffscreenCanvasRenderingContext2D', 'getImageData'],
              ['WebGLRenderingContext', 'readPixels'], ['WebGL2RenderingContext', 'readPixels'],
              ['AudioBuffer', 'copyFromChannel'], ['AnalyserNode', 'getFloatFrequencyData'],
              ['AnalyserNode', 'getFloatTimeDomainData'], ['AnalyserNode', 'getByteFrequencyData'],
              ['AnalyserNode', 'getByteTimeDomainData'], ['OfflineAudioContext', 'startRendering'],
              ['BaseAudioContext', 'decodeAudioData'], ['OfflineAudioCompletionEvent', 'renderedBuffer'],
              ['HTMLIFrameElement', 'contentWindow'], ['HTMLIFrameElement', 'contentDocument'],
            ];
            const isNative = (f) => /\\[native code\\]/.test(Function.prototype.toString.call(f));
            const describe = (label, f) =>
              f ? `${label}=${f.name}/${f.length}/${isNative(f) ? 'native' : 'wrapped'}` : `${label}=missing`;
            const out = list.map(([c, k]) => {
              const d = window[c] && Object.getOwnPropertyDescriptor(window[c].prototype, k);
              return describe(`${c}.${k}`, d && (d.value || d.get));
            });
            let holder = window;
            while (holder && !Object.getOwnPropertyDescriptor(holder, 'open')) {
              holder = Object.getPrototypeOf(holder);
            }
            out.push(describe('open', holder && Object.getOwnPropertyDescriptor(holder, 'open').value));
            return out.join('|');
            """

        /// Replaces the document with `document.open/write`, then reads a canvas in it.
        static let documentWrite = """
            document.open();
            document.write('<!doctype html><title>written</title><body>written</body>');
            document.close();
            return readCanvas();
            """
    }
#endif
