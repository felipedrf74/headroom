import SwiftUI

struct MeterTrack: View {
    var usedPercent: Double
    var remaining: Double
    var isStale: Bool

    var body: some View {
        let radius = min(2.5, HeadroomTokens.meterHeight / 2)
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(HeadroomTokens.track)
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
            .frame(height: HeadroomTokens.meterHeight)
            .accessibilityHidden(true)
    }

    private var usageGradient: some ShapeStyle {
        if isStale {
            return AnyShapeStyle(Color.secondary.opacity(0.72))
        }
        return AnyShapeStyle(
            LinearGradient(
                gradient: HeadroomTokens.usageGradient,
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }
}
