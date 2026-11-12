import SwiftUI

extension View {
    /// The look of anything that floats over the lodge: rounded, a hairline edge and a soft shadow.
    func floatingSurface(cornerRadius: CGFloat, fill: some ShapeStyle = .background) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        return clipShape(shape)
            .overlay { shape.strokeBorder(.separator, lineWidth: 0.5) }
            .background { shape.fill(fill).shadow(color: .black.opacity(0.3), radius: 8, y: 2) }
    }
}
