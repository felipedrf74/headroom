import SwiftUI

/// A week of hourly usage as a line over a soft fill. Hours without a reading leave a gap;
/// 0–100% spans the full height.
struct Sparkline: View {
    var history: UsageHistory
    var tint: Color
    var lineWidth: CGFloat = 1.5

    var body: some View {
        Canvas { context, size in
            let values = history.used
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(values.count - 1)
            for segment in Self.segments(values) {
                let points = segment.map { index, value in
                    CGPoint(x: CGFloat(index) * step, y: size.height * (1 - CGFloat(value) / 100))
                }
                guard let first = points.first, let last = points.last else { continue }
                var line = Path()
                line.addLines(points)
                var area = line
                area.addLine(to: CGPoint(x: last.x, y: size.height))
                area.addLine(to: CGPoint(x: first.x, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(
                    Gradient(colors: [tint.opacity(0.28), tint.opacity(0.02)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                ))
                if points.count == 1 {
                    context.fill(Path(ellipseIn: CGRect(x: first.x - lineWidth, y: first.y - lineWidth, width: lineWidth * 2, height: lineWidth * 2)), with: .color(tint))
                } else {
                    context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// What the line shows, for VoiceOver: its highest hour and the latest.
    static func summary(_ history: UsageHistory) -> String {
        let used = history.points.map { $0.used }
        guard let latest = used.last, let highest = used.max() else { return "No readings" }
        return "Highest \(TokenroomFormat.percentText(highest))%, latest \(TokenroomFormat.percentText(latest))%"
    }

    /// Runs of consecutive readings, as (hour index, used %).
    static func segments(_ values: [UInt8?]) -> [[(Int, Double)]] {
        var segments: [[(Int, Double)]] = []
        var current: [(Int, Double)] = []
        for (index, value) in values.enumerated() {
            if let value {
                current.append((index, Double(value)))
            } else if !current.isEmpty {
                segments.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            segments.append(current)
        }
        return segments
    }
}
