import CoreGraphics
import Testing

@testable import LodgeKit

@Suite struct VideoPopOutTests {
    @Test func popsOutOnlyAnEnabledPlayingUnmutedVideo() {
        for isPlaying in [false, true] {
            for isMuted in [false, true] {
                for hasVideo in [false, true] {
                    for isEnabled in [false, true] {
                        let expected = isPlaying && !isMuted && hasVideo && isEnabled
                        #expect(VideoPopOut.shouldPopOut(isPlaying: isPlaying, isMuted: isMuted, hasVideo: hasVideo,
                                                         isEnabled: isEnabled) == expected)
                    }
                }
            }
        }
    }

    @Test func returnsOnlyWhenTheTabIsShownWithItsVideoInTheMiniPlayer() {
        #expect(VideoPopOut.shouldReturn(isTabShown: true, isInMiniPlayer: true))
        #expect(!VideoPopOut.shouldReturn(isTabShown: true, isInMiniPlayer: false))
        #expect(!VideoPopOut.shouldReturn(isTabShown: false, isInMiniPlayer: true))
        #expect(!VideoPopOut.shouldReturn(isTabShown: false, isInMiniPlayer: false))
    }

    @Test func leavingPictureInPictureWhileTheTabIsAwayRestoresAPlayingVideoAndClosesAPausedOne() {
        #expect(VideoPopOut.exit(mode: .inline, isPaused: false, isTabShown: false) == .restore)
        #expect(VideoPopOut.exit(mode: .fullscreen, isPaused: false, isTabShown: false) == .restore)
        #expect(VideoPopOut.exit(mode: .inline, isPaused: true, isTabShown: false) == .close)
    }

    @Test func stillInPictureInPictureOrOnScreenIsNoExit() {
        for isPaused in [false, true] {
            #expect(VideoPopOut.exit(mode: .pictureInPicture, isPaused: isPaused, isTabShown: false) == PiPExit.none)
            #expect(VideoPopOut.exit(mode: .pictureInPicture, isPaused: isPaused, isTabShown: true) == PiPExit.none)
            #expect(VideoPopOut.exit(mode: .inline, isPaused: isPaused, isTabShown: true) == PiPExit.none)
        }
    }

    @Test func isOnByDefaultUnderItsSettingKey() {
        #expect(VideoPopOut.settingKey == "popOutPlayingVideo")
        #expect(VideoPopOut.enabledByDefault)
    }
}

@Suite struct MiniPlayerFrameTests {
    private typealias Frame = MiniPlayerFrame
    private static let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private static let start = CGRect(x: 400, y: 300, width: 480, height: 270)
    private static let aspect = CGSize(width: 16, height: 9)

    private func resized(_ edges: Frame.Edges, _ dx: CGFloat, _ dy: CGFloat) -> CGRect {
        Frame.resized(
            Self.start, edges: edges, by: CGVector(dx: dx, dy: dy), aspect: Self.aspect, minWidth: 240,
            within: Self.screen)
    }

    @Test func aPointGrabsTheEdgesWithinTheMarginAndNoneInTheMiddle() {
        let size = CGSize(width: 480, height: 270)
        #expect(Frame.edges(at: CGPoint(x: 240, y: 135), in: size, margin: 6).isEmpty)
        #expect(Frame.edges(at: CGPoint(x: 2, y: 135), in: size, margin: 6) == .left)
        #expect(Frame.edges(at: CGPoint(x: 478, y: 135), in: size, margin: 6) == .right)
        #expect(Frame.edges(at: CGPoint(x: 240, y: 268), in: size, margin: 6) == .top)
        #expect(Frame.edges(at: CGPoint(x: 1, y: 1), in: size, margin: 6) == [.left, .bottom])
    }

