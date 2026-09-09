import SwiftUI

enum MenuBarDensity: Equatable {
    case comfortable
    case compact
}

enum MenuBarLayout {
    static func density(for meters: [MenuMeter]) -> MenuBarDensity {
        .compact
    }

    static func compactText(for meters: [MenuMeter]) -> String {
        meters.map { "\($0.provider.shortName) \($0.valueText)%" }.joined(separator: "  ")
    }

    static func tooltip(for meters: [MenuMeter]) -> String {
        if meters.isEmpty {
            return "Headroom"
        }
        return meters.map { meter in
            let value = meter.isPlaceholder ? "–%" : "\(meter.valueText)%"
            return "\(meter.provider.displayName) \(value)"
        }.joined(separator: "\n")
    }
}

struct MenuBarLabel: View {
    var meters: [MenuMeter]
    var style: MenuBarStyle = .percents

    var body: some View {
        Group {
            if meters.isEmpty {
                Text("Headroom")
                    .font(.system(size: HeadroomTokens.menuPercentSize, weight: .medium))
            } else {
                HStack(alignment: .center, spacing: columnSpacing) {
                    ForEach(meters) { meter in
                        column(meter)
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .fixedSize()
    }

    private var columnSpacing: CGFloat {
        style == .meters ? HeadroomTokens.menuMeterSpacing : HeadroomTokens.menuColumnSpacing
    }

    @ViewBuilder
    private func column(_ meter: MenuMeter) -> some View {
        switch style {
        case .percents:
            percentColumn(meter)
        case .meters:
            meterColumn(meter)
        }
    }

    private func percentColumn(_ meter: MenuMeter) -> some View {
        let percent = meter.isPlaceholder ? "–%" : "\(meter.valueText)%"
        let faded = meter.isStale ? HeadroomTokens.staleOpacity : 1
        return HStack(alignment: .center, spacing: 3) {
            ProviderGlyph(provider: meter.provider, size: HeadroomTokens.menuIconSize)
                .opacity(0.92 * faded)
            Text(percent)
                .font(.system(size: HeadroomTokens.menuPercentSize, weight: .semibold).monospacedDigit())
                .tracking(-0.2)
                .opacity(faded)
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(meter.provider.displayName) \(percent)")
    }

    private func meterColumn(_ meter: MenuMeter) -> some View {
        let percent = meter.isPlaceholder ? "–%" : "\(meter.valueText)%"
        let faded = meter.isStale ? HeadroomTokens.staleOpacity : 1
        return HStack(alignment: .center, spacing: 2) {
            ProviderGlyph(provider: meter.provider, size: HeadroomTokens.menuIconSize)
                .opacity(0.92 * faded)
            MenuUsageBar(
                usedPercent: meter.isPlaceholder ? 0 : meter.usedPercent,
                remaining: meter.remaining,
                isStale: meter.isStale
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(meter.provider.displayName) \(percent)")
    }
}

struct MenuUsageBar: View {
    var usedPercent: Double
    var remaining: Double
    var isStale: Bool

    var body: some View {
        let fraction = MeterLayout.usedFraction(usedPercent)
        let width = HeadroomTokens.menuMeterBarWidth
        let height = HeadroomTokens.menuMeterBarHeight
        let stroke: CGFloat = 1
        Capsule()
            .fill(Color.primary.opacity(0.10))
            .overlay {
                GeometryReader { geo in
                    let innerW = max(0, geo.size.width - stroke * 2)
                    let innerH = max(0, geo.size.height - stroke * 2)
                    ZStack(alignment: .bottom) {
                        Color.clear
                        if fraction > 0 {
                            Capsule()
                                .fill(HeadroomTokens.meterFill(remaining: remaining, isStale: isStale))
                                .frame(width: innerW, height: max(2, innerH * fraction))
                        }
                    }
                    .padding(stroke)
                }
            }
            .overlay {
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.92), lineWidth: stroke)
            }
            .clipShape(Capsule())
            .frame(width: width, height: height)
            .accessibilityHidden(true)
    }
}
