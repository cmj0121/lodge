#if DEBUG
    import AppKit
    import LodgeKit
    import Network
    import WebKit

    extension LayoutRenderer {
        /// Runs `checkAuthInWebKit`, then removes the store it made for a named workspace, once nothing of the check
        /// holds it any more.
        static func checkAuth() {
            let namedID = UUID()
            autoreleasepool { checkAuthInWebKit(namedWorkspace: namedID) }
            var removal: Result<Void, any Error>?
            for _ in 0..<20 where (try? removal?.get()) == nil {
                var done = false
                Task {
                    do {
                        try await WebViewRegistry.removeWebsiteData(for: namedID)
                        removal = .success(())
                    } catch {
                        removal = .failure(error)
                    }
                    done = true
                }
                while !done { autoreleasepool { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3)) } }
            }
            if case .failure(let error) = removal { print("Auth: removing the named workspace's store: \(error)") }
            let removed = (try? removal?.get()) != nil
            print("Auth: the named workspace's store is removed after the check: \(removed ? "ok" : "FAILED")")
        }

        /// HTTP sign-in (D1, D3, D4) in real WebKit, off screen, printing ok or FAILED for each: pages come from
        /// `AuthCheckServer` on the loopback interface, reached as two sites, `localhost` and `127.0.0.1`, and each
        /// sheet is answered through `TabController.selfCheckAnswer` where it would be shown. A tab counts as shown
        /// while `AuthCheckPlacement` says so and its view sits in a window that is never ordered in. Default runs on
        /// its own store, a named workspace on a store made for the check and removed after it, and each Anonymous tab
        /// on its own; whether an answer reaches another store is told at the server, by the `Authorization` headers
        /// each path received. Every tab closes and the server stops when the check ends.
        private static func checkAuthInWebKit(namedWorkspace namedID: UUID) {
            func report(_ name: String, _ passed: Bool) { print("Auth: \(name): \(passed ? "ok" : "FAILED")") }
            func settle(_ seconds: Double = 0.3) {
                autoreleasepool { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
            }
            func waitUntil(_ seconds: Double = 8, _ done: () -> Bool) -> Bool {
                let deadline = Date.now.addingTimeInterval(seconds)
                while !autoreleasepool(invoking: done), Date.now < deadline { settle(0.02) }
                return autoreleasepool(invoking: done)
            }

            let server = AuthCheckServer()
            guard server.start(), let port = server.port else { return report("the loopback server starts", false) }
            defer { server.stop() }
            let one = "localhost"
            let other = "127.0.0.1"
            func url(_ host: String, _ path: String) -> URL { server.url(host, path) }
            let right = (user: AuthCheckServer.user, password: AuthCheckServer.password)
            let wrong = (user: AuthCheckServer.user, password: "wrong")

            /// Every prompt the sheet would have shown since the last `visit`, and how the next one is answered.
            var prompts: [AuthPrompt] = []
            var respond: (AuthPrompt) -> (user: String, password: String)? = { _ in nil }
            TabController.selfCheckAnswer = { prompt in
                prompts.append(prompt)
                return respond(prompt)
            }
            defer { TabController.selfCheckAnswer = nil }
            /// Answers the coming prompts with `answers` in turn, then with Cancel.
            func answering(_ answers: [(user: String, password: String)?]) {
                var left = answers
                prompts = []
                respond = { _ in left.isEmpty ? nil : left.removeFirst() }
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
                // Closing a model's last tab leaves a blank one, which holds the store until it is detached.
                registry.detach(tabs: namedModel.tabs.tabs.map(\.id))
                settle()
                registry.forget(store: .workspace(namedID))
            }

            typealias Tab = (id: TabID, view: LodgeWebView)
            /// The tab on screen, and the model it belongs to.
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
            /// A new blank tab of `model`, on screen or in the background.
            func open(_ model: BrowserModel, shown isShown: Bool) -> Tab? {
                let tab = BrowserTab(store: model.newTabStore())
                guard let view = model.append(tab, load: false) else { return nil }
                if isShown { show(model, tab.id) }
                return (tab.id, view)
            }
            func loaded(_ view: WKWebView, _ title: String) -> Bool {
                waitUntil { view.title == title && !view.isLoading }
            }
            /// Loads `path` at `host` in the tab with `answers` for its prompts; the prompts, once the page is titled
            /// `title` (a protected page's name, or "denied <name>" for its 401 page); nil when it never is.
            func visit(
                _ model: BrowserModel, _ tab: Tab, _ host: String, _ path: String,
                answers: [(user: String, password: String)?], until title: String
            ) -> [AuthPrompt]? {
                answering(answers)
                guard model.load(url(host, path), in: tab.id), loaded(tab.view, title) else { return nil }
                settle(0.2)
                return prompts
            }
            /// Whether the tab keeps its view when the model tries to release it as a background tab.
            func held(_ model: BrowserModel, _ tab: Tab) -> Bool {
                var isHeld: Bool?
                Task { isHeld = await model.release(candidates: [tab.id]) { _ in false } }
                _ = waitUntil { isHeld != nil }
                return isHeld == true && model.registry.webView(for: tab.id) === tab.view
            }
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
            /// The prompt is for `host` on the check's port, in the space `space`.
            func asks(_ prompt: AuthPrompt?, _ host: String, _ space: String) -> Bool {
                prompt?.host == "\(host):\(port)" && prompt?.realm == AuthCheckServer.realm(space)
            }

            guard let main = open(defaultModel, shown: true) else { return report("a shown tab opens", false) }

            // The sheet and its answers (D3).
            let first = visit(defaultModel, main, one, "/a/shown/page", answers: [right], until: "page")
            report(
                "a shown tab prompts with its host and realm",
                first?.count == 1 && asks(first?.first, one, "shown") && first?.first?.isPlainHTTP == true
                    && first?.first?.failed == false)
            let retried = visit(defaultModel, main, one, "/a/retry/retried", answers: [wrong, right], until: "retried")
            report(
                "a wrong then right answer loads the page, the second prompt saying the first failed",
                retried?.count == 2 && retried?.first?.failed == false && retried?.last?.failed == true
                    && asks(retried?.last, one, "retry"))
            let cancelled = visit(
                defaultModel, main, one, "/a/cancel/cancelled", answers: [nil], until: "denied cancelled")
            report("Cancel shows the server's 401 page", cancelled?.count == 1)
            let again = visit(defaultModel, main, one, "/a/shown/again", answers: [], until: "again")
            report(
                "an answer is used again in its own workspace with no prompt",
                again?.isEmpty == true && server.authorized("/a/shown/again") > 0)

            // A background tab's challenge (D1).
            if let back = open(defaultModel, shown: false) {
                let path = "/a/background/waited"
                prompts = []
                var switched = false
                respond = { _ in
                    if !switched {
                        switched = true
                        show(defaultModel, main.id)
                    }
                    return right
                }
                _ = defaultModel.load(url(one, path), in: back.id)
                let asked = waitUntil { server.hits(path) > 0 }
                settle(1)
                let waited = asked && prompts.isEmpty && held(defaultModel, back)
                show(defaultModel, back.id)
                let switchedAway = waitUntil { prompts.count == 1 }
                settle(1)
                let rewaited =
                    switchedAway && back.view.title != "waited" && server.authorized(path) == 0
                    && held(defaultModel, back)
                show(defaultModel, back.id)
                let finished = loaded(back.view, "waited") && prompts.count == 2
                report("a background tab's challenge holds the tab with no prompt until it is shown", waited && finished)
                report("switching away while its sheet is up holds the challenge again", rewaited && finished)
            } else {
                report("a background tab's challenge holds the tab with no prompt until it is shown", false)
            }
            if let back = open(defaultModel, shown: false) {
                let frames = ["/a/queue/one", "/a/queue/two"].map { url(one, $0).absoluteString }
                answering([right])
                _ = defaultModel.load(server.page(one, "queue", frames: frames), in: back.id)
                let asked = waitUntil { frames.allSatisfy { server.hits(URL(string: $0)!.path()) > 0 } }
                settle(1)
                let before = TabController.selfCheckResumes
                show(defaultModel, back.id)
                let titles = "[...document.querySelectorAll('iframe')].map(f => f.contentDocument.title).join()"
                let framed = asked && waitUntil { script(back.view, titles) == "one,two" }
                // WebKit holds a second challenge of the same space until the first is answered, then answers it with
                // that answer itself: one challenge reaches the tab, so the queue's own same-space reuse is not what
                // runs here.
                report(
                    "WebKit merges same-space challenges: one prompt and one answer load both frames",
                    framed && prompts.count == 1 && TabController.selfCheckResumes - before == 1
                        && server.authorized("/a/queue/one") > 0 && server.authorized("/a/queue/two") > 0)
                show(defaultModel, main.id)
            } else {
                report("WebKit merges same-space challenges: one prompt and one answer load both frames", false)
            }

            // Other sites (D3).
            let frame = "/a/crossframe/framed"
            let image = "/a/crossimage/pictured"
            answering([right])
            let crossed =
                defaultModel.load(
                    server.page(one, "crossed", frames: [url(other, frame).absoluteString],
                        images: [url(other, image).absoluteString]), in: main.id)
                && loaded(main.view, "crossed") && waitUntil { server.hits(frame) > 0 && server.hits(image) > 0 }
            settle(1)
            report(
                "another site's image or frame challenge gets no prompt",
                crossed && prompts.isEmpty && server.authorized(frame) == 0 && server.authorized(image) == 0)
            answering([right])
            let away =
                loaded(main.view, "crossed")
                && script(main.view, "location.href = '\(url(other, "/a/away/arrived"))'; 'went'") == "went"
                && loaded(main.view, "arrived")
            report("a main-frame navigation to another site prompts", away && prompts.count == 1 && asks(prompts.first, other, "away"))
            let start = visit(defaultModel, main, one, "/p/start", answers: [], until: "start")
            answering([right])
            let redirect = server.url(one, "/r?to=\(url(other, "/a/login/landed"))")
            let landed =
                start != nil && script(main.view, "location.href = '\(redirect)'; 'went'") == "went"
                && loaded(main.view, "landed")
            report(
                "a main-frame navigation redirected by the server to another site prompts",
                landed && prompts.count == 1 && asks(prompts.first, other, "login"))

            // A main frame's target is the navigation WebKit started, not one only asked about: once that navigation
            // stops, the site it went to is another site again.
            if let back = open(defaultModel, shown: false) {
                let waiting = "/a/stopwait/never"
                let afterStop = "/a/stopimage/pictured"
                answering([right])
                let stopped =
                    defaultModel.load(server.page(one, "stopstart"), in: back.id) && loaded(back.view, "stopstart")
                    && script(back.view, "location.href = '\(url(other, waiting))'; 'went'") == "went"
                    && waitUntil { server.hits(waiting) > 0 }
                settle(0.5)
                defaultModel.stopLoading(back.id)
                let ended = stopped && waitUntil { !back.view.isLoading }
                let fetched =
                    ended
                    && script(
                        back.view,
                        "(() => { const i = new Image(); i.src = '\(url(other, afterStop))'; "
                            + "document.body.append(i); return 'added' })()") == "added"
                    && waitUntil { server.hits(afterStop) > 0 }
                settle(1)
                show(defaultModel, back.id)
                settle(1)
                report(
                    "a main-frame navigation to another site that stops leaves that site's image with no prompt",
                    fetched && prompts.isEmpty && server.authorized(afterStop) == 0 && server.authorized(waiting) == 0
                        && back.view.title == "stopstart")
                show(defaultModel, main.id)
            } else {
                report("a main-frame navigation to another site that stops leaves that site's image with no prompt", false)
            }

            // A page that keeps asking (D1): after a Cancel its other challenges get no sheet until the next commit, and
            // no more than eight wait behind the sheet.
            func addFrame(_ view: WKWebView, _ path: String) -> Bool {
                let source = "(() => { const f = document.createElement('iframe'); f.src = '\(url(one, path))'; "
                    + "document.body.append(f); return 'added' })()"
                return script(view, source) == "added"
            }
            let refusing = visit(defaultModel, main, one, "/p/refusing", answers: [nil], until: "refusing")
            let firstFrame = "/a/refusefirst/framed"
            let secondFrame = "/a/refusesecond/framed"
            let cancelledOnce =
                refusing != nil && addFrame(main.view, firstFrame)
                && waitUntil { server.hits(firstFrame) > 0 && prompts.count == 1 }
            settle(0.5)
            let refusalsBefore = TabController.selfCheckRefusals
            let refused =
                cancelledOnce && addFrame(main.view, secondFrame)
                && waitUntil { TabController.selfCheckRefusals > refusalsBefore }
            settle(0.5)
            let quiet = refused && prompts.count == 1 && server.authorized(secondFrame) == 0
            answering([right])
            let navigated =
                script(main.view, "location.href = '\(url(one, "/a/refusenav/arrived"))'; 'went'") == "went"
                && loaded(main.view, "arrived") && prompts.count == 1
            answering([nil])
            let thirdFrame = "/a/refusethird/framed"
            let asksAgain = navigated && addFrame(main.view, thirdFrame) && waitUntil { prompts.count == 1 }
            report(
                "after a Cancel the page's other challenges are rejected with no prompt, its navigation still prompts",
                quiet && navigated)
            report("after the next commit the page's challenges prompt again", asksAgain)
            // WebKit keeps six connections to an origin, a waiting challenge holding one, so the frames come from two.
            let second = AuthCheckServer()
            defer { second.stop() }
            if second.start(), let back = open(defaultModel, shown: false) {
                let frames = (1...10).map {
                    ($0.isMultiple(of: 2) ? server : second).url(one, "/a/flood\($0)/framed").absoluteString
                }
                answering([])
                let refusalsBefore = TabController.selfCheckRefusals
                _ = defaultModel.load(server.page(one, "flood", frames: frames), in: back.id)
                let capped = waitUntil { TabController.selfCheckRefusals - refusalsBefore == 2 }
                settle(1)
                let resumesBefore = TabController.selfCheckResumes
                show(defaultModel, back.id)
                let drained = waitUntil { TabController.selfCheckResumes - resumesBefore == 8 }
                settle(0.5)
                report(
                    "no more than eight challenges wait: the rest are rejected with no prompt",
                    capped && TabController.selfCheckRefusals - refusalsBefore == 2)
                report(
                    "one Cancel rejects the waiting challenges of other spaces with no further prompt",
                    drained && prompts.count == 1 && TabController.selfCheckResumes - resumesBefore == 8)
                show(defaultModel, main.id)
            } else {
                report("no more than eight challenges wait: the rest are rejected with no prompt", false)
            }
            // A full queue still takes the main frame's own navigation: the page starts a navigation the server holds,
            // fills the queue from two other origins while it waits, and the navigation's challenge still prompts.
            let third = AuthCheckServer()
            defer { third.stop() }
            if third.start(), let back = open(defaultModel, shown: false) {
                let target = url(one, "/a/navfull/arrived")
                let delayed = server.url(one, "/d?to=\(target)")
                let frames = (1...10).map {
                    ($0.isMultiple(of: 2) ? second : third).url(one, "/a/full\($0)/framed").absoluteString
                }
                prompts = []
                respond = { $0.realm == AuthCheckServer.realm("navfull") ? right : nil }
                let refusalsBefore = TabController.selfCheckRefusals
                let started =
                    defaultModel.load(server.page(one, "fullstart"), in: back.id) && loaded(back.view, "fullstart")
                    && script(back.view, "location.href = '\(delayed)'; 'went'") == "went"
                    && waitUntil { server.hits("/d") > 0 }
                let source = frames.map { "{ const f = document.createElement('iframe'); f.src = '\($0)'; "
                    + "document.body.append(f) }" }.joined(separator: " ")
                let filled =
                    started && script(back.view, "(() => { \(source) return 'added' })()") == "added"
                    && waitUntil { TabController.selfCheckRefusals - refusalsBefore == 2 }
                let asked = filled && waitUntil { server.hits("/a/navfull/arrived") > 0 }
                settle(0.5)
                show(defaultModel, back.id)
                let arrived = asked && loaded(back.view, "arrived")
                report(
                    "with eight challenges waiting, the main frame's navigation still prompts",
                    arrived && prompts.last?.realm == AuthCheckServer.realm("navfull")
                        && server.authorized("/a/navfull/arrived") > 0)
                show(defaultModel, main.id)
            } else {
                report("with eight challenges waiting, the main frame's navigation still prompts", false)
            }

            // Each workspace's answers stay in its store (D4): another store's tab is asked again, and the server
            // never gets the answer ahead of the prompt.
            /// The tab loads `path`, is asked for `space` and cancels, and the server got no `Authorization` for it.
            func unseen(_ model: BrowserModel, _ tab: Tab?, _ path: String, _ space: String, _ name: String) -> Bool {
                guard let tab, let asked = visit(model, tab, one, path, answers: [nil], until: "denied \(name)")
                else { return false }
                return asked.count == 1 && asks(asked.first, one, space) && server.hits(path) > 0
                    && server.authorized(path) == 0
            }
            let named = open(namedModel, shown: true)
            report(
                "an answer given in Default is not seen in a named workspace, nor sent ahead",
                unseen(namedModel, named, "/a/shown/named", "shown", "named"))
            let namedSigned = named.flatMap {
                visit(namedModel, $0, one, "/a/named/signed", answers: [right], until: "signed")
            }
            let namedAgain = named.flatMap { visit(namedModel, $0, one, "/a/named/again", answers: [], until: "again") }
            show(defaultModel, main.id)
            report(
                "an answer given in a named workspace is not seen in Default, nor sent ahead",
                namedSigned?.count == 1 && namedAgain?.isEmpty == true && server.authorized("/a/named/again") > 0
                    && unseen(defaultModel, main, "/a/named/default", "named", "default"))
            let anonymous = open(anonymousModel, shown: true)
            let anonymousSigned = anonymous.flatMap {
                visit(anonymousModel, $0, one, "/a/anonymous/signed", answers: [right], until: "signed")
            }
            show(defaultModel, main.id)
            report(
                "an answer given in an Anonymous tab is not seen in Default, nor sent ahead",
                anonymousSigned?.count == 1
                    && unseen(defaultModel, main, "/a/anonymous/from-default", "anonymous", "from-default"))
            report(
                "an answer given in an Anonymous tab is not seen in another Anonymous tab, nor sent ahead",
                anonymousSigned?.count == 1
                    && unseen(
                        anonymousModel, open(anonymousModel, shown: true), "/a/anonymous/second", "anonymous",
                        "second"))
            show(defaultModel, main.id)

            // A tab that goes, or stops, while its challenge waits (D1): resumed once, with no sheet.
            if let back = open(defaultModel, shown: false) {
                let path = "/a/closing/gone"
                answering([right])
                _ = defaultModel.load(url(one, path), in: back.id)
                let asked = waitUntil { server.hits(path) > 0 }
                settle(0.5)
                let before = TabController.selfCheckResumes
                let wasHeld = asked && held(defaultModel, back)
                defaultModel.close(back.id)
                settle(1)
                report(
                    "a challenge waiting in a held tab that goes is resumed once, with no prompt",
                    wasHeld && TabController.selfCheckResumes - before == 1 && prompts.isEmpty)
            } else {
                report("a challenge waiting in a held tab that goes is resumed once, with no prompt", false)
            }
            if let back = open(defaultModel, shown: false) {
                let path = "/a/stopping/stopped"
                answering([right])
                _ = defaultModel.load(url(one, path), in: back.id)
                let asked = waitUntil { server.hits(path) > 0 }
                settle(0.5)
                let before = TabController.selfCheckResumes
                defaultModel.stopLoading(back.id)
                let ended = waitUntil { !back.view.isLoading }
                settle(0.5)
                report(
                    "a stop while a challenge waits resumes it once and ends the load, with no prompt",
                    asked && ended && TabController.selfCheckResumes - before == 1 && prompts.isEmpty)
            } else {
                report("a stop while a challenge waits resumes it once and ends the load, with no prompt", false)
            }
            report("no sheet was put up", NSApp.modalWindow == nil && window.attachedSheet == nil)
        }
    }

    /// Auth self-check only: the one tab a window shows, where a coordinator would say; no fingerprint settings.
    @MainActor
    final class AuthCheckPlacement: WindowPlacement {
        var shown: TabID?
        func isShown(_ tab: TabID) -> Bool { tab == shown }
        func didOpen(_ tab: TabID, in workspace: UUID, from source: TabID?) {}
        func willClose(_ tabs: Set<TabID>, of model: BrowserModel) {}
        func fingerprint(for workspaceID: UUID) -> FingerprintSettings? { nil }
        func setFingerprint(off: Bool, _ site: String, for workspaceID: UUID) {}
    }

    /// Auth self-check only: an HTTP server on the loopback interface. `/a/<space>/<name>` is a page titled `name`
    /// behind Basic authentication in the realm `realm(space)`, answered 401 with a page titled "denied <name>" until
    /// the request carries `user` and `password`; `/p/<name>` is a page titled `name` with the frames and images its
    /// `frame` and `image` query items name; `/r?to=<url>` redirects there with a 302, and `/d?to=<url>` does so after three seconds. Each path's `Authorization`
    /// headers are recorded, a request without one as an empty string. Nothing is cached.
    @MainActor
    final class AuthCheckServer {
        static let user = "lodge"
        static let password = "sesame"
        static func realm(_ space: String) -> String { "Lodge \(space)" }

        private var listener: NWListener?
        private var connections: [ObjectIdentifier: NWConnection] = [:]
        private(set) var port: UInt16?
        private var failed = false
        private var authorizations: [String: [String]] = [:]
        private let expected = "Basic " + Data("\(AuthCheckServer.user):\(AuthCheckServer.password)".utf8)
            .base64EncodedString()

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
                        print("Auth: the loopback server failed: \(error)")
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

        /// The page `/p/<name>` at `host` with the given frames and images.
        func page(_ host: String, _ name: String, frames: [String] = [], images: [String] = []) -> URL {
            var components = URLComponents(url: url(host, "/p/\(name)"), resolvingAgainstBaseURL: false)!
            components.queryItems =
                frames.map { URLQueryItem(name: "frame", value: $0) } + images.map { URLQueryItem(name: "image", value: $0) }
            return components.url!
        }

        /// How many requests reached `path`.
        func hits(_ path: String) -> Int { authorizations[path]?.count ?? 0 }

        /// How many requests to `path` carried an `Authorization` header, right or wrong.
        func authorized(_ path: String) -> Int { authorizations[path]?.filter { !$0.isEmpty }.count ?? 0 }

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
            let lines = request.components(separatedBy: "\r\n")
            let target = lines.first?.split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init) ?? "/"
            let components = URLComponents(string: target)
            let path = components?.path ?? target
            let authorization =
                lines.dropFirst().first { $0.lowercased().hasPrefix("authorization:") }
                .map { $0.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces) } ?? ""
            authorizations[path, default: []].append(authorization)
            var status = "200 OK"
            var headers: [String] = []
            var body = ""
            let parts = path.split(separator: "/").map(String.init)
            switch parts.first {
            case "a" where parts.count == 3:
                if authorization == expected {
                    body = "<!doctype html><title>\(parts[2])</title><body><p>\(parts[2])</p></body>"
                } else {
                    status = "401 Unauthorized"
                    headers.append("WWW-Authenticate: Basic realm=\"\(Self.realm(parts[1]))\"")
                    body = "<!doctype html><title>denied \(parts[2])</title><body><p>denied</p></body>"
                }
            case "p" where parts.count == 2:
                let items = components?.queryItems ?? []
                let frames = items.filter { $0.name == "frame" }.compactMap(\.value).map { "<iframe src='\($0)'></iframe>" }
                let images = items.filter { $0.name == "image" }.compactMap(\.value).map { "<img src='\($0)'>" }
                body =
                    "<!doctype html><title>\(parts[1])</title><body><p>\(parts[1])</p>"
                    + (frames + images).joined() + "</body>"
            case "r", "d":
                status = "302 Found"
                headers.append("Location: \(components?.queryItems?.first { $0.name == "to" }?.value ?? "/")")
            default:
                status = "404 Not Found"
            }
            let data = Data(body.utf8)
            let head = (["HTTP/1.1 \(status)", "Content-Type: text/html; charset=utf-8", "Content-Length: \(data.count)",
                "Cache-Control: no-store", "Connection: close"] + headers).joined(separator: "\r\n") + "\r\n\r\n"
            let send = {
                connection.send(
                    content: Data(head.utf8) + data,
                    completion: .contentProcessed { [weak self] _ in
                        MainActor.assumeIsolated { self?.close(connection) }
                    })
            }
            if parts.first == "d" { DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: send) } else { send() }
        }
    }
#endif
