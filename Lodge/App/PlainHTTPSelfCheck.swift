#if DEBUG
    import AppKit
    import LodgeKit
    import WebKit

    extension LayoutRenderer {
        /// Runs `checkPlainHTTPInWebKit`, then removes the store it made for a named workspace, once nothing of the
        /// check holds it any more.
        static func checkPlainHTTP() {
            let namedID = UUID()
            autoreleasepool { checkPlainHTTPInWebKit(namedWorkspace: namedID) }
            var removed = false
            for _ in 0..<20 where !removed {
                var done = false
                Task {
                    removed = (try? await WebViewRegistry.removeWebsiteData(for: namedID)) != nil
                    done = true
                }
                while !done { autoreleasepool { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3)) } }
            }
            print("Plain http: the named workspace's store is removed after the check: \(removed ? "ok" : "FAILED")")
        }

        /// The plain-http warning (D8) in real WebKit, off screen, printing ok or FAILED for each: pages come from
        /// `AuthCheckServer` on the loopback interface as two hosts, `localhost` and `127.0.0.1`, which count as remote
        /// once `BrowserModel.selfCheckWarnsLoopback` is on. Whether a warned load sent anything is told at the server.
        /// Default, a named workspace made for the check and Anonymous each run on their own store; every tab closes
        /// and the server stops when the check ends.
        private static func checkPlainHTTPInWebKit(namedWorkspace namedID: UUID) {
            func report(_ name: String, _ passed: Bool) { print("Plain http: \(name): \(passed ? "ok" : "FAILED")") }
            func settle(_ seconds: Double = 0.3) {
                autoreleasepool { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
            }
            func waitUntil(_ seconds: Double = 8, _ done: () -> Bool) -> Bool {
                let deadline = Date.now.addingTimeInterval(seconds)
                while !autoreleasepool(invoking: done), Date.now < deadline { settle(0.02) }
                return autoreleasepool(invoking: done)
            }

            let server = AuthCheckServer()
            guard server.start() else { return report("the loopback server starts", false) }
            defer { server.stop() }
            let one = "localhost"
            let other = "127.0.0.1"
            var prompts = 0
            TabController.selfCheckAnswer = { _ in
                prompts += 1
                return nil
            }
            defer {
                TabController.selfCheckAnswer = nil
                BrowserModel.selfCheckWarnsLoopback = false
            }

            let placement = AuthCheckPlacement()
            let registry = WebViewRegistry()
            func model(_ workspace: UUID, store: StoreRef?) -> BrowserModel {
                let model = BrowserModel(workspace: workspace, store: store, registry: registry)
                model.placement = placement
                return model
            }
            let defaultModel = model(Workspace.defaultID, store: .global)
            let namedModel = model(namedID, store: .workspace(namedID))
            let anonymousModel = model(Workspace.anonymousID, store: nil)
            let window = NSWindow(
                contentRect: NSRect(x: -10_000, y: -10_000, width: 800, height: 600), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer {
                window.close()
                for model in [defaultModel, namedModel, anonymousModel] {
                    for id in model.tabs.tabs.map(\.id) { autoreleasepool { model.close(id) } }
                }
                registry.detach(tabs: namedModel.tabs.tabs.map(\.id))
                settle()
                registry.forget(store: .workspace(namedID))
            }

            typealias Tab = (id: TabID, view: LodgeWebView)
            var shown: (model: BrowserModel, id: TabID)?
            /// Puts the tab on screen in place of the one shown, as a window's selection does.
            func show(_ model: BrowserModel, _ id: TabID) {
                if let previous = shown {
                    placement.shown = nil
                    previous.model.registry.webView(for: previous.id)?.removeFromSuperview()
                    previous.model.didSelect(nil, previous: previous.id, previousStillShown: false)
                }
                shown = (model, id)
                placement.shown = id
                guard let view = model.view(for: id, load: false), let content = window.contentView else { return }
                view.frame = content.bounds
                content.addSubview(view)
                model.didSelect(id, previous: nil, previousStillShown: false)
            }
            func open(_ model: BrowserModel, shown isShown: Bool = true) -> Tab? {
                let tab = BrowserTab(store: model.newTabStore())
                guard let view = model.append(tab, load: false) else { return nil }
                if isShown { show(model, tab.id) }
                return (tab.id, view)
            }
            func page(_ host: String, _ name: String) -> URL { server.url(host, "/p/\(name)") }
            func loaded(_ tab: Tab, _ title: String) -> Bool { waitUntil { tab.view.title == title && !tab.view.isLoading } }
            func script(_ view: WKWebView, _ source: String) -> String? {
                var answer: String?
                var done = false
                view.evaluateJavaScript(source) { value, _ in
                    answer = value as? String
                    done = true
                }
                _ = waitUntil { done }
                return answer
            }
            /// Loads `name` at `host` in the tab; true once its warning is up for that page, nothing having reached the
            /// server, and the view still showing what it showed.
            func warns(_ model: BrowserModel, _ tab: Tab, _ host: String, _ name: String) -> Bool {
                let url = page(host, name)
                let before = tab.view.url
                guard model.load(url, in: tab.id), waitUntil(8, { model.plainHTTPWarnings[tab.id] == url }) else {
                    return false
                }
                settle(0.5)
                return server.hits("/p/\(name)") == 0 && tab.view.url == before && model.tabs[tab.id]?.url == url
                    && model.security[tab.id] == SiteSecurity(url: url, hasOnlySecureContent: false)
            }
            func goesThrough(_ model: BrowserModel, _ tab: Tab, _ host: String, _ name: String) -> Bool {
                model.load(page(host, name), in: tab.id) && loaded(tab, name) && model.plainHTTPWarnings[tab.id] == nil
                    && server.hits("/p/\(name)") == 1
            }

            guard let main = open(defaultModel) else { return report("a shown tab opens", false) }
            report("a loopback http page loads with no warning", goesThrough(defaultModel, main, one, "exempt"))
            BrowserModel.selfCheckWarnsLoopback = true

            let blocked = warns(defaultModel, main, other, "blocked")
            report("a plain http page shows the warning and sends nothing to the server", blocked)
            defaultModel.goBackFromPlainHTTP(main.id)
            settle()
            report(
                "Go Back leaves the page as it was, its address the page's again",
                blocked && defaultModel.plainHTTPWarnings[main.id] == nil && main.view.title == "exempt"
                    && defaultModel.tabs[main.id]?.url == page(one, "exempt") && server.hits("/p/blocked") == 0)

            if let blank = open(defaultModel) {
                let warned = warns(defaultModel, blank, other, "fromblank")
                defaultModel.goBackFromPlainHTTP(blank.id)
                settle()
                report(
                    "Go Back in a new tab leaves it blank",
                    warned && defaultModel.tabs[blank.id]?.url == nil && blank.view.url == nil
                        && defaultModel.selectionTabs.blank.contains(blank.id))
                defaultModel.close(blank.id)
                show(defaultModel, main.id)
            }

            let continued =
                warns(defaultModel, main, other, "continued")
                && {
                    defaultModel.continueToPlainHTTP(main.id)
                    return loaded(main, "continued") && server.hits("/p/continued") == 1
                }()
            report("Continue loads the page", continued && defaultModel.plainHTTPWarnings[main.id] == nil)
            report(
                "a later load of that host in the same workspace goes straight through",
                continued && goesThrough(defaultModel, main, other, "later"))
            if let second = open(defaultModel) {
                report(
                    "another tab of the same workspace goes straight through",
                    goesThrough(defaultModel, second, other, "secondtab"))
                defaultModel.close(second.id)
                show(defaultModel, main.id)
            }

            // A tab woken at a plain http address (restored, resting) keeps it on Go Back, its page blank.
            let woken = BrowserTab(store: defaultModel.newTabStore(), url: page(one, "woken"))
            defaultModel.append(woken, load: true)
            let wokeWarned = waitUntil { defaultModel.plainHTTPWarnings[woken.id] == page(one, "woken") }
            settle(0.5)
            defaultModel.goBackFromPlainHTTP(woken.id)
            report(
                "Go Back on a tab woken at a plain http address keeps that address on a blank page",
                wokeWarned && server.hits("/p/woken") == 0 && defaultModel.tabs[woken.id]?.url == page(one, "woken")
                    && registry.webView(for: woken.id)?.url == nil
                    && !defaultModel.selectionTabs.blank.contains(woken.id))
            defaultModel.close(woken.id)
            show(defaultModel, main.id)

            // Another store has not allowed the host.
            if let named = open(namedModel) {
                report("a named workspace still warns", warns(namedModel, named, other, "named"))
            } else {
                report("a named workspace still warns", false)
            }
            // A warned back load: Continue goes to its history entry, so the page it left stays ahead.
            if let history = open(namedModel) {
                BrowserModel.selfCheckWarnsLoopback = false
                let walked =
                    goesThrough(namedModel, history, one, "histfirst")
                    && goesThrough(namedModel, history, other, "histsecond")
                BrowserModel.selfCheckWarnsLoopback = true
                history.view.goBack()
                let warned = walked && waitUntil { namedModel.plainHTTPWarnings[history.id] == page(one, "histfirst") }
                settle(0.5)
                let quiet = warned && server.hits("/p/histfirst") == 1 && history.view.title == "histsecond"
                namedModel.continueToPlainHTTP(history.id)
                report(
                    "Continue after a warned back load goes to that history entry, the page it left still ahead",
                    quiet && loaded(history, "histfirst") && namedModel.plainHTTPWarnings[history.id] == nil
                        && history.view.backForwardList.forwardItem?.url == page(other, "histsecond"))
            } else {
                report("Continue after a warned back load goes to that history entry, the page it left still ahead", false)
            }
            if let anonymous = open(anonymousModel), let second = open(anonymousModel) {
                let warned = warns(anonymousModel, anonymous, other, "anonymous")
                anonymousModel.continueToPlainHTTP(anonymous.id)
                let allowed = warned && loaded(anonymous, "anonymous")
                report("an Anonymous tab still warns", warned)
                report(
                    "an Anonymous tab's Continue is not another Anonymous tab's",
                    allowed && warns(anonymousModel, second, other, "anonymoussecond"))
                let store = anonymousModel.tabs[anonymous.id]?.store
                let kept = store.map { registry.plainHTTPHosts(for: $0) == [other] } == true
                anonymousModel.close(anonymous.id)
                settle(0.5)
                report(
                    "an Anonymous tab's allowed hosts go with its store",
                    kept && store.map { registry.plainHTTPHosts(for: $0).isEmpty } == true)
            } else {
                report("an Anonymous tab still warns", false)
            }
            show(defaultModel, main.id)

            // A server redirect to a host not allowed (D8) is stopped mid-load: the main frame's sign-in target is the
            // committed page again, so another site's image challenge after it gets no prompt.
            let redirect = server.url(other, "/r?to=\(page(one, "redirected"))")
            prompts = 0
            let redirected =
                loaded(main, "later") && script(main.view, "location.href = '\(redirect)'; 'went'") == "went"
                && waitUntil { defaultModel.plainHTTPWarnings[main.id] == page(one, "redirected") }
            let stopped = redirected && waitUntil { !main.view.isLoading }
            settle(0.5)
            report(
                "a server redirect to a plain http host warns, with nothing sent there",
                stopped && server.hits("/r") == 1 && server.hits("/p/redirected") == 0 && main.view.title == "later"
                    && defaultModel.tabs[main.id]?.url == page(one, "redirected"))
            let image = "/a/afterwarn/pictured"
            let fetched =
                stopped
                && script(
                    main.view,
                    "(() => { const i = new Image(); i.src = '\(server.url(one, image))'; "
                        + "document.body.append(i); return 'added' })()") == "added"
                && waitUntil { server.hits(image) > 0 }
            settle(1)
            report(
                "after a warned redirect another site's image challenge gets no prompt",
                fetched && prompts == 0 && server.authorized(image) == 0)
            defaultModel.goBackFromPlainHTTP(main.id)
            report("Go Back after a warned redirect shows the page's address", defaultModel.tabs[main.id]?.url == page(other, "later"))

            // A popup to a plain http page warns in the popup's tab, not its opener's.
            let before = Set(defaultModel.tabs.tabs.map(\.id))
            let popped =
                script(main.view, "window.open('\(page(one, "popped"))'); 'opened'") == "opened"
                && waitUntil { defaultModel.tabs.tabs.count > before.count }
            let popup = defaultModel.tabs.tabs.first { !before.contains($0.id) }?.id
            let popupWarned = popped && waitUntil { popup.flatMap { defaultModel.plainHTTPWarnings[$0] } == page(one, "popped") }
            settle(0.5)
            report(
                "a popup to a plain http page warns in the popup's tab",
                popupWarned && defaultModel.plainHTTPWarnings[main.id] == nil && server.hits("/p/popped") == 0
                    && main.view.title == "later")

            // A download link in the main frame is a main-frame load too.
            let downloadURL = page(one, "downloaded")
            let clicked =
                script(
                    main.view,
                    "(() => { const a = document.createElement('a'); a.href = '\(downloadURL)'; a.download = 'x.html'; "
                        + "document.body.append(a); a.click(); return 'clicked' })()") == "clicked"
            let downloadWarned = clicked && waitUntil { defaultModel.plainHTTPWarnings[main.id] == downloadURL }
            settle(1)
            report(
                "a download link to a plain http host warns, with nothing sent there",
                downloadWarned && server.hits("/p/downloaded") == 0)
            defaultModel.goBackFromPlainHTTP(main.id)

            // Switching away keeps a tab's warning; releasing a resting tab ends it on the page it showed; closing a
            // tab drops it.
            if let back = open(defaultModel, shown: false) {
                let shownFirst = goesThrough(defaultModel, back, other, "resting")
                let warned = shownFirst && warns(defaultModel, back, one, "restingwarn")
                show(defaultModel, back.id)
                show(defaultModel, main.id)
                let kept = warned && defaultModel.plainHTTPWarnings[back.id] == page(one, "restingwarn")
                report("a tab switched away from and back keeps its warning", kept)
                var done = false
                Task {
                    await defaultModel.release(candidates: [back.id]) { _ in false }
                    done = true
                }
                _ = waitUntil { done }
                report(
                    "a released tab's warning ends on the page it showed",
                    kept && defaultModel.plainHTTPWarnings[back.id] == nil
                        && defaultModel.tabs[back.id]?.url == page(other, "resting"))
            }
            if let closing = open(defaultModel, shown: false) {
                let warned = warns(defaultModel, closing, one, "closing")
                defaultModel.close(closing.id)
                report("a closed tab's warning goes with it", warned && defaultModel.plainHTTPWarnings[closing.id] == nil)
            }
            report("no sheet was put up", NSApp.modalWindow == nil && window.attachedSheet == nil)
        }
    }
#endif