    @Test func dragsKeepTheAspectRatioAndTheOppositeEdges() {
        let right = resized(.right, 160, 0)
        #expect(right == CGRect(x: 400, y: 210, width: 640, height: 360))
        #expect(right.maxY == Self.start.maxY)
        let left = resized(.left, -160, 0)
        #expect(left.maxX == Self.start.maxX && left.width == 640 && left.maxY == Self.start.maxY)
        let top = resized(.top, 0, 90)
        #expect(top == CGRect(x: 400, y: 300, width: 640, height: 360))
        let corner = resized([.left, .bottom], -16, -90)
        #expect(corner.maxX == Self.start.maxX && corner.maxY == Self.start.maxY && corner.width == 640)
        for frame in [right, left, top, corner] { #expect(abs(frame.width / frame.height - 16.0 / 9) < 0.0001) }
    }

    @Test func aDragStopsAtTheSmallestWidthAndTheScreen() {
        #expect(resized(.right, -1000, 0).width == 240)
        let huge = resized(.right, 5000, 0)
        #expect(huge.width == 1600 && huge.height == 900)
        #expect(resized([], 50, 50) == Self.start)
    }

    @Test func aVideosShapeIsKeptWithinFourToOne() {
        #expect(Frame.aspect(of: CGSize(width: 1280, height: 720)) == CGSize(width: 1280, height: 720))
        #expect(Frame.aspect(of: CGSize(width: 1, height: 4)) == CGSize(width: 1, height: 4))
        #expect(Frame.aspect(of: CGSize(width: 1, height: 65536)) == CGSize(width: 1, height: Frame.maximumAspect))
        #expect(Frame.aspect(of: CGSize(width: 65536, height: 1)) == CGSize(width: Frame.maximumAspect, height: 1))
        #expect(Frame.aspect(of: CGSize(width: 0, height: 720)) == nil)
        #expect(Frame.aspect(of: CGSize(width: 1280, height: 0)) == nil)
    }

    @Test func aPanelsSizeKeepsItsWidthUnlessTheScreenIsTooSmall() {
        #expect(
            Frame.sized(width: 480, aspect: Self.aspect, minHeight: 135, within: Self.screen)
                == CGSize(width: 480, height: 270))
        #expect(
            Frame.sized(width: 480, aspect: CGSize(width: 4, height: 1), minHeight: 135, within: Self.screen)
                == CGSize(width: 480, height: 135))
        let tall = Frame.sized(width: 480, aspect: CGSize(width: 1, height: 4), minHeight: 135, within: Self.screen)
        #expect(tall == CGSize(width: 250, height: 1000))
        let narrow = CGRect(x: 0, y: 0, width: 300, height: 1000)
        #expect(
            Frame.sized(width: 480, aspect: Self.aspect, minHeight: 135, within: narrow)
                == CGSize(width: 300, height: 169))
    }

    @Test func theScreenWinsOverThePanelsMinimum() {
        let small = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let tall = Frame.sized(width: 480, aspect: CGSize(width: 1, height: 4), minHeight: 135, within: small)
        #expect(tall == CGSize(width: 200, height: 800))
        #expect(tall.width < 240 && tall.width <= small.width && tall.height <= small.height)
        let tiny = CGRect(x: 0, y: 0, width: 200, height: 100)
        let wide = Frame.sized(width: 480, aspect: CGSize(width: 4, height: 1), minHeight: 135, within: tiny)
        #expect(wide.width <= tiny.width && wide.height <= tiny.height && wide.height < 135)
    }

    @Test func aDragNeverPushesThePanelOffTheScreen() {
        let screen = Self.screen
        let nearLeft = CGRect(x: 10, y: 600, width: 480, height: 270)
        let left = Frame.resized(
            nearLeft, edges: .left, by: CGVector(dx: -300, dy: 0), aspect: Self.aspect, minWidth: 240, within: screen)
        #expect(left.minX == screen.minX && left.width == 780)
        let nearBottom = CGRect(x: 100, y: 20, width: 480, height: 270)
        let bottom = Frame.resized(
            nearBottom, edges: .bottom, by: CGVector(dx: 0, dy: -180), aspect: Self.aspect, minWidth: 240,
            within: screen)
        #expect(bottom.minY == screen.minY && bottom.height == 450)
        let nearTop = CGRect(x: 100, y: 700, width: 480, height: 270)
        let top = Frame.resized(
            nearTop, edges: .top, by: CGVector(dx: 0, dy: 180), aspect: Self.aspect, minWidth: 240, within: screen)
        #expect(top.maxY == screen.maxY && top.height == 450)
        let nearRight = CGRect(x: 1100, y: 100, width: 480, height: 270)
        let right = Frame.resized(
            nearRight, edges: .right, by: CGVector(dx: 300, dy: 0), aspect: Self.aspect, minWidth: 240, within: screen)
        #expect(right.maxX == screen.maxX && screen.contains(right))
    }
}
