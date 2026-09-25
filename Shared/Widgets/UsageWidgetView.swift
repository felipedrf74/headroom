import SwiftUI
import WidgetKit

struct UsageWidgetView: View {
    var entry: ReadingsEntry
    @Environment(\.widgetFamily) private var systemFamily
    @Environment(\.widgetPreviewStyle) private var preview

    private var family: WidgetFamily {
        preview?.family ?? systemFamily
    }

    var body: some View {
        content
            .redacted(reason: entry.isPlaceholder ? .placeholder : [])
            .containerBackground(isAccessory ? AnyShapeStyle(.clear) : AnyShapeStyle(.background), for: .widget)
    }

    private var isAccessory: Bool {
        [.accessoryCircular, .accessoryRectangular, .accessoryInline].contains(family)
    }

    @ViewBuilder
    private var content: some View {
        if let first = entry.items.first {
            switch family {
            case .systemMedium:
                ListWidget(entry: entry, count: 4, showsHistory: false)
            case .systemLarge:
                ListWidget(entry: entry, count: 8, showsHistory: true)
            case .accessoryCircular:
                CircularWidget(item: first)
            case .accessoryRectangular:
                RectangularWidget(items: Array(entry.items.prefix(3)), date: entry.date)
            case .accessoryInline:
                InlineWidget(items: Array(entry.items.prefix(3)))
                    .widgetURL(DeepLink.provider(first.id).url)
            default:
                SmallWidget(entry: entry, item: first)
            }
        } else {
            EmptyWidget(isAccessory: isAccessory)
        }
    }
}

// MARK: Home Screen

private struct SmallWidget: View {
    var entry: ReadingsEntry
    var item: ReadingCache.Item

    var body: some View {
        let provider = item.provider
        let window = provider.primaryWindow
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                MonogramMark(provider: provider, size: 20)
                Text(provider.shortName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if entry.isSample {
                    SampleTag()
                }
            }
            Spacer(minLength: 0)
            Text(ReadingText.headline(window))
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(headlineStyle(window, isLive: provider.isLive))
                .widgetAccentable()
            if let window {
                if window.isMetered {
                    WidgetMeter(used: window.used, isStale: !provider.isLive)
                }
                Text(window.title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                ResetText(window: window, date: entry.date)
            }
        }
        .widgetURL(DeepLink.provider(provider.id).url)
    }
}

