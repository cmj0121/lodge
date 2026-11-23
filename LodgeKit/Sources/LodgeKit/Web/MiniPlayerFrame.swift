import CoreGraphics

/// The mini player's frame (#36) while it is dragged by an edge or a corner: which edges a point grabs, and the frame
/// a drag makes, keeping the video's aspect ratio. Coordinates are AppKit's, y up.
public enum MiniPlayerFrame {
    public struct Edges: OptionSet, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let left = Edges(rawValue: 1)
        public static let right = Edges(rawValue: 2)
        public static let bottom = Edges(rawValue: 4)
        public static let top = Edges(rawValue: 8)
    }

    /// The widest a video's shape is taken, width to height, and the tallest, height to width: a page's video
    /// beyond it (a 1×65536 one) still makes a panel of at most this shape.
    public static let maximumAspect: CGFloat = 4

    /// `size`, a video's width to height, as the panel's aspect ratio: kept as is within 1:`maximumAspect` …
    /// `maximumAspect`:1, else that limit; nil when a side is not positive and finite.
    public static func aspect(of size: CGSize) -> CGSize? {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return nil }
        let ratio = size.width / size.height
        if ratio > maximumAspect { return CGSize(width: maximumAspect, height: 1) }
        if ratio < 1 / maximumAspect { return CGSize(width: 1, height: maximumAspect) }
        return size
    }

    /// The panel's size `width` wide at `aspect`, at least `minHeight` tall, shrunk at the same ratio where it would
    /// be wider or taller than `bounds` (the screen's visible frame). The screen wins: the result always fits
    /// `bounds`, even when that leaves it narrower than the panel's minimum width or lower than `minHeight`.
    public static func sized(width: CGFloat, aspect: CGSize, minHeight: CGFloat, within bounds: CGRect) -> CGSize {
        guard aspect.width > 0, aspect.height > 0 else { return CGSize(width: width, height: minHeight) }
        let ratio = aspect.width / aspect.height
        var size = CGSize(width: width, height: max(minHeight, (width / ratio).rounded()))
        if size.height > bounds.height { size = CGSize(width: (bounds.height * ratio).rounded(), height: bounds.height) }
        if size.width > bounds.width { size = CGSize(width: bounds.width, height: (bounds.width / ratio).rounded()) }
        return size
    }

    /// The edges within `margin` of `point` in a view of `size`; none in the middle, where a drag moves the panel.
    public static func edges(at point: CGPoint, in size: CGSize, margin: CGFloat) -> Edges {
        var edges: Edges = []
        if point.x <= margin { edges.insert(.left) } else if point.x >= size.width - margin { edges.insert(.right) }
        if point.y <= margin { edges.insert(.bottom) } else if point.y >= size.height - margin { edges.insert(.top) }
        return edges
    }

    /// `frame` dragged by `edges` through `delta`, at `aspect` (width to height), at least `minWidth` wide and at most
    /// as large as `bounds` (the screen's visible frame) allows, and moved back inside `bounds` where it would leave
    /// them. Otherwise the edges opposite the dragged ones stay put; dragging a side keeps the top, dragging the top or
    /// bottom keeps the left. A corner follows whichever way the pointer moved more.
    public static func resized(
        _ frame: CGRect, edges: Edges, by delta: CGVector, aspect: CGSize, minWidth: CGFloat, within bounds: CGRect
    ) -> CGRect {
        guard !edges.isEmpty, aspect.width > 0, aspect.height > 0 else { return frame }
        let ratio = aspect.width / aspect.height
        let dx = edges.contains(.left) ? -delta.dx : edges.contains(.right) ? delta.dx : 0
        let dy = edges.contains(.bottom) ? -delta.dy : edges.contains(.top) ? delta.dy : 0
        let grow = abs(dx) >= abs(dy * ratio) ? dx : dy * ratio
        let maxWidth = max(minWidth, min(bounds.width, bounds.height * ratio))
        let width = min(max(frame.width + grow, minWidth), maxWidth)
        let height = width / ratio
        let x = edges.contains(.left) ? frame.maxX - width : frame.minX
        let y = edges.contains(.bottom) ? frame.maxY - height : edges.contains(.top) ? frame.minY : frame.maxY - height
        return CGRect(
            x: min(max(x, bounds.minX), max(bounds.minX, bounds.maxX - width)),
            y: min(max(y, bounds.minY), max(bounds.minY, bounds.maxY - height)), width: width, height: height)
    }
}
