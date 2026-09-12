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
        .frame(height: HeadroomTokens.menuRowHeight)
        .padding(.horizontal, 2)
        .fixedSize()
        .transaction { $0.animation = nil }
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
                .tracking(-0.3)
                .offset(y: 0.5)
                .opacity(faded)
        }
        .foregroundStyle(.primary)
        .frame(height: HeadroomTokens.menuRowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(meter.provider.displayName) \(percent) used")
    }

    private func meterColumn(_ meter: MenuMeter) -> some View {
        let percent = meter.isPlaceholder ? "–%" : "\(meter.valueText)%"
        let faded = meter.isStale ? HeadroomTokens.staleOpacity : 1
        return HStack(alignment: .center, spacing: 3) {
            ProviderGlyph(provider: meter.provider, size: HeadroomTokens.menuIconSize)
                .opacity(0.92 * faded)
            MenuUsageBar(
                usedPercent: meter.isPlaceholder ? 0 : meter.usedPercent,
                remaining: meter.remaining,
                isStale: meter.isStale
            )
        }
        .foregroundStyle(.primary)
        .frame(height: HeadroomTokens.menuRowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(meter.provider.displayName) \(percent) used")
    }
}

struct MenuUsageBar: View {
    var usedPercent: Double
    var remaining: Double
    var isStale: Bool

    var body: some View {
        let fraction = MeterLayout.usedFraction(usedPercent)
        Canvas { context, size in
            let stroke = HeadroomTokens.menuMeterStroke
            let outline = CGRect(
                x: stroke / 2,
                y: stroke / 2,
                width: max(size.width - stroke, 1),
                height: max(size.height - stroke, 1)
            )
            let inner = outline.insetBy(dx: stroke / 2, dy: stroke / 2)
            let well = inner.insetBy(dx: HeadroomTokens.menuMeterFillInset, dy: HeadroomTokens.menuMeterFillInset)
            let radius = HeadroomTokens.menuMeterCorner
            let rim = Path(roundedRect: outline, cornerRadius: radius, style: .continuous)
            let fillRadius = max(radius - stroke / 2 - HeadroomTokens.menuMeterFillInset, 0.7)

            if fraction > 0, well.width > 0, well.height > 0 {
                let fillHeight = MeterLayout.fillLength(usedPercent: usedPercent, total: well.height)
                let fillRect = CGRect(
                    x: well.minX,
                    y: well.maxY - fillHeight,
                    width: well.width,
                    height: fillHeight
                )
                let corner = min(fillRadius, fillRect.height / 2)
                context.fill(
                    Path(roundedRect: fillRect, cornerRadius: corner, style: .continuous),
                    with: .color(HeadroomTokens.usageColor(usedPercent: usedPercent, isStale: isStale))
                )
            }
            context.stroke(rim, with: .color(Color.primary), lineWidth: stroke)
        }
        .frame(width: HeadroomTokens.menuMeterBarWidth, height: HeadroomTokens.menuMeterBarHeight)
        .accessibilityHidden(true)
    }
}