private struct ListWidget: View {
    var entry: ReadingsEntry
    var count: Int
    var showsHistory: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: showsHistory ? 8 : 6) {
            HStack(spacing: 6) {
                Text("Usage")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if entry.isSample {
                    SampleTag()
                }
                Spacer(minLength: 0)
                if let savedAt = entry.savedAt, entry.date.timeIntervalSince(savedAt) > 3600 {
                    Text("Updated \(RelativeTime.ago(savedAt, now: entry.date))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button(intent: RefreshReadingsIntent()) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Refresh")
            }
            ForEach(entry.items.prefix(count)) { item in
                Link(destination: DeepLink.provider(item.id).url) {
                    ListRow(item: item, showsHistory: showsHistory, date: entry.date)
                }
                // Links tint their labels; rows keep their own colors.
                .foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct ListRow: View {
    var item: ReadingCache.Item
    var showsHistory: Bool
    var date: Date

    var body: some View {
        let provider = item.provider
        let window = provider.primaryWindow
        HStack(spacing: 8) {
            MonogramMark(provider: provider, size: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(provider.shortName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let resetsAt = window?.resetsAt, resetsAt > date {
                        ResetCountdown(resetsAt: resetsAt, date: date)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(ReadingText.headline(window))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(headlineStyle(window, isLive: provider.isLive))
                        .widgetAccentable()
                }
                if let window, window.isMetered {
                    WidgetMeter(used: window.used, isStale: !provider.isLive, height: 5)
                }
            }
            if showsHistory {
                Group {
                    if let history = item.primaryHistory, !history.isEmpty {
                        Sparkline(history: history, tint: Color(hex: provider.tint), lineWidth: 1.2)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 56, height: 22)
            }
        }
        .opacity(provider.isLive ? 1 : 0.6)
    }
}

// MARK: Lock Screen

private struct CircularWidget: View {
    var item: ReadingCache.Item

    var body: some View {
        let window = item.provider.primaryWindow
        Gauge(value: min(max(window?.used ?? 0, 0), 100), in: 0...100) {
            Text(item.provider.monogram)
        } currentValueLabel: {
            Text(window.map { TokenroomFormat.percentText($0.used) } ?? "–")
                .monospacedDigit()
        }
        .gaugeStyle(.accessoryCircular)
        .widgetAccentable()
        .widgetURL(DeepLink.provider(item.id).url)
    }
}

private struct RectangularWidget: View {
    var items: [ReadingCache.Item]
    var date: Date

    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(alignment: .leading, spacing: 2) {
                rows
                if let first = items.first, let resetsAt = first.provider.primaryWindow?.resetsAt, resetsAt > date {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.counterclockwise")
                        Text(first.provider.shortName)
                        ResetCountdown(resetsAt: resetsAt, date: date)
                            .monospacedDigit()
                    }
                    .font(.caption2)
                    .lineLimit(1)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                rows
            }
        }
        .widgetURL(items.first.map { DeepLink.provider($0.id).url })
    }

    private var rows: some View {
        ForEach(items) { item in
            let used = item.provider.primaryWindow?.used ?? 0
            HStack(spacing: 6) {
                Text(item.provider.shortName)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .frame(width: 58, alignment: .leading)
                Gauge(value: min(max(used, 0), 100), in: 0...100) {
                    EmptyView()
                }
                .gaugeStyle(.accessoryLinearCapacity)
                .widgetAccentable()
                Text(ReadingText.headline(item.provider.primaryWindow))
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
            }
        }
    }
}

private struct InlineWidget: View {
    var items: [ReadingCache.Item]

    var body: some View {
        ViewThatFits {
            Text(line(items))
            Text(line(Array(items.prefix(2))))
            Text(line(Array(items.prefix(1))))
        }
    }

    private func line(_ items: [ReadingCache.Item]) -> String {
        items.map { "\($0.provider.shortName) \(ReadingText.headline($0.provider.primaryWindow))" }.joined(separator: " · ")
    }
}

// MARK: Pieces

private struct EmptyWidget: View {
    var isAccessory: Bool

    var body: some View {
        if isAccessory {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .widgetURL(DeepLink.settings.url)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Spacer(minLength: 0)
                Text("No readings yet")
                    .font(.headline)
                Text("Open Tokenroom to connect your Mac or add a key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(DeepLink.settings.url)
        }
    }
}

/// A full-color meter on the Home Screen; a flat, accentable one when the system tints widgets.
private struct WidgetMeter: View {
    var used: Double
    var isStale: Bool
    var height: CGFloat = 6
    @Environment(\.widgetRenderingMode) private var systemRenderingMode
    @Environment(\.widgetPreviewStyle) private var preview

    var body: some View {
        if (preview?.renderingMode ?? systemRenderingMode) == .fullColor {
            MeterTrack(usedPercent: used, remaining: 100 - used, isStale: isStale, height: height)
        } else {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.2))
                    Capsule()
                        .fill(.primary)
                        .frame(width: geometry.size.width * min(max(used, 0), 100) / 100)
                        .widgetAccentable()
                }
            }
            .frame(height: height)
        }
    }
}

private struct ResetText: View {
    var window: RelayWindow
    var date: Date

    var body: some View {
        if let resetsAt = window.resetsAt, resetsAt > date {
            Text("Resets in \(ResetCountdown.text(resetsAt: resetsAt, date: date))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if window.isMetered, window.resetsAt == nil, window.used == 0 {
            Text("Reset")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Time left until a reset: a ticking "2:13:05" within a day, so the widget needs no reloads for
/// the clock; "3d 1h" further out.
struct ResetCountdown: View {
    var resetsAt: Date
    var date: Date

    var body: some View {
        Self.text(resetsAt: resetsAt, date: date)
    }

    static func text(resetsAt: Date, date: Date) -> Text {
        guard resetsAt > date else { return Text("now") }
        if resetsAt.timeIntervalSince(date) < 86_400 {
            return Text(timerInterval: date...resetsAt, countsDown: true)
        }
        let words = RelativeTime.resets(resetsAt, now: date) ?? ""
        return Text(words.replacingOccurrences(of: "resets in ", with: ""))
    }
}

private struct SampleTag: View {
    var body: some View {
        Text("Sample")
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(.tint.opacity(0.18), in: Capsule())
            .foregroundStyle(.tint)
    }
}

private func headlineStyle(_ window: RelayWindow?, isLive: Bool) -> Color {
    guard let window, window.isMetered else { return .primary }
    return TokenroomTokens.ink(remaining: 100 - window.used, isStale: !isLive)
}
