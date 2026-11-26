import AVFoundation
import LodgeKit
import UIKit
import WebKit
import os

/// Keeps a tab's playing video in Picture in Picture while the tab is away, the iPhone and iPad stand-in for the Mac's
/// mini player (#36). Every frame's `VideoPopOutScript` reports reach `receive`, kept per tab as on the Mac.
///
/// Leaving a tab whose best video plays with sound (`VideoPopOut.shouldPopOut`, with the setting on) first parks its
/// web view in a view behind all of its window's content, so WebKit never sees it leave a window (AVKit will not start
/// PiP for a video whose view has gone), then asks that video's frame to `present` it in Picture in Picture. The view
/// stays parked while the tab is held; its `WebViewContainer` takes it back when the tab is shown again, and the video
/// returns inline. WebKit not reporting PiP within `timeout` (or the frame refusing) gives the tab up at once, so a
/// refused PiP never delays the switch.
///
/// Leaving PiP while the tab is away follows `VideoPopOut.exit`: still playing, the user asked for it back
/// (`onRestore`); paused, they closed it, and the tab stays where it is. One tab at a time: a newer one ends the last.
///
/// The audio session is made `.playback` and active just before each PiP request, never at launch (that would ignore
/// the silent switch and stop Music), and inactive again once no tab is held.
@MainActor
final class PictureInPicture {
    private static let logger = Logger(subsystem: "dev.lodge", category: "pip")
    private static let world = WKContentWorld.world(name: VideoPopOutScript.worldName)
    /// How long WebKit has to report Picture in Picture after a request.
    static let timeout: Duration = .seconds(1)

    private let pool: WebViewPool
    private let isEnabled: () -> Bool
    /// The tab in or entering Picture in Picture; at most one.
    private(set) var tab: TabID?
    /// Shows the tab's workspace and selects it: the user asked for its video back.
    var onRestore: (TabID) -> Void = { _ in }

    private var reports: [TabID: VideoPopOutScript.Reports<WKFrameInfo>] = [:]
    /// The held tab is off screen, its view parked; false while it is held on screen (the app leaving, D4).
    private var isAway = false
    /// WebKit reported the held tab's video in Picture in Picture; until then a mode leaving it is an earlier hold's.
    private var isPresenting = false
    /// This hold's PiP request has been made (its `present` returned true); a PiP report before that is an earlier
    /// hold's.
    private var isRequested = false
    /// A PiP report came during this hold before its request was made; the request's answer then counts it.
    private var sawPictureInPicture = false
    /// The frame the held tab's video was asked into PiP in, which inline goes back to.
    private var frame: WKFrameInfo?
    /// Counts holds, so a late answer or timeout of an earlier hold of the same tab is not taken for this one's.
    private var generation = 0
    private var isAudioActive = false
    private var deadline: Task<Void, Never>?
    /// Behind all of a window's content, full size and not hidden, so a view in it stays in that window.
    private lazy var parking: UIView = {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return view
    }()

    /// `isEnabled` reads the `VideoPopOut.settingKey` setting.
    init(pool: WebViewPool, isEnabled: @escaping () -> Bool) {
        self.pool = pool
        self.isEnabled = isEnabled
    }

    /// A frame of `tab` reported its document's video or a presentation change; a fill hop means nothing here.
    func receive(_ message: VideoPopOutScript.Message, frame: WKFrameInfo, from tab: TabID) {
        guard case .presentation(_, let mode, let isPaused) = message else {
            reports[tab, default: .init()].apply(message, from: frame)
            if reports[tab]?.isEmpty == true { reports[tab] = nil }
            return
        }
        Self.logger.info(
            "mode \(mode.rawValue, privacy: .public) paused=\(isPaused) held=\(tab == self.tab) requested=\(self.isRequested) presenting=\(self.isPresenting) away=\(self.isAway)"
        )
        guard tab == self.tab else { return }
        if mode == .pictureInPicture {
            guard isRequested else {
                sawPictureInPicture = true
                return
            }
            if !isPresenting { didPresent() }
            return
        }
        guard isPresenting else { return }
        switch VideoPopOut.exit(mode: mode, isPaused: isPaused, isTabShown: !isAway) {
        case .restore:
            // The view stays parked until the container shown with the tab takes it back.
            letGo()
            onRestore(tab)
        case .close:
            unpark(tab)
            letGo()
        case .none:
            if !isAway { letGo() }
        }
    }

