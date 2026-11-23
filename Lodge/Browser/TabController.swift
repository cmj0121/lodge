import AppKit
import LodgeKit
import WebKit

/// Navigation and UI delegate of one tab's web view; mirrors the view's state into the tab model.
@MainActor
final class TabController: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let tab: TabID
    private weak var model: BrowserModel?
    private var observations: [NSKeyValueObservation] = []
    private var dialogGate = DialogGate()
    /// Ends the dialog or file panel sheet this tab has open, answering it with its default.
    private var dismissSheet: (() -> Void)?
    private let favicons: FaviconLoader
    private var history: HistoryEventFilter
    /// The load that restored the tab; its commit is not a visit.
    var restoreNavigation: WKNavigation?
    /// The next main-frame commit is a restore from saved interaction state, so it is not a visit.
    var expectsRestoreCommit = false
    /// Each recent navigation action's gesture and site, for the download its response may become.
    private var gestures = NavigationGestures()
    /// The next main-frame action is a load the browser started (`browserWillLoad()`).
    private var nextLoadIsBrowserInitiated = false
    /// Whether the tab is on its link's own load, whose icon the link keeps (D2).
    private var ownLoad = LinkOwnLoad()
    /// A main-frame form submission is loading; it holds the page (`PageWork`) until that load ends.
    private var isFormPostLoading = false
    /// The scroll-restoring script (`PlaceScript`), until the load it was added for ends.
    private var scrollRestore: WKUserScript?
    /// The main frame's response was let through and its commit is still to come: that commit is a new document whose
    /// reads start afresh. A back/forward cache restore commits without a response, so its reads were cleared at its
    /// navigation action instead, before its relay re-reports them on `pageshow`, whichever of that and the commit
    /// comes first.
    private var commitsNewDocument = false
    /// The view whose user scripts this controller alone installs (`installScripts(seed:site:)`).
    private weak var webView: WKWebView?
    /// The registrable domain of the view's main frame that its scripts are seeded for (D1); nil without one.
    private(set) var topSite: String?
    /// A sign-in challenge waiting for its answer (D1).
    private struct Challenge {
        let id = UUID()
        let challenge: URLAuthenticationChallenge
        let prompt: AuthPrompt
        /// It came while the main frame's navigation was provisional, from that navigation's origin.
        let isForNavigation: Bool
        let continuation: CheckedContinuation<(URLSession.AuthChallengeDisposition, URLCredential?), Never>
    }
    /// Sign-in challenges waiting for their sheet, first come first: only the head is ever shown (D1).
    private var challenges: [Challenge] = []
    /// The challenge taken off the queue for the sheet on screen, or about to be.
    private var signIn: Challenge?
    /// The tab is going: every challenge has been answered with a cancel, and any later one is too.
    private var isTornDown = false
    /// The origin the main frame is loading or showing, as provisional start, server redirect and commit report it;
    /// a challenge from it prompts even on another site (D3).
    private var navigationOrigin: Origin?
    /// The main frame's navigation has started and neither committed nor ended: a challenge from `navigationOrigin`
    /// is for it, not for the committed page.
    private var isNavigating = false
    /// The user cancelled a sheet since the last commit: challenges not for the main frame's navigation are rejected
    /// with no sheet until the next one.
    private var refusesOtherChallenges = false
    /// At most this many challenges wait behind the sheet; more are rejected.
    private static let challengeLimit = 8
    /// The registrable domain of the committed page; a challenge from another site gets no sheet (D3).
    private var pageSite: String?
    #if DEBUG
        /// Layout self-checks: how many `lodge:` navigations and popups every tab has refused.
        static var lodgeRefusals = 0
        /// Layout self-checks: answers a sign-in challenge where its sheet would be shown, nil meaning Cancel.
        static var selfCheckAnswer: ((AuthPrompt) -> (user: String, password: String)?)?
        /// Layout self-checks: how many sign-in challenges every tab has answered or cancelled.
        static var selfCheckResumes = 0
        /// Layout self-checks: how many prompting challenges every tab has rejected with no sheet, after a Cancel or
        /// with the queue full.
        static var selfCheckRefusals = 0
    #endif

    /// Installs the view's scripts seeded for `topSite`, the site its first document is expected at (D7).
    init(tab: TabID, webView: LodgeWebView, model: BrowserModel, faviconSession: URLSession, topSite: String?) {
        self.tab = tab
        self.model = model
        self.webView = webView
        self.topSite = topSite
        history = HistoryEventFilter(tab: tab)
        favicons = FaviconLoader(session: faviconSession) { [weak model] image in model?.setFavicon(image, for: tab) }
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.didMoveToWindow = { [weak self] in self?.pumpChallenges() }
        observations = [
            webView.observe(\.title) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.model?.update(self.tab) { $0.title = view.title ?? "" }
                    self.sendHistory(
                        self.history.titleChanged(view.title ?? "", url: view.url, store: self.store))
                }
            },
            webView.observe(\.url, options: .initial) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let url = view.url, !LodgePage.isLodge(url), !self.isWarningPlainHTTP {
                        self.model?.update(self.tab) { $0.url = url }
                    }
                    self.updateSecurity(of: view)
                    self.sendHistory(
                        self.history.urlChanged(
                            view.url, title: view.title ?? "", store: self.store, isLoading: view.isLoading))
                }
            },
            webView.observe(\.isLoading) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.model?.update(self.tab) { $0.isLoading = view.isLoading }
                    guard !view.isLoading else { return }
                    self.sendHistory(self.history.loadFinished(view.url, title: view.title ?? "", store: self.store))
                }
            },
            mirror(webView, \.canGoBack) { $0.canGoBack = $1.canGoBack },
            mirror(webView, \.canGoForward) { $0.canGoForward = $1.canGoForward },
            webView.observe(\.estimatedProgress) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.model?.setProgress(view.estimatedProgress, for: self.tab)
                }
            },
            webView.observe(\.hasOnlySecureContent, options: .initial) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.updateSecurity(of: view) }
            },
            holdState(webView, \.cameraCaptureState),
            holdState(webView, \.microphoneCaptureState),
            holdState(webView, \.fullscreenState),
        ]
        reinstallScripts()
    }

    /// Tells the model when a state that keeps a background tab's view alive changes.
    private func holdState<Value>(_ webView: WKWebView, _ keyPath: KeyPath<WKWebView, Value>) -> NSKeyValueObservation {
        webView.observe(keyPath) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model?.holdStateChanged(self.tab)
            }
        }
    }

    /// Reclassifies the page's security from the view's current URL and content; the plain-http warning keeps its own.
    private func updateSecurity(of view: WKWebView) {
        guard !isWarningPlainHTTP else { return }
        model?.setSecurity(SiteSecurity(url: view.url, hasOnlySecureContent: view.hasOnlySecureContent), for: tab)
    }

    /// The tab shows the plain-http warning (D8): the address and security are the warned page's, not the view's.
    private var isWarningPlainHTTP: Bool { model?.plainHTTPWarnings[tab] != nil }

    /// The main frame has committed a document since the view was made, so `webView.url` is a page it shows.
    private var hasCommitted = false
    /// The address the view was built to load (a restored, resting or new tab with an address); nil for a blank tab.
    var wakeURL: URL?

    /// The warning has gone (Go Back): the address and security are the view's page again; a view that never showed
    /// one keeps the address it was woken at, a blank tab none.
    func showCurrentPage() {
        guard let webView else { return }
        let url = hasCommitted ? webView.url : wakeURL
        if url.map(LodgePage.isLodge) != true { model?.update(tab) { $0.url = url } }
        updateSecurity(of: webView)
    }

    /// The tab's store; nil once the tab is gone.
    private var store: StoreRef? { model?.tabs[tab]?.store }

    private func sendHistory(_ event: HistoryRecorder.Event?) {
        if let event { model?.historyRecorder?.send(event) }
    }

    /// Copies a web view property into the tab whenever it changes; `apply` reads the current
    /// value off the view, so a property that turns nil is copied too.
    private func mirror<Value>(
        _ webView: WKWebView, _ keyPath: KeyPath<WKWebView, Value>,
        _ apply: @escaping @MainActor @Sendable (inout BrowserTab, WKWebView) -> Void
    ) -> NSKeyValueObservation {
        webView.observe(keyPath) { [weak self] view, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model?.update(self.tab) { apply(&$0, view) }
            }
        }
    }

    /// Called just before the browser loads a URL into the tab (address bar, bookmark, history, restore): that
    /// navigation's downloads count against the URL's site, not the page it replaces.
    func browserWillLoad() {
        nextLoadIsBrowserInitiated = true
    }

    /// The browser is about to load the tab's link's own URL (D2): the page it lands on, redirects included, gives the
    /// link its icon, until the tab navigates anywhere else.
    func linkWillLoad() {
        ownLoad.start()
    }

    /// The tab's page is its link's own, so the icon it shows is the one the link keeps.
    var isOnLinkLoad: Bool { ownLoad.isOn }

    /// The tab wakes from a record (D5): the next load of `url` scrolls its main frame back to `y`, from a user script
    /// removed once that load ends.
    func restoreScroll(to y: Double, at url: URL) {
        scrollRestore = WKUserScript(
            source: PlaceScript.restoreScroll(to: y, at: url), injectionTime: .atDocumentEnd, forMainFrameOnly: true,
            in: .world(name: PlaceScript.worldName))
        reinstallScripts()
    }

    /// The load the scroll-restoring script was added for has ended: it goes, every other script stays.
    private func endScrollRestore() {
        guard scrollRestore != nil else { return }
        scrollRestore = nil
        reinstallScripts()
    }

    /// The main frame is at, or about to show, a document at `url`: when that is another site than `topSite`, the
    /// scripts are seeded for it (D1). The response decision calls it, and so do a commit (a back/forward cache
    /// restore has no response) and a load that fails or stops before committing (the old page stays).
    private func seedMainFrame(at url: URL?) {
        let site = FingerprintSite.of(url, inheriting: topSite)
        guard site != topSite else { return }
        topSite = site
        reinstallScripts()
    }

    /// Installs the scripts again for `topSite` with the tab's current fingerprint settings, as after its site's
    /// exception changes; documents loaded from then on see the change.
    func reinstallScripts() {
        installScripts(seed: model?.fingerprintSettings(for: tab)?.pageSeed(for: topSite), site: topSite)
    }

    /// The one place the view's user scripts are set (D7), since removing any drops every world's: the fingerprint
    /// patch seeded with `seed` for `site` in the page world (none for nil: the site is excepted or has no registrable
    /// domain; a document whose top frame is on another site gets a throwaway seed), the fingerprint relay (D4), the
    /// work script (D3) and the video probe (#36) in their own worlds in every frame, and the scroll-restoring script
    /// while one is pending.
    func installScripts(seed: String?, site: String?) {
        guard let controller = webView?.configuration.userContentController else { return }
        controller.removeAllUserScripts()
        if let seed, let site {
            controller.addUserScript(
                WKUserScript(
                    source: FingerprintScript.pageSource(
                        seed: seed, site: site, exactHost: RegistrableDomain.isWholeHost(site)),
                    injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        controller.addUserScript(
            WKUserScript(
                source: FingerprintScript.relaySource, injectionTime: .atDocumentStart, forMainFrameOnly: false,
                in: .world(name: FingerprintScript.worldName)))
        controller.addUserScript(
            WKUserScript(
                source: PageWorkScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: false,
                in: .world(name: PageWorkScript.worldName)))
        controller.addUserScript(
            WKUserScript(
                source: VideoPopOutScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: false,
                in: .world(name: VideoPopOutScript.worldName)))
        if let scrollRestore { controller.addUserScript(scrollRestore) }
    }

    /// Called when another tab is selected: ends this tab's open sheet; a sign-in sheet's challenge waits again.
    func didDeselect() {
        dismissSheet?()
    }

    /// Called when the tab is shown: the sign-in challenge at the head of the queue gets its sheet.
    func didSelect() {
        pumpChallenges()
    }

    /// A sign-in challenge is waiting, on screen or queued: it holds the tab's view (D1).
    var isWaitingForSignIn: Bool { signIn != nil || !challenges.isEmpty }

    /// The tab goes (released, closed): every challenge is cancelled, and so is any that arrives later (D1).
    func cancelChallenges() {
        isTornDown = true
        cancelQueuedChallenges()
    }

    /// A new main-frame load, a failed one, a stop or a crashed page: the waiting challenges are cancelled and the
    /// sign-in sheet ends; later challenges still prompt (D1).
    func cancelQueuedChallenges() {
        let waiting = (signIn.map { [$0] } ?? []) + challenges
        guard !waiting.isEmpty else { return }
        let isOnScreen = signIn != nil
        changeChallenges {
            signIn = nil
            challenges = []
        }
        for challenge in waiting { resume(challenge, with: (.cancelAuthenticationChallenge, nil)) }
        if isOnScreen { dismissSheet?() }
    }

    /// The model stopped the tab's load: no delegate call follows, so the waiting challenges are cancelled and the
    /// main frame's target is the committed page again.
    func didStop() {
        cancelQueuedChallenges()
        navigationOrigin = webView?.url.map(Origin.init(url:))
        isNavigating = false
        ownLoad.loadEnded()
    }

    /// Runs `change` on the challenges, telling the model when whether one holds the tab changes.
    private func changeChallenges(_ change: () -> Void) {
        let wasWaiting = isWaitingForSignIn
        change()
        if isWaitingForSignIn != wasWaiting { model?.holdStateChanged(tab) }
    }

    /// Shows the head of the queue while this tab is on screen with no sheet open (D1).
    private func pumpChallenges() {
        guard !isTornDown, signIn == nil, !challenges.isEmpty, let webView, let window = visibleWindow(of: webView)
        else { return }
        let head = challenges.removeFirst()
        signIn = head
        Task { await showSignIn(head, in: window) }
    }

    /// The sign-in sheet for `item` (D3). Ended by `didDeselect()`, the challenge goes back to the head of the
    /// queue; ended by a cancel, it was already answered.
    private func showSignIn(_ item: Challenge, in window: NSWindow) async {
        guard signIn?.id == item.id else { return }
        guard model?.placement?.isShown(tab) == true, webView?.window === window else {
            requeue(item)
            return
        }
        #if DEBUG
            if let selfCheckAnswer = Self.selfCheckAnswer {
                let credentials = selfCheckAnswer(item.prompt)
                // The answer stands in for the sheet: a tab switched away from meanwhile waits again, as a sheet
                // ended by `didDeselect()` does.
                guard signIn?.id == item.id else { return }
                if model?.placement?.isShown(tab) == true { answer(item, with: credentials) } else { requeue(item) }
                pumpChallenges()
                return
            }
        #endif
        let (alert, name, password) = Self.signInAlert(for: item.prompt)
        let dismiss = {
            if window.attachedSheet === alert.window { window.endSheet(alert.window, returnCode: .abort) }
        }
        _ = await whileSelected(dismiss: dismiss) {
            let response = await alert.beginSheetModal(for: window)
            guard signIn?.id == item.id else { return response }
            if response == .abort {
                requeue(item)
            } else {
                answer(item, with: response == .alertFirstButtonReturn ? (name.stringValue, password.stringValue) : nil)
            }
            return response
        }
    }

    /// The sheet for `item` ended unanswered: it waits at the head of the queue again.
    private func requeue(_ item: Challenge) {
        signIn = nil
        challenges.insert(item, at: 0)
    }

    /// Answers the challenge on screen: a name and password are used for this session, and for every queued
    /// challenge of the same protection space; nil (Cancel) rejects the space for them all, so the server's own page
    /// shows, and rejects every queued challenge not for the main frame's navigation, as it does those arriving
    /// before the next commit.
    private func answer(_ item: Challenge, with credentials: (user: String, password: String)?) {
        let reply: (URLSession.AuthChallengeDisposition, URLCredential?) =
            credentials.map {
                (.useCredential, URLCredential(user: $0.user, password: $0.password, persistence: .forSession))
            } ?? (.rejectProtectionSpace, nil)
        let space = item.challenge.protectionSpace
        let sameSpace = challenges.filter { $0.challenge.protectionSpace == space }
        let refused =
            credentials == nil
            ? challenges.filter { $0.challenge.protectionSpace != space && !$0.isForNavigation } : []
        if credentials == nil { refusesOtherChallenges = true }
        changeChallenges {
            signIn = nil
            challenges.removeAll { $0.challenge.protectionSpace == space }
            challenges.removeAll { refused.map(\.id).contains($0.id) }
        }
        for challenge in [item] + sameSpace + refused { resume(challenge, with: reply) }
    }

    private func resume(
        _ challenge: Challenge, with reply: (URLSession.AuthChallengeDisposition, URLCredential?)
    ) {
        #if DEBUG
            Self.selfCheckResumes += 1
        #endif
        challenge.continuation.resume(returning: reply)
    }

    /// The sign-in alert for `prompt`, with its name and password fields: the title names the site, the body the
    /// whole host.
    static func signInAlert(for prompt: AuthPrompt) -> (NSAlert, NSTextField, NSSecureTextField) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Sign in to \(prompt.site)")
        var lines: [String] = []
        if prompt.failed { lines.append(String(localized: "The name or password was wrong.")) }
        if let realm = prompt.realm {
            lines.append(String(localized: "\(prompt.shownHost) asks for a name and password for “\(realm)”."))
        } else {
            lines.append(String(localized: "\(prompt.shownHost) asks for a name and password."))
        }
        if prompt.isPlainHTTP { lines.append(String(localized: "The name and password are sent without encryption.")) }
        alert.informativeText = lines.joined(separator: "\n\n")
        let name = NSTextField(string: prompt.proposedUser ?? "")
        name.placeholderString = String(localized: "User name")
        let password = NSSecureTextField(string: "")
        password.placeholderString = String(localized: "Password")
        let fields = NSStackView(views: [name, password])
        fields.orientation = .vertical
        fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 240, height: 52)
        name.widthAnchor.constraint(equalToConstant: 240).isActive = true
        password.widthAnchor.constraint(equalToConstant: 240).isActive = true
        alert.accessoryView = fields
        alert.addButton(withTitle: String(localized: "Sign In"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = prompt.proposedUser == nil ? name : password
        return (alert, name, password)
    }

    // MARK: WKNavigationDelegate

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let browserInitiated = isMainFrame && nextLoadIsBrowserInitiated
        if isMainFrame { nextLoadIsBrowserInitiated = false }
        if navigationAction.targetFrame?.isMainFrame == true {
            // A load the browser starts has no type either, but is never a redirect.
            ownLoad.navigationAction(isOther: navigationAction.navigationType == .other && !browserInitiated)
        }
        if LodgePage.isLodge(navigationAction.request.url) {
            #if DEBUG
                Self.lodgeRefusals += 1
            #endif
            return (.cancel, preferences)
        }
        gestures.record(
            Self.gestureRecord(of: navigationAction, browserInitiated: browserInitiated),
            url: navigationAction.request.url, isMainFrame: isMainFrame)
        // A sent form in any frame puts its body in the view's history (S0), so its place on disk is a record only.
        if navigationAction.targetFrame != nil,
            [.formSubmitted, .formResubmitted].contains(navigationAction.navigationType)
        {
            model?.didSendForm(tab)
        }
        let opensNewTab =
            navigationAction.navigationType == .linkActivated && navigationAction.modifierFlags.contains(.command)
            && navigationAction.request.url.map(NewTabPolicy.allows) == true
        // A plain-http page in this view's own main frame, however it was reached and a download link's included, waits
        // for the warning (D8); a load aimed at a new window has no target frame and is decided in the popup's own
        // view, as is a Cmd-click in its new tab.
        if !opensNewTab, navigationAction.targetFrame?.isMainFrame == true, let url = navigationAction.request.url,
            let model
        {
            if model.warnsPlainHTTP(url, in: tab) {
                warnPlainHTTP(url, in: webView, backForward: navigationAction.navigationType == .backForward)
                return (.cancel, preferences)
            }
            model.endPlainHTTPWarning(tab, loading: url)
        }
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        if opensNewTab, let url = navigationAction.request.url {
            model?.open(url: url, from: tab)
            return (.cancel, preferences)
        }
        // A form aimed at a new window (`target=_blank`) has no target frame here: it loads in the popup, not this tab.
        if navigationAction.targetFrame?.isMainFrame == true,
            [.formSubmitted, .formResubmitted].contains(navigationAction.navigationType)
        {
            setFormPostLoading(true)
        }
        if isMainFrame, navigationAction.navigationType == .backForward { model?.resetFingerprintReads(tab) }
        return (.allow, preferences)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")
        let action = gestures.record(
            for: navigationResponse.response.url, isMainFrame: navigationResponse.isForMainFrame)
        let download = DownloadPolicy.shouldDownload(
            mimeCanShow: navigationResponse.canShowMIMEType, contentDisposition: disposition,
            isMainFrame: navigationResponse.isForMainFrame, userInitiated: action?.userInitiated ?? false)
        if download { return .download }
        // The main frame's final response, once redirects are done, is let through: its document gets its site's
        // seed (D7).
        if navigationResponse.isForMainFrame {
            seedMainFrame(at: navigationResponse.response.url)
            commitsNewDocument = true
        }
        return .allow
    }

    /// Stops for the warning: nothing reaches the server. A restore that was to commit no longer will. The keys leave
    /// the hidden page, so typing does not go on in it behind the warning. A load stopped at a server redirect fails
    /// its provisional navigation, which puts the sign-in state back on the committed page; one stopped before it
    /// started leaves that state as it was.
    /// A back/forward load is marked so, for Continue to go to its history entry.
    private func warnPlainHTTP(_ url: URL, in webView: WKWebView, backForward: Bool) {
        expectsRestoreCommit = false
        model?.showPlainHTTPWarning(url, for: tab, backForward: backForward)
        if let window = webView.window, let responder = window.firstResponder as? NSView,
            responder.isDescendant(of: webView)
        {
            window.makeFirstResponder(nil)
        }
    }

    /// A link click (an `<a download>` included) or a form submission counts as user-initiated: WebKit has no public
    /// user-gesture flag, so the navigation type is the closest signal (see `DownloadGate`). The site is the source
    /// frame's origin, else (or for a `browserInitiated` load) the target URL's.
    private static func gestureRecord(
        of action: WKNavigationAction, browserInitiated: Bool = false
    ) -> NavigationGestures.Record {
        let source = action.sourceFrame.securityOrigin
        return NavigationGestures.Record(
            userInitiated: action.navigationType == .linkActivated || action.navigationType == .formSubmitted,
            site: DownloadGate.site(
                source: Origin(scheme: source.protocol, host: source.host, port: source.port),
                target: action.request.url, browserInitiated: browserInitiated))
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        let isMainFrame =
            navigationAction.sourceFrame.isMainFrame && (navigationAction.targetFrame?.isMainFrame ?? true)
        startDownload(download, action: Self.gestureRecord(of: navigationAction), isMainFrame: isMainFrame)
    }

    /// The response's action is looked up by URL and frame; without one it counts as not user-initiated and
    /// without a site.
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        let isMainFrame = navigationResponse.isForMainFrame
        let action = gestures.record(for: navigationResponse.response.url, isMainFrame: isMainFrame)
        startDownload(
            download, action: action ?? NavigationGestures.Record(userInitiated: false, site: nil),
            isMainFrame: isMainFrame)
    }

    /// Hands the download to the manager with the tab's store and its action's gesture and site; without a store
    /// it does not run.
    private func startDownload(_ download: WKDownload, action: NavigationGestures.Record, isMainFrame: Bool) {
        guard let manager = model?.downloads, let store else {
            download.cancel(nil)
            return
        }
        manager.start(
            download, store: store, site: action.site, userInitiated: action.userInitiated, isMainFrame: isMainFrame)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        cancelQueuedChallenges()
        navigationOrigin = webView.url.map(Origin.init(url:))
        isNavigating = true
        model?.update(tab) { $0.hasCrashed = false }
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        navigationOrigin = webView.url.map(Origin.init(url:))
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        let isRestore = (navigation != nil && navigation === restoreNavigation) || expectsRestoreCommit
        if isRestore { restoreNavigation = nil }
        expectsRestoreCommit = false
        hasCommitted = true
        pageSite = webView.url.flatMap(RegistrableDomain.of)
        navigationOrigin = webView.url.map(Origin.init(url:))
        isNavigating = false
        refusesOtherChallenges = false
        if let url = webView.url {
            dialogGate.commit(origin: Origin(url: url))
            sendHistory(history.committed(url, title: webView.title ?? "", store: store, isRestore: isRestore))
        }
        seedMainFrame(at: webView.url)
        favicons.pageCommitted(webView.url)
        model?.mainFrameLeavesDocument(tab)
        model?.resetWork(tab)
        if commitsNewDocument { model?.resetFingerprintReads(tab) }
        commitsNewDocument = false
        model?.update(tab) { $0.hasCrashed = false }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        favicons.pageFinished(in: webView)
        ownLoad.loadEnded()
        setFormPostLoading(false)
        endScrollRestore()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        ownLoad.loadEnded()
        setFormPostLoading(false)
        endScrollRestore()
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) {
        cancelQueuedChallenges()
        navigationOrigin = webView.url.map(Origin.init(url:))
        isNavigating = false
        seedMainFrame(at: webView.url)
        commitsNewDocument = false
        ownLoad.loadEnded()
        setFormPostLoading(false)
        endScrollRestore()
    }

    /// Tells the model when a main-frame form submission starts or stops loading.
    private func setFormPostLoading(_ loading: Bool) {
        guard loading != isFormPostLoading else { return }
        isFormPostLoading = loading
        model?.formPost(inFlight: loading, in: tab)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        cancelQueuedChallenges()
        ownLoad.loadEnded()
        isNavigating = false
        setFormPostLoading(false)
        model?.resetWork(tab)
        model?.resetFingerprintReads(tab)
        model?.update(tab) {
            $0.hasCrashed = true
            $0.isLoading = false
        }
    }

    // MARK: WKUIDelegate

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard !LodgePage.isLodge(navigationAction.request.url) else {
            #if DEBUG
                Self.lodgeRefusals += 1
            #endif
            return nil
        }
        // A popup's first document is at its own site, or its opener's when it opens blank (D7).
        return model?.openPopup(
            from: tab, configuration: configuration,
            topSite: FingerprintSite.of(navigationAction.request.url, inheriting: topSite),
            sendsForm: [.formSubmitted, .formResubmitted].contains(navigationAction.navigationType))
    }

    func webViewDidClose(_ webView: WKWebView) {
        model?.close(tab)
    }

    /// Basic, Digest and NTLM challenges wait for the sign-in sheet (D1); a challenge from another site than the
    /// page's that is not for the main frame's own load gets none and is rejected (D3), as is one not for that load
    /// after a Cancel until the next commit, and one beyond `challengeLimit` waiting; the main frame's navigation
    /// always waits for its sheet. Others are handled as WebKit would.
    func webView(
        _ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard AuthPrompt.prompts(for: challenge.protectionSpace.authenticationMethod) else {
            return (.performDefaultHandling, nil)
        }
        guard !isTornDown else { return (.cancelAuthenticationChallenge, nil) }
        guard
            let prompt = AuthPrompt(
                space: challenge.protectionSpace, previousFailureCount: challenge.previousFailureCount,
                proposedUser: challenge.proposedCredential?.user, pageSite: pageSite, navigation: navigationOrigin)
        else { return (.rejectProtectionSpace, nil) }
        let isForNavigation = isNavigating && prompt.isNavigationTarget
        guard isForNavigation || (!refusesOtherChallenges && challenges.count < Self.challengeLimit) else {
            #if DEBUG
                Self.selfCheckRefusals += 1
            #endif
            return (.rejectProtectionSpace, nil)
        }
        return await withCheckedContinuation { continuation in
            changeChallenges {
                challenges.append(
                    Challenge(
                        challenge: challenge, prompt: prompt, isForNavigation: isForNavigation,
                        continuation: continuation))
            }
            pumpChallenges()
        }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async {
        await presentDialog(message: message, from: frame, in: webView, buttons: [])
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        await presentDialog(message: message, from: frame, in: webView, buttons: [String(localized: "OK"), String(localized: "Cancel")])
            == .alertFirstButtonReturn
    }

    func webView(
        _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        guard let window = visibleWindow(of: webView) else { return nil }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        let response = await whileSelected(dismiss: { panel.cancel(nil) }) { await panel.beginSheetModal(for: window) }
        return response == .OK ? panel.urls : nil
    }

    /// The window to hang a sheet on, only while this tab is the one on screen and has no sheet open or about to open.
    private func visibleWindow(of webView: WKWebView) -> NSWindow? {
        guard dismissSheet == nil, signIn == nil, model?.placement?.isShown(tab) == true else { return nil }
        return webView.window
    }

    /// Shows a page's dialog as a sheet; a background tab's dialog, or one past the page's rate
    /// limit, is answered at once with `nil`, which callers read as dismissed (confirm → false).
    @discardableResult
    private func presentDialog(
        message: String, from frame: WKFrameInfo, in webView: WKWebView, buttons: [String]
    ) async -> NSApplication.ModalResponse? {
        guard let window = visibleWindow(of: webView), dialogGate.admit() else { return nil }
        let origin = frame.securityOrigin
        let alert = NSAlert()
        alert.messageText = DialogGate.title(for: Origin(scheme: origin.protocol, host: origin.host, port: origin.port))
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Block further dialogs from this page")
        let response = await whileSelected(dismiss: { window.endSheet(alert.window, returnCode: .abort) }) {
            await alert.beginSheetModal(for: window)
        }
        if alert.suppressionButton?.state == .on { dialogGate.block() }
        return response
    }

    /// Runs a sheet that `didDeselect()` ends through `dismiss`; once it ends, a waiting sign-in challenge may show.
    private func whileSelected(
        dismiss: @escaping () -> Void, _ sheet: () async -> NSApplication.ModalResponse
    ) async -> NSApplication.ModalResponse {
        dismissSheet = dismiss
        defer {
            dismissSheet = nil
            pumpChallenges()
        }
        return await sheet()
    }
}
