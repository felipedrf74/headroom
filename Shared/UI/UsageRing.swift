import SwiftUI

/// A ring for one window: used percent in the usage gradient, a label (the monogram or the
/// percent) in the middle. Scales to its frame, from a Watch row to the iPhone's summary card.
struct UsageRing: View {
    var used: Double
    var isStale: Bool
    var label: String
    /// Stroke width; nil scales with the ring.
    var lineWidth: CGFloat? = nil

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let width = lineWidth ?? max(3, side * 0.11)
            ZStack {
                Circle()
                    .stroke(TokenroomTokens.track, lineWidth: width)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(fill, style: StrokeStyle(lineWidth: width, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(label)
                    .font(.system(size: side * 0.3, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(width)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(TokenroomFormat.percentText(used)) percent used")
    }

    private var fraction: CGFloat {
        CGFloat(min(max(used, 0), 100) / 100)
    }

    /// The gradient runs around the whole ring, so 30% stays cool and 95% reaches red.
    private var fill: AnyShapeStyle {
        if isStale {
            return AnyShapeStyle(Color.secondary)
        }
        // Starts a little before 12 o'clock, so the round cap at the start takes the first color
        // instead of the last one wrapping around.
        return AnyShapeStyle(AngularGradient(gradient: TokenroomTokens.usageGradient, center: .center, startAngle: .degrees(-12), endAngle: .degrees(348)))
    }
}
