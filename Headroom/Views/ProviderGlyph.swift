import SwiftUI

/// Menu-bar marks. Brand logos as template images so they tint with the extra;
/// Claude and Cursor stay as paths.
struct ProviderGlyph: View {
    var provider: Provider
    var size: CGFloat = 11

    var body: some View {
        Group {
            if let name = provider.menuGlyphName, let image = HeadroomImage.template(name) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    .padding(size * 0.06)
            } else if let name = provider.menuGlyphName {
                Image(name)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    .padding(size * 0.06)
            } else {
                switch provider {
                case .claude:
                    ClaudeMark()
                        .stroke(style: StrokeStyle(lineWidth: max(1.2, size * 0.12), lineCap: .round))
                        .padding(size * 0.08)
                case .cursor:
                    CursorMark()
                        .fill()
                        .padding(size * 0.06)
                default:
                    Color.clear
                }
            }
        }
        .frame(width: size, height: size, alignment: .center)
        .accessibilityHidden(true)
    }
}

private struct ClaudeMark: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = rect.insetBy(dx: 0.6, dy: 0.6)
        let c = CGPoint(x: inset.midX, y: inset.midY)
        let r = min(inset.width, inset.height) * 0.48
        var path = Path()
        for i in 0..<4 {
            let a = (Double(i) / 8) * .pi * 2 - .pi / 2
            path.move(to: CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r))
            path.addLine(to: CGPoint(x: c.x - CGFloat(cos(a)) * r, y: c.y - CGFloat(sin(a)) * r))
        }
        return path
    }
}

private struct CursorMark: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = rect.insetBy(dx: 0.4, dy: 0.4)
        let x = inset.minX
        let y = inset.minY
        let w = inset.width
        let h = inset.height
        var path = Path()
        path.move(to: CGPoint(x: x + w * 0.20, y: y + h * 0.12))
        path.addLine(to: CGPoint(x: x + w * 0.84, y: y + h * 0.50))
        path.addLine(to: CGPoint(x: x + w * 0.20, y: y + h * 0.88))
        path.addLine(to: CGPoint(x: x + w * 0.20, y: y + h * 0.68))
        path.addLine(to: CGPoint(x: x + w * 0.56, y: y + h * 0.50))
        path.addLine(to: CGPoint(x: x + w * 0.20, y: y + h * 0.32))
        path.closeSubpath()
        return path
    }
}
