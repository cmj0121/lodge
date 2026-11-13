import CoreGraphics
import Foundation
import Testing

@testable import LodgeKit

@Suite struct WindowFrameTests {
    private typealias Frame = SessionSnapshot.WindowFrame

    private let main = Frame(x: 0, y: 0, width: 1440, height: 900)
    private let side = Frame(x: 1440, y: 0, width: 1920, height: 1080)

    @Test func convertsToAndFromARect() {
        let rect = CGRect(x: 12.5, y: -40, width: 900, height: 600)
        #expect(Frame(rect).rect == rect)
        #expect(Frame(rect) == Frame(x: 12.5, y: -40, width: 900, height: 600))
    }

    @Test func roundTripsAsJSON() throws {
        let frame = Frame(x: 1, y: 2, width: 3, height: 4)
        #expect(try JSONDecoder().decode(Frame.self, from: JSONEncoder().encode(frame)) == frame)
    }

    @Test func noScreensGiveNil() {
        #expect(Frame(x: 0, y: 0, width: 900, height: 600).clamped(to: []) == nil)
    }

    @Test func aFrameInsideAScreenIsUnchanged() {
        let frame = Frame(x: 100, y: 50, width: 900, height: 600)
        #expect(frame.clamped(to: [main, side]) == frame)
    }

    @Test func aFrameHangingOffTheEdgeMovesInside() {
        #expect(
            Frame(x: 1000, y: -100, width: 900, height: 600).clamped(to: [main])
                == Frame(x: 540, y: 0, width: 900, height: 600))
    }

    @Test func aFrameLargerThanItsScreenShrinksToFit() {
        #expect(Frame(x: -50, y: -50, width: 3000, height: 2000).clamped(to: [main]) == main)
    }

    @Test func goesToTheScreenItOverlapsMost() {
        #expect(
            Frame(x: 1300, y: 100, width: 900, height: 600).clamped(to: [main, side])
                == Frame(x: 1440, y: 100, width: 900, height: 600))
        #expect(
            Frame(x: 900, y: 100, width: 900, height: 600).clamped(to: [main, side])
                == Frame(x: 540, y: 100, width: 900, height: 600))
    }

    @Test func aFrameOnNoScreenGoesToTheFirst() {
        #expect(
            Frame(x: 9000, y: 9000, width: 900, height: 600).clamped(to: [side, main])
                == Frame(x: 2460, y: 480, width: 900, height: 600))
    }

    @Test func growsToTheMinimumSizeWithinTheScreen() {
        #expect(
            Frame(x: 10, y: 10, width: 200, height: 100).clamped(to: [main])
                == Frame(x: 10, y: 10, width: 800, height: 500))
        let small = Frame(x: 0, y: 0, width: 640, height: 480)
        #expect(Frame(x: 10, y: 10, width: 200, height: 100).clamped(to: [small]) == small)
        #expect(
            Frame(x: 10, y: 10, width: 200, height: 100).clamped(to: [main], minWidth: 100, minHeight: 100)
                == Frame(x: 10, y: 10, width: 200, height: 100))
    }
}
