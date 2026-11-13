public enum PageZoom {
    public static let levels: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    public static let actual: Double = 1.0

    public static func zoomedIn(from current: Double) -> Double {
        levels.first { $0 > current } ?? levels[levels.count - 1]
    }

    public static func zoomedOut(from current: Double) -> Double {
        levels.last { $0 < current } ?? levels[0]
    }

    public static func canZoomIn(from current: Double) -> Bool {
        current < levels[levels.count - 1]
    }

    public static func canZoomOut(from current: Double) -> Bool {
        current > levels[0]
    }
}
