import SwiftUI

struct MeterTrack: View {
    var usedPercent: Double
    var remaining: Double
    var isStale: Bool

    var body: some View {
        GeometryReader { geometry in
            let fillWidth = MeterLayout.fillLength(usedPercent: usedPercent, total: geometry.size.width)
            Capsule()
                .fill(HeadroomTokens.track)
                .overlay(alignment: .leading) {
                    if fillWidth > 0 {
                        Rectangle()
                            .fill(HeadroomTokens.meterFill(remaining: remaining, isStale: isStale))
                            .frame(width: fillWidth)
                    }
                }
                .clipShape(Capsule())
        }
        .frame(height: HeadroomTokens.meterHeight)
        .accessibilityHidden(true)
    }
}
