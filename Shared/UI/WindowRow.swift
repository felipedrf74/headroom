import SwiftUI

/// One usage window as a compact block: title and headline, a thin meter with the pace tick, and
/// a caption such as "resets in 2d 4h". Used in the Mac's expanded cards and on Apple Watch.
struct WindowRow: View {
    var title: String
    /// "64%", "$12.40 left".
    var headline: String
    /// Nil for windows without a meter (a balance with no limit).
    var usedPercent: Double?
    var isStale: Bool
    var paceMark: Double? = nil
    var caption: String? = nil
    var titleFont: Font = .caption
    var captionFont: Font = .caption2

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(titleFont)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(headline)
                    .font(titleFont.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(ink)
            }
            if let usedPercent {
                MeterTrack(usedPercent: usedPercent, remaining: 100 - usedPercent, isStale: isStale, paceMark: paceMark, height: 5)
            }
            if let caption {
                Text(caption)
                    .font(captionFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var ink: Color {
        guard let usedPercent else { return .primary }
        return TokenroomTokens.ink(remaining: 100 - usedPercent, isStale: isStale)
    }
}
