import SwiftUI

enum HeadroomFormat {
    static func percentText(_ value: Double) -> String {
        let clamped = max(0, min(100, value))
        let nearest = clamped.rounded()
        if abs(clamped - nearest) < 0.05 {
            return String(Int(nearest))
        }
        return String(format: "%.1f", clamped)
    }
}

enum HeadroomTokens {
    static let tightRemaining = 25.0
    static let criticalRemaining = 10.0

    static let tight = Color(red: 196 / 255, green: 122 / 255, blue: 44 / 255)
    static let critical = Color(red: 194 / 255, green: 59 / 255, blue: 34 / 255)
    static let fill = Color.primary.opacity(0.85)
    static let track = Color.primary.opacity(0.12)
    static let staleOpacity = 0.55

    static let menuLabelSize: CGFloat = 10
    static let menuPercentSize: CGFloat = 12
    static let menuIconSize: CGFloat = 16.4
    static let menuRowHeight: CGFloat = 20
    static let menuColumnSpacing: CGFloat = 8
    static let menuMeterBarWidth: CGFloat = 5
    static let menuMeterBarHeight: CGFloat = 18
    static let menuMeterSpacing: CGFloat = 6
    static let menuMeterStroke: CGFloat = 1
    static let menuMeterCorner: CGFloat = 2.5
    static let popoverNameSize: CGFloat = 13
    static let popoverPercentSize: CGFloat = 22
    static let captionSize: CGFloat = 11
    static let meterHeight: CGFloat = 8
    static let meterRadius: CGFloat = 6
    static let rhythm: CGFloat = 8
    static let cardPadding: CGFloat = 12
    static let cardGap: CGFloat = 8
    static let popoverWidth: CGFloat = 360

    static func ink(remaining: Double, isStale: Bool) -> Color {
        if isStale {
            return Color.secondary.opacity(staleOpacity)
        }
        if remaining <= criticalRemaining {
            return critical
        }
        if remaining <= tightRemaining {
            return tight
        }
        return Color.primary
    }

    static func meterFill(remaining: Double, isStale: Bool) -> Color {
        ink(remaining: remaining, isStale: isStale)
    }
}
