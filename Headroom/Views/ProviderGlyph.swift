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
                    .interpolation(.medium)
                    .scaledToFit()
            } else {
                Canvas { context, canvas in
                    let rect = CGRect(origin: .zero, size: canvas).insetBy(dx: 0.4, dy: 0.4)
                    switch provider {
                    case .grok: slashG(in: rect, context: &context)
                    case .grokBot: face(in: rect, context: &context)
                    case .openai: blossom(in: rect, context: &context)
                    case .claude: asterisk(rays: 8, in: rect, context: &context, weight: 0.145)
                    case .cursor: chevron(in: rect, context: &context)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func asterisk(rays: Int, in rect: CGRect, context: inout GraphicsContext, weight: CGFloat) {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let s = min(rect.width, rect.height)
        let r = s * 0.48
        var path = Path()
        let diameters = max(rays / 2, 1)
        for i in 0..<diameters {
            let a = (Double(i) / Double(rays)) * .pi * 2 - .pi / 2
            path.move(to: CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r))
            path.addLine(to: CGPoint(x: c.x - CGFloat(cos(a)) * r, y: c.y - CGFloat(sin(a)) * r))
        }
        context.stroke(
            path,
            with: .foreground,
            style: StrokeStyle(lineWidth: s * weight, lineCap: .round)
        )
    }

    private func chevron(in rect: CGRect, context: inout GraphicsContext) {
        let x = rect.minX
        let y = rect.minY
        let w = rect.width
        let h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: x + w * 0.20, y: y + h * 0.12))
        path.addLine(to: CGPoint(x: x + w * 0.84, y: y + h * 0.50))
        path.addLine(to: CGPoint(x: x + w * 0.20, y: y + h * 0.88))
        path.addLine(to: CGPoint(x: x + w * 0.20, y: y + h * 0.68))
        path.addLine(to: CGPoint(x: x + w * 0.56, y: y + h * 0.50))
        path.addLine(to: CGPoint(x: x + w * 0.20, y: y + h * 0.32))
        path.closeSubpath()
        context.fill(path, with: .foreground)
    }

    private func slashG(in rect: CGRect, context: inout GraphicsContext) {
        let s = min(rect.width, rect.height)
        let inset = CGRect(
            x: rect.midX - s * 0.42,
            y: rect.midY - s * 0.42,
            width: s * 0.84,
            height: s * 0.84
        )
        var ring = Path()
        ring.addArc(
            center: CGPoint(x: inset.midX, y: inset.midY),
            radius: inset.width * 0.46,
            startAngle: .degrees(38),
            endAngle: .degrees(328),
            clockwise: false
        )
        context.stroke(ring, with: .foreground, style: StrokeStyle(lineWidth: s * 0.13, lineCap: .round))
        var slash = Path()
        slash.move(to: CGPoint(x: inset.minX + inset.width * 0.18, y: inset.maxY - inset.height * 0.12))
        slash.addLine(to: CGPoint(x: inset.maxX - inset.width * 0.14, y: inset.minY + inset.height * 0.16))
        context.stroke(slash, with: .foreground, style: StrokeStyle(lineWidth: s * 0.12, lineCap: .round))
    }

    private func face(in rect: CGRect, context: inout GraphicsContext) {
        let s = min(rect.width, rect.height)
        let inset = CGRect(
            x: rect.midX - s * 0.44,
            y: rect.midY - s * 0.44,
            width: s * 0.88,
            height: s * 0.88
        )
        context.stroke(
            Path(ellipseIn: inset.insetBy(dx: s * 0.06, dy: s * 0.06)),
            with: .foreground,
            style: StrokeStyle(lineWidth: s * 0.11)
        )
        let eyeY = inset.minY + inset.height * 0.40
        let eyeR = s * 0.055
        context.fill(
            Path(ellipseIn: CGRect(x: inset.minX + inset.width * 0.30 - eyeR, y: eyeY - eyeR, width: eyeR * 2, height: eyeR * 2)),
            with: .foreground
        )
        context.fill(
            Path(ellipseIn: CGRect(x: inset.maxX - inset.width * 0.30 - eyeR, y: eyeY - eyeR, width: eyeR * 2, height: eyeR * 2)),
            with: .foreground
        )
    }

    private func blossom(in rect: CGRect, context: inout GraphicsContext) {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let s = min(rect.width, rect.height)
        var path = Path()
        for i in 0..<8 {
            let a = (Double(i) / 8) * .pi * 2 - .pi / 2
            path.move(to: c)
            path.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * s * 0.46, y: c.y + CGFloat(sin(a)) * s * 0.46))
        }
        context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: s * 0.11, lineCap: .round))
        let r = s * 0.09
        context.fill(
            Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
            with: .foreground
        )
    }
}
