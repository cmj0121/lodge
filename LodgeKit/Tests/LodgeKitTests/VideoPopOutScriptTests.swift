import Foundation
import JavaScriptCore
import Testing

@testable import LodgeKit

@Suite struct VideoPopOutScriptTests {
    private typealias State = VideoPopOutScript.State
    private typealias Report = VideoPopOutScript.Report

    private static var playing: [String: Any] { [
        "doc": "d", "hasVideo": true, "isPlaying": true, "isMuted": false, "width": 640, "height": 360, "area": 9e4,
    ] }

    // MARK: Message bodies

    @Test func decodesAReportAndGone() {
        let state = State(hasVideo: true, isPlaying: true, isMuted: false, width: 640, height: 360)
        #expect(VideoPopOutScript.message(from: Self.playing) == .report(Report(document: "d", state: state, area: 9e4)))
        #expect(VideoPopOutScript.message(from: Self.playing as NSDictionary) != nil)
        #expect(VideoPopOutScript.message(from: ["doc": "d", "gone": true]) == .gone(document: "d"))
    }

    @Test func rejectsAnythingElse() {
        var extra = Self.playing
        extra["src"] = "x"
        var missing = Self.playing
        missing["isMuted"] = nil
        var negative = Self.playing
        negative["width"] = -1
        var wrong = Self.playing
        wrong["hasVideo"] = "yes"
        var noDocument = Self.playing
        noDocument["doc"] = ""
        for body in [extra, missing, negative, wrong, noDocument] {
            #expect(VideoPopOutScript.message(from: body) == nil)
        }
        #expect(VideoPopOutScript.message(from: ["doc": "d", "gone": false]) == nil)
        #expect(VideoPopOutScript.message(from: "state") == nil)
    }

    @Test func aHugeSizeReadsAsTheMaximum() {
        var huge = Self.playing
        huge["width"] = 2_147_483_647
        huge["height"] = 1e300
        guard case .report(let report) = VideoPopOutScript.message(from: huge) else {
            Issue.record("a huge size is not dropped")
            return
        }
        #expect(report.state.width == VideoPopOutScript.maximumSide)
        #expect(report.state.height == VideoPopOutScript.maximumSide)
    }

    // MARK: Ranking frames

    @Test func theBestFrameIsPlayingWithSoundThenLarger() {
        func report(_ doc: String, playing: Bool, muted: Bool, area: Double, has: Bool = true) -> Report {
            Report(
                document: doc, state: State(hasVideo: has, isPlaying: playing, isMuted: muted, width: 1, height: 1),
                area: area)
        }
        let paused = report("paused", playing: false, muted: false, area: 9e6)
        let muted = report("muted", playing: true, muted: true, area: 9e6)
        let small = report("small", playing: true, muted: false, area: 2e4)
        let large = report("large", playing: true, muted: false, area: 9e4)
        let none = report("none", playing: false, muted: false, area: 0, has: false)
        #expect(VideoPopOutScript.best([paused, muted, small, large, none]) == large)
        #expect(VideoPopOutScript.best([paused, muted]) == muted)
        #expect(VideoPopOutScript.best([none]) == nil)
        #expect(VideoPopOutScript.best([]) == nil)
    }

    // MARK: Probe

