import SwiftUI

struct MeterTrack: View {
    var usedPercent: Double
    var remaining: Double
    var isStale: Bool
    /// Where an even pace would be now, 0–1 of the window; drawn as a tick.
    var paceMark: Double? = nil
    var height: CGFloat = TokenroomTokens.meterHeight

    var body: some View {
        let radius = min(2.5, height / 2)
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(TokenroomTokens.track)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    let fillWidth = MeterLayout.fillLength(usedPercent: usedPercent, total: geometry.size.width)
                    if fillWidth > 0 {
                        Rectangle()
                            .fill(usageGradient)
                            .frame(width: geometry.size.width)
                            .frame(width: fillWidth, alignment: .leading)
                            .clipped()
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .frame(height: height)
            .overlay(alignment: .leading) {
                if let paceMark, !isStale {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(Color.primary.opacity(0.7))
                            .frame(width: 2, height: height + 6)
                            .offset(x: geometry.size.width * min(max(paceMark, 0), 1) - 1, y: -3)
                    }
                }
            }
            .accessibilityHidden(true)
    }

    private var usageGradient: some ShapeStyle {
        if isStale {
            return AnyShapeStyle(Color.secondary.opacity(0.72))
        }
        return AnyShapeStyle(
            LinearGradient(
                gradient: TokenroomTokens.usageGradient,
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }
}
