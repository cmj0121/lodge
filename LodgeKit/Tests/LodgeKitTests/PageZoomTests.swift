import Testing

@testable import LodgeKit

@Suite struct PageZoomTests {
    @Test func actualSizeIsOneAndALevel() {
        #expect(PageZoom.actual == 1.0)
        #expect(PageZoom.levels.contains(PageZoom.actual))
        #expect(PageZoom.levels == PageZoom.levels.sorted())
    }

    @Test func zoomInAndOutStepThroughEveryLevel() {
        let levels = PageZoom.levels
        for (lower, upper) in zip(levels, levels.dropFirst()) {
            #expect(PageZoom.zoomedIn(from: lower) == upper)
            #expect(PageZoom.zoomedOut(from: upper) == lower)
        }
        #expect(PageZoom.zoomedIn(from: 1.0) == 1.1)
        #expect(PageZoom.zoomedOut(from: 1.0) == 0.9)
    }

    @Test func clampsAtBothEnds() {
        #expect(PageZoom.zoomedIn(from: 3.0) == 3.0)
        #expect(PageZoom.zoomedIn(from: 5.0) == 3.0)
        #expect(PageZoom.zoomedOut(from: 0.5) == 0.5)
        #expect(PageZoom.zoomedOut(from: 0.1) == 0.5)
        #expect(!PageZoom.canZoomIn(from: 3.0))
        #expect(!PageZoom.canZoomOut(from: 0.5))
        #expect(PageZoom.canZoomIn(from: 2.5))
        #expect(PageZoom.canZoomOut(from: 0.67))
    }

    @Test func offLevelValuesSnapToTheNextLevel() {
        #expect(PageZoom.zoomedIn(from: 1.05) == 1.1)
        #expect(PageZoom.zoomedOut(from: 1.05) == 1.0)
        #expect(PageZoom.zoomedIn(from: 0.3) == 0.5)
        #expect(PageZoom.zoomedOut(from: 4.0) == 3.0)
    }
}