    /// The tab is about to leave the screen; call before the selection or the workspace changes, while its view is
    /// still in its window.
    func leaving(_ tab: TabID) {
        let view = pool.existingView(for: tab)
        Self.logger.info("leaving: view=\(view != nil) window=\(view?.window != nil) held=\(tab == self.tab)")
        guard let view, let window = view.window else { return }
        if tab == self.tab {
            park(view, in: window)
            isAway = true
            return
        }
        guard let best = poppable(tab, view) else { return }
        if let earlier = self.tab { end(earlier) }
        park(view, in: window)
        hold(tab, isAway: true, view: view, frame: best)
    }

    /// The tab is on screen again: its video returns inline, and the tab is no longer held (its container has taken
    /// its view back).
    func shown(_ tab: TabID) {
        guard tab == self.tab else { return }
        present(.inline, tab)
        letGo()
    }

    /// The scene goes from `.active` to `.inactive` (D4): the shown tab's video playing with sound goes into Picture
    /// in Picture where it is, its view staying in its container. No timeout: nothing is parked or switched, and a
    /// suspended app could take a late PiP report for a refusal; `appActive` ends the hold either way.
    func appResigning(shown: TabID?) {
        let view = shown.flatMap(pool.existingView(for:))
        Self.logger.info(
            "appResigning: shown=\(shown != nil) held=\(shown != nil && shown == self.tab) view=\(view != nil) window=\(view?.window != nil)"
        )
        guard let shown, shown != tab, let view = pool.existingView(for: shown), view.window != nil,
            let best = poppable(shown, view)
        else { return }
        if let earlier = tab { end(earlier) }
        hold(shown, isAway: false, view: view, frame: best)
    }

    /// The scene is `.active` again (D4): the held tab, still shown, takes its video back inline.
    func appActive(shown: TabID?) {
        Self.logger.info("appActive: held=\(self.tab != nil) shownHeld=\(shown != nil && shown == self.tab) away=\(self.isAway)")
        guard let tab, tab == shown, !isAway else { return }
        present(.inline, tab)
        letGo()
    }

    /// The tab closes: its video returns inline, its view leaves the parking, and its reports go.
    func closing(_ tab: TabID) {
        if tab == self.tab { end(tab) }
        reports[tab] = nil
    }

    /// Whether the tab is held: its view must not be released (that would end Picture in Picture).
    func isHolding(_ tab: TabID) -> Bool { tab == self.tab }

    // MARK: - Holding

    /// The frame of the tab's best video when it should pop out, dropping reports from an earlier view of the tab.
    private func poppable(_ tab: TabID, _ view: WKWebView) -> WKFrameInfo? {
        reports[tab]?.removeAll { $0.webView !== view }
        guard let best = reports[tab]?.best else {
            Self.logger.info("poppable: no video report for the tab")
            return nil
        }
        let state = best.report.state
        let enabled = isEnabled()
        let pops = VideoPopOut.shouldPopOut(
            isPlaying: state.isPlaying, isMuted: state.isMuted, hasVideo: state.hasVideo, isEnabled: enabled)
        Self.logger.info(
            "poppable: playing=\(state.isPlaying) muted=\(state.isMuted) video=\(state.hasVideo) enabled=\(enabled) mainFrame=\(best.frame.isMainFrame) host=\(best.frame.securityOrigin.host, privacy: .public) -> \(pops)"
        )
        guard pops else { return nil }
        return best.frame
    }

