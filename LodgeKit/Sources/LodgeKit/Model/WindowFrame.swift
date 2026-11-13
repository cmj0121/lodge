import CoreGraphics
import Foundation

extension SessionSnapshot {
    /// A window's frame in screen coordinates, as stored in the session.
    public struct WindowFrame: Codable, Equatable, Sendable {
        public var x, y, width, height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public init(_ rect: CGRect) {
            self.init(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
        }

        public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

        /// All four values finite and at least 1×1.
        var isUsable: Bool {
            [x, y, width, height].allSatisfy(\.isFinite) && width >= 1 && height >= 1
        }

        /// On the screen it overlaps most (else the first): shrunk to fit, then moved inside; nil for no screens.
        /// It is grown to `minWidth`×`minHeight` first where the screen has room.
        public func clamped(to screens: [WindowFrame], minWidth: Double = 800, minHeight: Double = 500)
            -> WindowFrame?
        {
            guard let screen = screens.max(by: { overlap(with: $0) < overlap(with: $1) }) else { return nil }
            let width = min(max(width, minWidth), screen.width)
            let height = min(max(height, minHeight), screen.height)
            return WindowFrame(
                x: min(max(x, screen.x), screen.x + screen.width - width),
                y: min(max(y, screen.y), screen.y + screen.height - height),
                width: width, height: height)
        }

        private func overlap(with other: WindowFrame) -> Double {
            let width = min(x + self.width, other.x + other.width) - max(x, other.x)
            let height = min(y + self.height, other.y + other.height) - max(y, other.y)
            return width > 0 && height > 0 ? width * height : 0
        }
    }
}
