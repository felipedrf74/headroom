import SwiftUI

enum HeadroomFormat {
    static func percentText(_ value: Double) -> String {
        String(Int(max(0, min(100, value)).rounded()))
    }
}

enum HeadroomTokens {
    static let tightRemaining = 25.0
    static let criticalRemaining = 10.0

    static let tight = Color(red: 196 / 255, green: 122 / 255, blue: 44 / 255)
    static let critical = Color(red: 194 / 255, green: 59 / 255, blue: 34 / 255)
    static let usageHealthy = Color(red: 110 / 255, green: 196 / 255, blue: 245 / 255)
    static let usageWatch = Color(red: 242 / 255, green: 196 / 255, blue: 22 / 255)
    static let usageTight = Color(red: 232 / 255, green: 122 / 255, blue: 16 / 255)
    static let usageCritical = Color(red: 214 / 255, green: 45 / 255, blue: 38 / 255)
    static let fill = Color.primary.opacity(0.85)
    static let track = Color.primary.opacity(0.12)
    static let staleOpacity = 0.55

    static let usageGradient = Gradient(stops: [
        .init(color: usageHealthy, location: 0),
        .init(color: usageWatch, location: 0.48),
        .init(color: usageTight, location: 0.74),
        .init(color: usageCritical, location: 1),
    ])

    static let menuLabelSize: CGFloat = 10
    static let menuPercentSize: CGFloat = 12
    static let menuIconSize: CGFloat = 17.22
    static let menuRowHeight: CGFloat = 20
    static let menuColumnSpacing: CGFloat = 8
    static let menuMeterBarWidth: CGFloat = 8.05
    static let menuMeterBarHeight: CGFloat = 18
    static let menuMeterSpacing: CGFloat = 6
    static let menuMeterStroke: CGFloat = 1
    static let menuMeterCorner: CGFloat = 1.6
    static let menuMeterFillInset: CGFloat = 1.2
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

    static func usageColor(usedPercent: Double, isStale: Bool) -> Color {
        if isStale {
            return Color.secondary.opacity(0.72)
        }
        let used = max(0, min(100, usedPercent))
        if used >= 90 { return usageCritical }
        if used >= 75 { return usageTight }
        if used >= 50 { return usageWatch }
        return usageHealthy
    }

    static func usageShading(in well: CGRect, vertical: Bool, isStale: Bool) -> GraphicsContext.Shading {
        if isStale {
            return .color(Color.secondary.opacity(0.72))
        }
        let start = vertical
            ? CGPoint(x: well.midX, y: well.maxY)
            : CGPoint(x: well.minX, y: well.midY)
        let end = vertical
            ? CGPoint(x: well.midX, y: well.minY)
            : CGPoint(x: well.maxX, y: well.midY)
        return .linearGradient(usageGradient, startPoint: start, endPoint: end)
    }
}