    @Test func aDocumentReportsOnceAtLoadAndThenOnChange() throws {
        let page = try VideoPage()
        page.run("runTimers();")
        #expect(page.reports.map(\.state) == [.none])
        page.run("video({ paused: false, width: 640, height: 360 }); fire('play'); fire('playing'); runTimers();")
        #expect(
            page.reports.last
                == Report(
                    document: "doc-1", state: State(hasVideo: true, isPlaying: true, isMuted: false, width: 640, height: 360),
                    area: 120_000))
        page.run("fire('volumechange'); runTimers();")
        #expect(page.reports.count == 2)
    }

    @Test func aSmallVideoIsNotThePagesVideo() throws {
        let page = try VideoPage()
        page.run("video({ paused: false, box: [100, 60] }); fire('play'); runTimers();")
        #expect(page.reports.map(\.state) == [.none])
    }

    @Test func mutedPausedAndSilentVideosReportSo() throws {
        let page = try VideoPage()
        page.run("var v = video({ paused: false, muted: true }); fire('play'); runTimers();")
        #expect(page.reports.last?.state == State(hasVideo: true, isPlaying: true, isMuted: true, width: 0, height: 0))
        page.run("v.muted = false; v.volume = 0; fire('volumechange'); runTimers();")
        #expect(page.reports.count == 1)
        page.run("v.volume = 1; v.paused = true; fire('pause'); runTimers();")
        #expect(page.reports.last?.state == State(hasVideo: true, isPlaying: false, isMuted: false, width: 0, height: 0))
    }

    @Test func theScriptClampsAHugeSize() throws {
        let page = try VideoPage()
        page.run("video({ paused: false, width: 2147483647, height: 900000 }); fire('play'); runTimers();")
        let message = try #require(page.posted.last)
        #expect(message["width"] as? Int == VideoPopOutScript.maximumSide)
        #expect(message["height"] as? Int == VideoPopOutScript.maximumSide)
    }

    @Test func aPlayingVideoWithSoundOutranksALargerMutedOne() throws {
        let page = try VideoPage()
        page.run(
            "video({ paused: false, muted: true, box: [1200, 700] }); video({ paused: false, width: 1, box: [300, 200] });"
                + "fire('play'); runTimers();")
        #expect(page.reports.last?.state.isMuted == false)
        #expect(page.reports.last?.state.width == 1)
    }

    @Test func pagehideSaysGoneAtOnce() throws {
        let page = try VideoPage()
        page.run("video({ paused: false }); fire('play'); runTimers(); fire('pagehide', {}, window);")
        #expect(VideoPopOutScript.message(from: page.posted.last ?? [:]) == .gone(document: "doc-1"))
        page.run("fire('pageshow', { persisted: true }, window); runTimers();")
        #expect(page.reports.last?.state.isPlaying == true)
    }

    @Test func withoutItsHandlerTheScriptDoesNothing() throws {
        let page = try VideoPage(withHandler: false)
        page.run("video({ paused: false }); fire('play'); runTimers();")
        #expect(page.posted.isEmpty)
        #expect(page.listenerCount == 0)
    }

    @Test func aSubframeReportsToTheAppAndPostsNothingToItsParent() throws {
        let page = try VideoPage(topFrame: false)
        page.run("var v = video({ paused: false }); fire('play'); runTimers(); v.paused = true; fire('pause'); runTimers();")
        #expect(page.reports.map(\.state.isPlaying) == [true, false])
        #expect(page.value("JSON.stringify(window.parent.received)") == "[]")
    }

    // MARK: Reports

    private static func entry(_ doc: String, playing: Bool = true, area: Double = 9e4, has: Bool = true)
        -> VideoPopOutScript.Message
    {
        .report(
            Report(
                document: doc, state: State(hasVideo: has, isPlaying: playing, isMuted: false, width: 1, height: 1),
                area: area))
    }

    @Test func aReportWithoutAVideoOrGoneRemovesItsDocument() {
        var reports = VideoPopOutScript.Reports<Int>()
        reports.apply(Self.entry("a"), from: 1)
        reports.apply(Self.entry("b"), from: 2)
        reports.apply(Self.entry("none", has: false), from: 3)
        #expect(reports.count == 2 && !reports.contains("none"))
        reports.apply(Self.entry("a", has: false), from: 1)
        reports.apply(.gone(document: "b"), from: 2)
        reports.apply(.hop(document: "c", token: String(repeating: "a", count: 32), origin: "https://x.example"), from: 4)
        #expect(reports.isEmpty && reports.best == nil)
    }

    @Test func theBestReportComesWithItsFrame() {
        var reports = VideoPopOutScript.Reports<Int>()
        reports.apply(Self.entry("paused", playing: false, area: 9e6), from: 1)
        reports.apply(Self.entry("playing"), from: 2)
        #expect(reports.best?.report.document == "playing" && reports.best?.frame == 2)
    }

    @Test func reportsPastTheCapacityDropTheLowestRankedThenTheOldest() {
        let capacity = VideoPopOutScript.Reports<Int>.capacity
        #expect(capacity == 32)
        var reports = VideoPopOutScript.Reports<Int>()
        reports.apply(Self.entry("small", area: 2e4), from: 0)
        reports.apply(Self.entry("paused", playing: false), from: 0)
        for n in 0..<(capacity - 2) { reports.apply(Self.entry("frame-\(n)"), from: n) }
        #expect(reports.count == capacity)
        reports.apply(Self.entry("new"), from: 99)
        #expect(reports.count == capacity && !reports.contains("paused") && reports.contains("new"))
        reports.apply(Self.entry("newer"), from: 100)
        #expect(reports.count == capacity && !reports.contains("small"))
        reports.apply(Self.entry("frame-0"), from: 0)
        reports.apply(Self.entry("newest"), from: 101)
        #expect(!reports.contains("frame-1") && reports.contains("frame-0") && reports.contains("newest"))
        for n in 0..<1000 { reports.apply(Self.entry("churn-\(n)", area: Double(n)), from: n) }
        #expect(reports.count == capacity && reports.contains("newest"))
    }

    @Test func reportsOfGoneFramesDrop() {
        var reports = VideoPopOutScript.Reports<Int>()
        reports.apply(Self.entry("a"), from: 1)
        reports.apply(Self.entry("b"), from: 2)
        reports.removeAll { $0 == 1 }
        #expect(!reports.contains("a") && reports.contains("b"))
    }

    // MARK: Hops

    @Test func eachHopIsFreshAndAcceptsOnlyItsTokenFromTheChild() {
        let hop = VideoPopOutScript.Hop(childOrigin: "https://child.example")
        let other = VideoPopOutScript.Hop(childOrigin: "https://child.example")
        #expect(hop.key != other.key && hop.token != other.token)
        #expect(hop.key.count == 12 && hop.key.allSatisfy { ("a"..."z").contains($0) })
        #expect(VideoPopOutScript.Hop.isToken(hop.token))
        #expect(hop.accepts(token: hop.token, from: "https://child.example"))
        #expect(!hop.accepts(token: other.token, from: "https://child.example"))
        #expect(!hop.accepts(token: hop.token, from: "https://parent.example"))
    }

    @Test func aFramesOriginIsSpelledAsMessageEventsDo() {
        #expect(VideoPopOutScript.Hop.origin(protocol: "https", host: "a.example", port: 0) == "https://a.example")
        #expect(VideoPopOutScript.Hop.origin(protocol: "http", host: "a.example", port: 8080) == "http://a.example:8080")
        #expect(VideoPopOutScript.Hop.origin(protocol: "http", host: "::1", port: 0) == "http://[::1]")
        #expect(VideoPopOutScript.Hop.origin(protocol: "file", host: "", port: 0) == "file://")
    }

    @Test func anOpaqueOriginIsNullAsASandboxedFramesMessagesSayIt() {
        #expect(VideoPopOutScript.Hop.origin(protocol: "", host: "", port: 0) == "null")
        #expect(VideoPopOutScript.Hop.origin(protocol: "https", host: "", port: 0) == "null")
        let hop = VideoPopOutScript.Hop(childOrigin: VideoPopOutScript.Hop.origin(protocol: "", host: "", port: 0))
        #expect(hop.accepts(token: hop.token, from: "null"))
    }

    @Test func aParentRelaysASandboxedChildsHopWithANullOrigin() throws {
        let page = try VideoPage()
        page.run("var f = iframe(); runTimers(); message({ \(Self.key): '\(Self.nonce)' }, f.contentWindow, 'null');")
        let relayed = VideoPopOutScript.message(from: page.posted.last ?? [:])
        #expect(relayed == .hop(document: "doc-1", token: Self.nonce, origin: "null"))
        guard case .hop(_, _, let origin) = relayed else { return }
        let hop = VideoPopOutScript.Hop(childOrigin: VideoPopOutScript.Hop.origin(protocol: "", host: "", port: 0))
        #expect(hop.accepts(token: hop.token, from: origin))
    }

    @Test func decodesAHopAndRejectsAMalformedOne() {
        let token = String(repeating: "0a", count: 16)
        #expect(
            VideoPopOutScript.message(from: ["doc": "d", "hop": token, "from": "https://c.example"])
                == .hop(document: "d", token: token, origin: "https://c.example"))
        for body: [String: Any] in [
            ["doc": "d", "hop": "short", "from": "https://c.example"],
            ["doc": "d", "hop": token.uppercased(), "from": "https://c.example"],
            ["doc": "d", "hop": token, "from": ""],
            ["doc": "d", "hop": token, "from": "https://c.example", "x": 1],
        ] {
            #expect(VideoPopOutScript.message(from: body) == nil)
        }
    }

    // MARK: Picture in Picture

    @Test func decodesAPresentationAndRejectsAMalformedOne() {
        #expect(
            VideoPopOutScript.message(from: ["doc": "d", "mode": "picture-in-picture", "paused": false])
                == .presentation(document: "d", mode: .pictureInPicture, isPaused: false))
        #expect(
            VideoPopOutScript.message(from: ["doc": "d", "mode": "inline", "paused": true] as NSDictionary)
                == .presentation(document: "d", mode: .inline, isPaused: true))
        #expect(
            VideoPopOutScript.message(from: ["doc": "d", "mode": "fullscreen", "paused": false])
                == .presentation(document: "d", mode: .fullscreen, isPaused: false))
        for body: [String: Any] in [
            ["doc": "d", "mode": "pip", "paused": false],
            ["doc": "d", "mode": "inline", "paused": 1],
            ["doc": "d", "mode": "inline", "paused": "no"],
            ["doc": "d", "mode": 1, "paused": false],
            ["doc": "d", "mode": "inline"],
            ["doc": "d", "mode": "inline", "paused": false, "x": 1],
            ["doc": "", "mode": "inline", "paused": false],
        ] {
            #expect(VideoPopOutScript.message(from: body) == nil)
        }
    }

    @Test func aPresentationChangesNoReports() {
        var reports = VideoPopOutScript.Reports<Int>()
        reports.apply(Self.entry("a"), from: 1)
        reports.apply(.presentation(document: "a", mode: .pictureInPicture, isPaused: false), from: 1)
        reports.apply(.presentation(document: "b", mode: .inline, isPaused: true), from: 2)
        #expect(reports.count == 1 && reports.contains("a") && !reports.contains("b"))
        #expect(reports.best?.frame == 1)
    }

    @Test func presentAsksTheFramesBestVideoWhenItSupportsTheMode() throws {
        let page = try VideoPage()
        page.run(
            """
            var asked = [];
            function presentable(v) {
              v.webkitSupportsPresentationMode = function (m) { return m !== 'fullscreen'; };
              v.webkitSetPresentationMode = function (m) { asked.push(m); this.webkitPresentationMode = m; };
              return v;
            }
            var small = presentable(video({ paused: false, box: [200, 200] }));
            var v = presentable(video({ paused: false }));
            """)
        #expect(page.call(VideoPopOutScript.present, ["mode": "picture-in-picture"]) == "true")
        #expect(page.value("JSON.stringify(asked)") == #"["picture-in-picture"]"#)
        #expect(page.value("String(v.webkitPresentationMode)") == "picture-in-picture")
        #expect(page.call(VideoPopOutScript.present, ["mode": "fullscreen"]) == "false")
        #expect(page.call(VideoPopOutScript.present, ["mode": "bogus"]) == "false")
        #expect(page.call(VideoPopOutScript.present, ["mode": "inline"]) == "true")
        #expect(page.value("JSON.stringify(asked)") == #"["picture-in-picture","inline"]"#)
    }

    @Test func presentIsFalseWithoutAVideoOrItsPresentationModes() throws {
        let page = try VideoPage()
        #expect(page.call(VideoPopOutScript.present, ["mode": "picture-in-picture"]) == "false")
        page.run("video({ paused: false });")
        #expect(page.call(VideoPopOutScript.present, ["mode": "picture-in-picture"]) == "false")
    }

    @Test func enteringPictureInPictureIsReportedAtOnceAndLeavingItWithPausedAfterItsDelay() throws {
        let page = try VideoPage()
        page.run("var v = video({ paused: false }); runTimers(); posted = [];")
        page.run("v.webkitPresentationMode = 'picture-in-picture'; fire('webkitpresentationmodechanged', { target: v });")
        #expect(
            page.posted.compactMap { VideoPopOutScript.message(from: $0) }
                == [.presentation(document: "doc-1", mode: .pictureInPicture, isPaused: false)])
        page.run(
            """
            posted = [];
            v.webkitPresentationMode = 'inline'; fire('webkitpresentationmodechanged', { target: v });
            """)
        #expect(page.posted.isEmpty)
        page.run("v.paused = true; runTimers();")
        #expect(
            page.posted.compactMap { VideoPopOutScript.message(from: $0) }
                == [.presentation(document: "doc-1", mode: .inline, isPaused: true)])
    }

    @Test func aModeChangeOfANonVideoOrAnUnknownModeIsNotReported() throws {
        let page = try VideoPage()
        page.run(
            """
            var v = video({ paused: false }); runTimers(); posted = [];
            fire('webkitpresentationmodechanged', { target: element({ localName: 'div' }) });
            v.webkitPresentationMode = 'weird'; fire('webkitpresentationmodechanged', { target: v });
            runTimers();
            """)
        #expect(page.posted.isEmpty)
    }

    // MARK: Fill

    private static let key = "abcdefghijkl"
    private static let nonce = "0123456789abcdef0123456789abcdef"
    private static let nextKey = "mnopqrstuvwx"
    private static let nextNonce = "fedcba9876543210fedcba9876543210"

    @Test func fillMarksTheTopFramesVideoAndUnfillPutsItBack() throws {
        let page = try VideoPage()
        page.run("var v = video({ paused: false }); fire('play'); runTimers();")
        #expect(page.call(VideoPopOutScript.fill, key: Self.key, nonce: Self.nonce) == "true")
        let attribute = try #require(page.value("Object.keys(v.attrs).join(',')"))
        #expect(attribute.range(of: #"^data-[a-z]{10}$"#, options: .regularExpression) != nil)
        #expect(page.value("String(document.adoptedStyleSheets.length)") == "1")
        #expect(
            page.value(
                "String(document.adoptedStyleSheets[0].text.indexOf('[\(attribute)]{position:fixed') === 0)") == "true")
        #expect(page.value("String(styles.length)") == "0")
        #expect(page.value("JSON.stringify(document.documentElement.attrs)") == "{}")
        #expect(page.value("JSON.stringify(window.parent.received)") == "[]")
        _ = page.call(VideoPopOutScript.unfill)
        #expect(page.value("JSON.stringify(v.attrs)") == "{}")
        #expect(page.value("String(document.adoptedStyleSheets.length)") == "0")
    }

    @Test func eachFillMarksWithANewAttribute() throws {
        let page = try VideoPage()
        page.run("var v = video({ paused: false }); fire('play'); runTimers();")
        _ = page.call(VideoPopOutScript.fill, key: Self.key, nonce: Self.nonce)
        let first = page.value("Object.keys(v.attrs).join(',')")
        _ = page.call(VideoPopOutScript.unfill)
        _ = page.call(VideoPopOutScript.fill, key: Self.key, nonce: Self.nonce)
        let second = page.value("Object.keys(v.attrs).join(',')")
        #expect(first != nil && second != nil && first != second)
    }

    @Test func aSubframeFillPostsTheHopToItsParentsOriginOnly() throws {
        let page = try VideoPage(topFrame: false)
        page.run("var v = video({ paused: false }); fire('play'); runTimers();")
        #expect(page.call(VideoPopOutScript.fill, key: Self.key, nonce: Self.nonce) == "true")
        #expect(page.value("JSON.stringify(window.parent.received)") == #"[{"\#(Self.key)":"\#(Self.nonce)"}]"#)
        #expect(page.value("JSON.stringify(window.parent.targets)") == #"["https://parent.example"]"#)
        let opaque = try VideoPage(topFrame: false, parentOrigin: "null")
        opaque.run("video({ paused: false }); fire('play'); runTimers();")
        _ = opaque.call(VideoPopOutScript.fill, key: Self.key, nonce: Self.nonce)
        #expect(opaque.value("JSON.stringify(window.parent.targets)") == #"["*"]"#)
    }

    @Test func aParentRelaysItsChildsHopAndPassesItOnOnce() throws {
        let page = try VideoPage(topFrame: false)
        page.run("var f = iframe(); var g = iframe(); runTimers();")
        page.run("message({ \(Self.key): '\(Self.nonce)' }, f.contentWindow, 'https://child.example');")
        #expect(
            VideoPopOutScript.message(from: page.posted.last ?? [:])
                == .hop(document: "doc-1", token: Self.nonce, origin: "https://child.example"))
        #expect(page.value("JSON.stringify(f.attrs)") == "{}")
        #expect(page.call(VideoPopOutScript.pass, token: Self.nonce, key: Self.nextKey, nonce: Self.nextNonce) == "true")
        #expect(page.value("String(Object.keys(f.attrs).length === 1 && Object.keys(g.attrs).length === 0)") == "true")
        #expect(
            page.value("JSON.stringify(window.parent.received)") == #"[{"\#(Self.nextKey)":"\#(Self.nextNonce)"}]"#)
        #expect(page.call(VideoPopOutScript.pass, token: Self.nonce, key: Self.nextKey, nonce: Self.nextNonce) == "false")
        #expect(page.value("window.parent.received.length") == "1")
    }

    @Test func aHopNotFromAChildOrMalformedIsIgnored() throws {
        let page = try VideoPage()
        page.run("var f = iframe(); runTimers();")
        let reports = page.posted.count
        page.run("message({ \(Self.key): '\(Self.nonce)' }, window, 'https://x.example');")
        page.run("message({ \(Self.key): '\(Self.nonce)' }, recorder(), 'https://x.example');")
        page.run("message({ lodgeVideoPopOut: '\(Self.nonce)' }, f.contentWindow, 'https://x.example');")
        page.run("message({ \(Self.key): 'not-a-token' }, f.contentWindow, 'https://x.example');")
        page.run(
            "message({ \(Self.key): '\(Self.nonce)', \(Self.nextKey): '\(Self.nonce)' }, f.contentWindow, 'https://x.example');")
        page.run("message('\(Self.nonce)', f.contentWindow, 'https://x.example');")
        #expect(page.posted.count == reports)
        #expect(page.call(VideoPopOutScript.pass, token: Self.nonce, key: Self.nextKey, nonce: Self.nextNonce) == "false")
        #expect(page.value("JSON.stringify(f.attrs)") == "{}")
    }

    @Test func unfillDropsPendingHops() throws {
        let page = try VideoPage()
        page.run("var f = iframe(); message({ \(Self.key): '\(Self.nonce)' }, f.contentWindow, 'https://c.example');")
        _ = page.call(VideoPopOutScript.unfill)
        #expect(page.call(VideoPopOutScript.pass, token: Self.nonce, key: Self.nextKey, nonce: Self.nextNonce) == "false")
    }

    @Test func nothingThePageCanSeeNamesLodge() throws {
        let page = try VideoPage(topFrame: false)
        page.run("var v = video({ paused: false }); var f = iframe(); fire('play'); runTimers();")
        _ = page.call(VideoPopOutScript.fill, key: Self.key, nonce: Self.nonce)
        page.run("message({ \(Self.key): '\(Self.nonce)' }, f.contentWindow, 'https://child.example');")
        _ = page.call(VideoPopOutScript.pass, token: Self.nonce, key: Self.nextKey, nonce: Self.nextNonce)
        let visible = try #require(
            page.value(
                """
                JSON.stringify([elements.concat([document.documentElement]).map(function (e) { return e.attrs; }),
                  document.adoptedStyleSheets.map(function (s) { return s.text; }), styles.length,
                  window.parent.received, window.parent.targets])
                """))
        #expect(page.value("window.parent.received.length") == "2")
        #expect(!visible.lowercased().contains("lodge"))
    }

    @Test func togglePlaysOrPausesOnlyTheFilledVideo() throws {
        let page = try VideoPage()
        page.run("var v = video({ paused: false }); fire('play'); runTimers();")
        #expect(page.call(VideoPopOutScript.togglePlayback) == "null")
        _ = page.call(VideoPopOutScript.fill, key: Self.key, nonce: Self.nonce)
        #expect(Playback.from(page.result(VideoPopOutScript.togglePlayback))?.isPaused == true)
        #expect(page.value("String(v.paused)") == "true")
        #expect(Playback.from(page.result(VideoPopOutScript.togglePlayback))?.isPaused == false)
        #expect(page.value("String(v.paused)") == "false")
        _ = page.call(VideoPopOutScript.unfill)
        #expect(page.call(VideoPopOutScript.togglePlayback) == "null")
    }

    // MARK: Controls

    private typealias Playback = VideoPopOutScript.Playback

    private static var controls: [(body: String, arguments: [String: Any])] { [
        (VideoPopOutScript.playback, [:]), (VideoPopOutScript.togglePlayback, [:]),
        (VideoPopOutScript.seek, ["by": 5.0]), (VideoPopOutScript.seekTo, ["time": 1.0]),
        (VideoPopOutScript.toggleMute, [:]), (VideoPopOutScript.next, [:]),
    ] }

    /// A top frame playing `v` (`props`), filled.
    private static func filledPage(_ props: String = "") throws -> VideoPage {
        let page = try VideoPage()
        page.run("var box = container(); var v = video({ paused: false, parent: box\(props) }); fire('play'); runTimers();")
        _ = page.call(VideoPopOutScript.fill, key: Self.key, nonce: Self.nonce)
        return page
    }

    @Test func everyControlReturnsPlaybackOrNullWithoutAFilledVideo() throws {
        let page = try VideoPage()
        page.run("var v = video({ paused: false }); fire('play'); runTimers();")
        for control in Self.controls { #expect(page.call(control.body, control.arguments) == "null") }
        #expect(page.value("String(v.paused + ',' + v.muted + ',' + v.currentTime)") == "false,false,0")
        let filled = try Self.filledPage()
        for control in Self.controls { #expect(Playback.from(filled.result(control.body, control.arguments)) != nil) }
        _ = filled.call(VideoPopOutScript.unfill)
        for control in Self.controls { #expect(filled.call(control.body, control.arguments) == "null") }
        let subframe = try VideoPage(topFrame: false)
        subframe.run("var f = iframe(); message({ \(Self.key): '\(Self.nonce)' }, f.contentWindow, 'https://c.example');")
        _ = subframe.call(VideoPopOutScript.pass, token: Self.nonce, key: Self.nextKey, nonce: Self.nextNonce)
        for control in Self.controls { #expect(subframe.call(control.body, control.arguments) == "null") }
    }

    @Test func playbackDescribesTheFilledVideo() throws {
        let page = try Self.filledPage(
            ", currentTime: 12.5, duration: 300, seekable: ranges([[0, 100], [150, 290]]), width: 1280, height: 720")
        #expect(
            Playback.from(page.result(VideoPopOutScript.playback))
                == Playback(
                    time: 12.5, duration: 300, seekable: 0...290, isPaused: false, isMuted: false, hasNext: false,
                    width: 1280, height: 720))
        page.run("v.duration = Infinity; v.seekable = ranges([]); v.muted = true; v.paused = true;")
        let live = try #require(Playback.from(page.result(VideoPopOutScript.playback)))
        #expect(live.duration == nil && live.seekable == nil && !live.canSeek && live.isPaused && live.isMuted)
    }

    @Test func seekClampsToTheSeekableRangeAndRejectsAHugeStep() throws {
        let page = try Self.filledPage(", currentTime: 50, duration: 300, seekable: ranges([[10, 100], [120, 200]])")
        #expect(Playback.from(page.result(VideoPopOutScript.seek, ["by": 5.0]))?.time == 55)
        #expect(Playback.from(page.result(VideoPopOutScript.seek, ["by": -60.0]))?.time == 10)
        #expect(Playback.from(page.result(VideoPopOutScript.seek, ["by": 3600.0]))?.time == 200)
        #expect(Playback.from(page.result(VideoPopOutScript.seek, ["by": -3601.0]))?.time == 200)
        page.run("v.currentTime = 50;")
        for by in ["NaN", "Infinity", "'5'"] {
            #expect(page.value("String((function (by) { \(VideoPopOutScript.seek) })(\(by)) !== null)") == "true")
        }
        #expect(page.value("String(v.currentTime)") == "50")
        #expect(Playback.from(page.result(VideoPopOutScript.seekTo, ["time": 150.0]))?.time == 150)
        #expect(Playback.from(page.result(VideoPopOutScript.seekTo, ["time": -5.0]))?.time == 10)
        #expect(Playback.from(page.result(VideoPopOutScript.seekTo, ["time": 1e9]))?.time == 200)
    }

    @Test func seekDoesNothingWhenNothingIsSeekable() throws {
        let page = try Self.filledPage(", currentTime: 7, seekable: ranges([])")
        #expect(Playback.from(page.result(VideoPopOutScript.seek, ["by": 5.0]))?.time == 7)
        #expect(Playback.from(page.result(VideoPopOutScript.seekTo, ["time": 0.0]))?.time == 7)
    }

    @Test func toggleMuteFlipsMutedOnly() throws {
        let page = try Self.filledPage(", volume: 0.4")
        page.run("v.paused = true;")
        #expect(Playback.from(page.result(VideoPopOutScript.toggleMute))?.isMuted == true)
        #expect(page.value("String([v.muted, v.volume, v.paused])") == "true,0.4,true")
        #expect(Playback.from(page.result(VideoPopOutScript.toggleMute))?.isMuted == false)
        #expect(page.value("String([v.muted, v.volume, v.paused])") == "false,0.4,true")
    }

    @Test func aReplacedVideoIsMarkedInItsPlace() throws {
        let page = try Self.filledPage(", currentTime: 30")
        let attribute = try #require(page.value("Object.keys(v.attrs).join(',')"))
        page.run("v.isConnected = false; var w = video({ paused: false, parent: box, currentTime: 2 }); fire('loadstart');")
        #expect(page.value("String(Object.keys(w.attrs).join(',') === '\(attribute)' && !('\(attribute)' in v.attrs))") == "true")
        #expect(Playback.from(page.result(VideoPopOutScript.playback))?.time == 2)
        page.run("w.isConnected = false; var x = video({ paused: false, parent: box, currentTime: 3 }); mutate();")
        #expect(page.value("String('\(attribute)' in x.attrs)") == "true")
        page.run("box.isConnected = false; x.isConnected = false; var y = video({ paused: false, currentTime: 4 });")
        #expect(Playback.from(page.result(VideoPopOutScript.togglePlayback))?.time == 4)
        #expect(page.value("String('\(attribute)' in y.attrs && y.paused)") == "true")
        page.run("y.isConnected = false;")
        #expect(page.call(VideoPopOutScript.playback) == "null")
        _ = page.call(VideoPopOutScript.unfill)
        #expect(page.value("String(observers.every(function (o) { return o.target === null; }))") == "true")
    }

    @Test func whileItsParentStaysTheReplacementIsAwaitedThereNotTakenElsewhere() throws {
        let page = try Self.filledPage()
        let attribute = try #require(page.value("Object.keys(v.attrs).join(',')"))
        page.run("v.isConnected = false; var preview = video({ paused: false, box: [1200, 700] }); fire('emptied'); mutate();")
        #expect(page.call(VideoPopOutScript.playback) == "null")
        #expect(page.value("String('\(attribute)' in preview.attrs)") == "false")
        page.run("var w = video({ paused: false, parent: box, currentTime: 6 }); mutate();")
        #expect(page.value("String('\(attribute)' in w.attrs && !('\(attribute)' in preview.attrs))") == "true")
        #expect(Playback.from(page.result(VideoPopOutScript.playback))?.time == 6)
    }

    @Test func nextClicksOnlyYouTubesShownEnabledButtonInTheTopFrame() throws {
        let page = try Self.filledPage()
        page.run("var b = nextButton();")
        #expect(Playback.from(page.result(VideoPopOutScript.next))?.hasNext == false)
        #expect(page.value("String(b.clicks)") == "0")
        for host in ["youtube.com", "www.youtube.com", "m.youtube.com"] {
            page.run("location.hostname = '\(host)'; b.clicks = 0;")
            #expect(Playback.from(page.result(VideoPopOutScript.playback))?.hasNext == true)
            #expect(Playback.from(page.result(VideoPopOutScript.next)) != nil)
            #expect(page.value("String(b.clicks)") == "1")
        }
        for setup in [
            "location.hostname = 'notyoutube.com';", "location.hostname = 'youtube.com.evil.example';",
            "b.attrs['aria-disabled'] = 'true';", "b.rects = 0;", "b.isConnected = false;",
        ] {
            page.run("location.hostname = 'www.youtube.com'; b = nextButton(); \(setup)")
            #expect(Playback.from(page.result(VideoPopOutScript.next))?.hasNext == false)
            #expect(page.value("String(b.clicks)") == "0")
        }
        let subframe = try VideoPage(topFrame: false)
        subframe.run("location.hostname = 'www.youtube.com'; var b = nextButton(); var v = video({ paused: false });")
        _ = subframe.call(VideoPopOutScript.fill, key: Self.key, nonce: Self.nonce)
        #expect(Playback.from(subframe.result(VideoPopOutScript.next))?.hasNext == false)
        #expect(subframe.value("String(b.clicks)") == "0")
    }

    // MARK: Playback

    private static var playback: [String: Any] { [
        "time": 12.5, "duration": 300, "start": 0, "end": 290, "paused": false, "muted": true, "next": true,
        "width": 1280, "height": 720,
    ] }

    @Test func decodesPlayback() {
        #expect(
            Playback.from(Self.playback)
                == Playback(
                    time: 12.5, duration: 300, seekable: 0...290, isPaused: false, isMuted: true, hasNext: true,
                    width: 1280, height: 720))
        #expect(Playback.from(Self.playback as NSDictionary)?.canSeek == true)
        var none = Self.playback
        none["duration"] = -1
        none["start"] = -1
        none["end"] = -1
        let live = Playback.from(none)
        #expect(live?.duration == nil && live?.seekable == nil && live?.canSeek == false)
        var backwards = Self.playback
        backwards["start"] = 300
        #expect(Playback.from(backwards)?.seekable == nil)
        var negative = Self.playback
        negative["time"] = -3
        #expect(Playback.from(negative)?.time == 0)
        var huge = Self.playback
        huge["width"] = 1e12
        #expect(Playback.from(huge)?.width == VideoPopOutScript.maximumSide)
    }

    @Test func clampsHugeTimesToMaximumSeconds() {
        let limit = Playback.maximumSeconds
        var huge = Self.playback
        huge["time"] = 1e300
        huge["duration"] = 1e300
        huge["start"] = 1e299
        huge["end"] = Double.greatestFiniteMagnitude
        #expect(
            Playback.from(huge)
                == Playback(
                    time: limit, duration: limit, seekable: limit...limit, isPaused: false, isMuted: true,
                    hasNext: true, width: 1280, height: 720))
        var past = Self.playback
        past["end"] = 1e12
        #expect(Playback.from(past)?.seekable == 0...limit)
    }

    @Test func rejectsMalformedPlayback() {
        var bodies: [[String: Any]] = []
        var extra = Self.playback
        extra["src"] = "x"
        bodies.append(extra)
        for key in Self.playback.keys {
            var missing = Self.playback
            missing[key] = nil
            bodies.append(missing)
        }
        for (key, value) in [
            ("time", Double.nan), ("time", .infinity), ("duration", .infinity), ("end", -.infinity),
            ("duration", -2), ("start", -0.5), ("width", -1),
        ] as [(String, Double)] {
            var bad = Self.playback
            bad[key] = value
            bodies.append(bad)
        }
        var wrongType = Self.playback
        wrongType["paused"] = "no"
        bodies.append(wrongType)
        var boolNumber = Self.playback
        boolNumber["time"] = true
        bodies.append(boolNumber)
        for body in bodies { #expect(Playback.from(body) == nil) }
        #expect(Playback.from(nil) == nil)
        #expect(Playback.from(NSNull()) == nil)
        #expect(Playback.from("playback") == nil)
    }

    @Test func theFillHidesEverythingButTheMarkedElementAndFreesItsAncestors() {
        let css = VideoPopOutScript.css("[m]")
        #expect(css.contains("html:has([m]) *:not([m]){visibility:hidden!important}"))
        for property in ["transform", "translate", "rotate", "scale", "filter", "contain", "clip-path", "mask"] {
            #expect(css.contains(":has([m]){") && css.contains("\(property):"))
        }
        let ancestors = css.components(separatedBy: ":has([m]){")[1].components(separatedBy: "}")[0]
        for rule in ["overflow:visible", "opacity:1", "isolation:auto", "content-visibility:visible", "container-type:normal"] {
            #expect(ancestors.contains(rule))
        }
    }

    @Test func fillWithNoVideoDoesNothing() throws {
        let page = try VideoPage()
        #expect(page.call(VideoPopOutScript.fill, key: Self.key, nonce: Self.nonce) == "false")
        #expect(page.value("String(document.adoptedStyleSheets.length + styles.length)") == "0")
    }
}

/// A page stand-in for running `VideoPopOutScript` in JavaScriptCore: a `document` of plain-object videos and iframes
/// with attributes and adopted stylesheets, captured listeners, a `lodgeVideo` handler recording what is posted,
/// numbered document ids, and windows recording the messages posted to them and their target origins.
private final class VideoPage {
    private let context: JSContext

    /// `topFrame` false: the page is a subframe, its parent of `parentOrigin`, recording what it is posted.
    init(withHandler: Bool = true, topFrame: Bool = true, parentOrigin: String = "https://parent.example") throws {
        context = try #require(JSContext())
        context.exceptionHandler = { _, exception in
            Issue.record("JavaScript threw: \(exception?.toString() ?? "?")")
        }
        context.evaluateScript(
            """
            var posted = [];
            var listeners = [];
            var timers = [];
            var styles = [];
            var elements = [];
            var observers = [];
            var ids = 0;
            var crypto = {
              randomUUID: function () { ids += 1; return 'doc-' + ids; },
              getRandomValues: function (a) { for (var i = 0; i < a.length; i++) { a[i] = Math.floor(Math.random() * 256); } return a; },
            };
            function CSSStyleSheet() { this.text = ''; }
            CSSStyleSheet.prototype.replaceSync = function (t) { this.text = t; };
            function setTimeout(fn) { timers.push(fn); }
            function runTimers() { var run = timers; timers = []; run.forEach(function (fn) { fn(); }); }
            function element(props) {
              return Object.assign({ attrs: {}, isConnected: true, parentElement: null,
                setAttribute: function (k, v) { this.attrs[k] = v; },
                getAttribute: function (k) { return k in this.attrs ? this.attrs[k] : null; },
                removeAttribute: function (k) { delete this.attrs[k]; } }, props || {});
            }
            function connected(e) { return e.isConnected && (!e.parentElement || e.parentElement.isConnected); }
            function container() {
              var box = element({ localName: 'div' });
              box.querySelectorAll = function (selector) {
                return selector === 'video'
                  ? elements.filter(function (e) { return e.localName === 'video' && e.parentElement === box && connected(e); })
                  : [];
              };
              return box;
            }
            function ranges(list) {
              return { length: list.length, start: function (i) { return list[i][0]; }, end: function (i) { return list[i][1]; } };
            }
            function MutationObserver(fn) { this.fn = fn; this.target = null; observers.push(this); }
            MutationObserver.prototype.observe = function (target, options) { this.target = target; this.options = options; };
            MutationObserver.prototype.disconnect = function () { this.target = null; };
            function mutate() { observers.forEach(function (o) { if (o.target) { o.fn([]); } }); }
            var button = null;
            function nextButton() {
              button = element({ localName: 'a', clicks: 0, rects: 1,
                getClientRects: function () { return { length: this.rects }; },
                click: function () { this.clicks += 1; } });
              return button;
            }
            function recorder() {
              return { received: [], targets: [], postMessage: function (m, target) {
                this.received.push(JSON.parse(JSON.stringify(m)));
                this.targets.push(target);
              } };
            }
            var window = recorder();
            window.addEventListener = function (type, fn) { listeners.push({ type: type, fn: fn, on: window }); };
            \(topFrame ? "window.top = window; window.parent = window; var location = { hostname: 'example.com', ancestorOrigins: [] };" : "window.top = {}; window.parent = recorder(); var location = { hostname: 'example.com', ancestorOrigins: ['\(parentOrigin)'] };")
            \(withHandler ? "window.webkit = { messageHandlers: { lodgeVideo: { postMessage: function (m) { posted.push(m); } } } };" : "")
            var document = {
              documentElement: element(),
              adoptedStyleSheets: [],
              head: { appendChild: function (s) { styles.push(s); } },
              addEventListener: function (type, fn) { listeners.push({ type: type, fn: fn, on: document }); },
              createElement: function () {
                return { textContent: '', removed: false, remove: function () { this.removed = true; } };
              },
              querySelector: function (selector) {
                return selector === '.ytp-next-button' && button && button.isConnected ? button : null;
              },
              querySelectorAll: function (selector) {
                if (selector === 'video') {
                  return elements.filter(function (e) { return e.localName === 'video' && connected(e); });
                }
                if (selector === 'iframe, frame') {
                  return elements.filter(function (e) { return e.localName === 'iframe'; });
                }
                return [];
              },
            };
            function video(props) {
              var box = (props && props.box) || [400, 300];
              var el = element(Object.assign({ localName: 'video', paused: true, ended: false, muted: false, volume: 1,
                currentTime: 0, duration: NaN, seekable: ranges([]), parentElement: (props && props.parent) || null,
                videoWidth: (props && props.width) || 0, videoHeight: (props && props.height) || 0,
                getBoundingClientRect: function () { return { width: box[0], height: box[1] }; },
                play: function () { this.paused = false; return Promise.resolve(); },
                pause: function () { this.paused = true; } }, props || {}));
              elements.push(el);
              return el;
            }
            function iframe() {
              var el = element({ localName: 'iframe', contentWindow: recorder() });
              elements.push(el);
              return el;
            }
            function fire(type, props, on) {
              var e = Object.assign({ type: type }, props || {});
              listeners.filter(function (l) { return l.type === type && (!on || l.on === on); })
                .forEach(function (l) { l.fn(e); });
            }
            function message(data, source, origin) {
              fire('message', { data: data, source: source, origin: origin || 'null' }, window);
            }
            """)
        context.evaluateScript(VideoPopOutScript.source)
    }

    func run(_ script: String) { context.evaluateScript(script) }

    func value(_ script: String) -> String? { context.evaluateScript(script).toString() }

    /// Runs `body`, a `callAsyncJavaScript` function body, with its `token`, `key` and `nonce` arguments; its result
    /// as a string.
    func call(_ body: String, token: String = "", key: String = "", nonce: String = "") -> String? {
        let literal = String(decoding: try! JSONSerialization.data(withJSONObject: [token, key, nonce]), as: UTF8.self)
        return value("String((function (token, key, nonce) { \(body) }).apply(null, \(literal)))")
    }

    /// Runs `body` with `arguments` as its named parameters; its result as Foundation objects (null: `NSNull`).
    func result(_ body: String, _ arguments: [String: Any] = [:]) -> Any? {
        context.evaluateScript(Self.invocation(body, arguments)).toObject()
    }

    /// `result` as a string.
    func call(_ body: String, _ arguments: [String: Any]) -> String? {
        value("String(\(Self.invocation(body, arguments)))")
    }

    /// An expression calling `body` as a function of `arguments`' names, applied to their values.
    private static func invocation(_ body: String, _ arguments: [String: Any]) -> String {
        let names = arguments.keys.sorted()
        let literal = String(
            decoding: try! JSONSerialization.data(withJSONObject: names.map { arguments[$0]! }), as: UTF8.self)
        return "(function (\(names.joined(separator: ", "))) { \(body) }).apply(null, \(literal))"
    }

    var posted: [[String: Any]] {
        (context.objectForKeyedSubscript("posted").toArray() ?? []).compactMap { $0 as? [String: Any] }
    }

    var reports: [VideoPopOutScript.Report] {
        posted.compactMap {
            if case .report(let report) = VideoPopOutScript.message(from: $0) { return report }
            return nil
        }
    }

    var listenerCount: Int { Int(context.evaluateScript("listeners.length").toInt32()) }
}