    private func hold(_ tab: TabID, isAway: Bool, view: WKWebView, frame: WKFrameInfo) {
        generation += 1
        let generation = generation
        self.tab = tab
        self.isAway = isAway
        self.frame = frame
        isRequested = false
        sawPictureInPicture = false
        isPresenting = false
        Self.logger.info("hold \(generation): away=\(isAway) inWindow=\(view.window != nil) parked=\(view.superview === self.parking)")
        activateAudio()
        run(.pictureInPicture, in: frame, of: view, generation: generation)
        guard isAway else { return }
        deadline = Task { [weak self] in
            try? await Task.sleep(for: Self.timeout)
            guard !Task.isCancelled else { return }
            self?.refused(generation)
        }
    }

    /// WebKit reported this hold's video in Picture in Picture: the timeout no longer applies.
    private func didPresent() {
        isPresenting = true
        deadline?.cancel()
        deadline = nil
    }

    /// The hold `generation`'s PiP request was refused or never reported.
    private func refused(_ generation: Int) {
        guard let tab, generation == self.generation, !isPresenting else { return }
        Self.logger.info(
            "Picture in Picture did not start (requested=\(self.isRequested) away=\(self.isAway)); the tab is let go")
        unpark(tab)
        letGo()
    }

    /// Ends the held tab's Picture in Picture: its video inline, its view out of the parking, the tab let go.
    private func end(_ tab: TabID) {
        present(.inline, tab)
        unpark(tab)
        letGo()
    }

    private func letGo() {
        deadline?.cancel()
        deadline = nil
        tab = nil
        frame = nil
        isRequested = false
        sawPictureInPicture = false
        isAway = false
        isPresenting = false
        deactivateAudio()
    }

    /// Asks the held tab's video, in the frame it went into PiP from, into `mode`.
    private func present(_ mode: VideoPopOutScript.PresentationMode, _ tab: TabID) {
        guard tab == self.tab, let view = pool.existingView(for: tab), let frame else { return }
        run(mode, in: frame, of: view, generation: generation)
    }

    /// Asks `frame`'s video into `mode`; a PiP request of hold `generation` the frame cannot make lets that hold go at
    /// once.
    private func run(
        _ mode: VideoPopOutScript.PresentationMode, in frame: WKFrameInfo, of view: WKWebView, generation: Int
    ) {
        view.callAsyncJavaScript(
            VideoPopOutScript.present, arguments: ["mode": mode.rawValue], in: frame, in: Self.world
        ) { [weak self] result in
            MainActor.assumeIsolated {
                switch result {
                case .success(let value):
                    Self.logger.info(
                        "present \(mode.rawValue, privacy: .public) -> \(String(describing: value), privacy: .public) (generation \(generation))"
                    )
                case .failure(let error):
                    Self.logger.error(
                        "present \(mode.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
                guard let self, mode == .pictureInPicture else { return }
                guard (try? result.get()) as? Bool == true else { return self.refused(generation) }
                guard generation == self.generation, self.tab != nil else { return }
                self.isRequested = true
                if self.sawPictureInPicture, !self.isPresenting { self.didPresent() }
            }
        }
    }

    // MARK: - Parking

    /// Moves `view` into the parking, at index 0 of `window`, before SwiftUI takes its container off screen. A view
    /// left there by a tab that was let go leaves first.
    private func park(_ view: WKWebView, in window: UIWindow) {
        if parking.superview !== window {
            parking.frame = window.bounds
            window.insertSubview(parking, at: 0)
        }
        for stale in parking.subviews where stale !== view { stale.removeFromSuperview() }
        guard view.superview !== parking else { return }
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = parking.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        parking.addSubview(view)
    }

    private func unpark(_ tab: TabID) {
        guard let view = pool.existingView(for: tab), view.superview === parking else { return }
        view.removeFromSuperview()
    }

    // MARK: - Audio

    private func activateAudio() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
            isAudioActive = true
            Self.logger.info("audio active (.playback)")
        } catch {
            Self.logger.error("Cannot activate audio for Picture in Picture: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deactivateAudio() {
        guard isAudioActive else { return }
        isAudioActive = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Self.logger.info("Audio stays active after Picture in Picture: \(error.localizedDescription, privacy: .public)")
        }
    }
}
