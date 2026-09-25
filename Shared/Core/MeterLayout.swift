import CoreGraphics
import Foundation

enum MeterLayout {
    static func usedFraction(_ usedPercent: Double) -> CGFloat {
        CGFloat(min(max(usedPercent / 100, 0), 1))
    }

    static func fillLength(usedPercent: Double, total: CGFloat) -> CGFloat {
        let fraction = usedFraction(usedPercent)
        return fraction <= 0 ? 0 : total * fraction
    }
}
