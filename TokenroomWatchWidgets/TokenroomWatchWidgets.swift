import AppIntents
import SwiftUI
import WidgetKit

@main
struct TokenroomWatchWidgets: WidgetBundle {
    var body: some Widget {
        UsageComplication()
        ResetSoonWidget()
    }
}

// MARK: Complications

struct ComplicationEntry: TimelineEntry {
    var date: Date
    var items: [ReadingCache.Item]
}

struct ComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> ComplicationEntry {
        ComplicationEntry(date: .now, items: SampleData.cache().items)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (ComplicationEntry) -> Void) {
        let items = ReadingCache.defaultURL.flatMap(ReadingCache.load)?.items ?? []
        completion(ComplicationEntry(date: .now, items: context.isPreview && items.isEmpty ? SampleData.cache().items : items))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<ComplicationEntry>) -> Void) {
        Task {
            let now = Date.now
            let cache = await RelayReadings.cache(at: ReadingCache.defaultURL, maxAge: 15 * 60, budget: 6, now: now)
            // One entry now and one at each reset in the next 8 hours, so rings empty on time.
            let horizon = now.addingTimeInterval(8 * 3600)
            let resets = Set((cache?.items ?? []).flatMap { $0.provider.windows.compactMap(\.resetsAt) }.filter { $0 > now && $0 < horizon })
            let entries = ([now] + resets.sorted().prefix(11)).map { date in
                ComplicationEntry(date: date, items: (cache?.items ?? []).map { $0.rolledOver(at: date) })
            }
            completion(Timeline(entries: entries, policy: .after(WidgetSchedule.nextReload(after: now, items: cache?.items ?? []))))
        }
    }
}

struct UsageComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "watch.usage", provider: ComplicationProvider()) { entry in
            ComplicationView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Usage")
        .description("Your most urgent limit, or the three most used.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

private struct ComplicationView: View {
    var entry: ComplicationEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetURL(link)
    }

    /// Circular and corner complications show one provider and open it; the rest open the list.
    private var link: URL? {
        guard let first = entry.items.first, family == .accessoryCircular || family == .accessoryCorner else { return nil }
        return DeepLink.provider(first.id).url
    }

    @ViewBuilder
    private var content: some View {
        if let first = entry.items.first {
            let window = first.provider.primaryWindow
            let used = min(max(window?.used ?? 0, 0), 100)
            switch family {
            case .accessoryCorner:
                Text(ReadingText.headline(window))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .widgetCurvesContent()
                    .widgetLabel {
                        Gauge(value: used, in: 0...100) {
                            Text(first.provider.shortName)
                        }
                        .tint(ringTint)
                    }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(entry.items.prefix(3)) { item in
                        HStack(spacing: 4) {
                            Text(item.provider.shortName)
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 52, alignment: .leading)
                                .lineLimit(1)
                            Gauge(value: min(max(item.provider.primaryWindow?.used ?? 0, 0), 100), in: 0...100) { EmptyView() }
                                .gaugeStyle(.accessoryLinearCapacity)
                                .tint(ringTint)
                            Text(ReadingText.headline(item.provider.primaryWindow))
                                .font(.system(size: 12).monospacedDigit())
                        }
                    }
                }
            case .accessoryInline:
                Text(entry.items.prefix(2).map { "\($0.provider.shortName) \(ReadingText.headline($0.provider.primaryWindow))" }.joined(separator: " · "))
            default:
                Gauge(value: used, in: 0...100) {
                    Text(first.provider.monogram)
                } currentValueLabel: {
                    Text(TokenroomFormat.percentText(used))
                        .monospacedDigit()
                }
                .gaugeStyle(.accessoryCircular)
                .tint(ringTint)
            }
        } else {
            Image(systemName: "gauge.with.dots.needle.50percent")
        }
    }

    private var ringTint: Gradient {
        Gradient(colors: [TokenroomTokens.usageHealthy, TokenroomTokens.usageWatch, TokenroomTokens.usageTight, TokenroomTokens.usageCritical])
    }
}

// MARK: Smart Stack

/// One provider's window, chosen by `relevance()`; not something people configure.
struct WindowIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Usage Window"

    @Parameter(title: "Provider")
    var providerID: String?

    @Parameter(title: "Window")
    var windowID: String?

    init() {}

    init(providerID: String, windowID: String) {
        self.providerID = providerID
        self.windowID = windowID
    }
}

struct ResetSoonEntry: RelevanceEntry {
    var item: ReadingCache.Item?
    var windowID: String?
}

/// Relevant in the Smart Stack for the last 8 hours before a session or a busy window resets,
/// and for the next half day whenever a window is at 80% or more.
struct ResetSoonProvider: RelevanceEntriesProvider {
    static let busyUse = 80.0
    static let busySpan: TimeInterval = 12 * 3600

    func relevance() async -> WidgetRelevance<WindowIntent> {
        let now = Date.now
        let items = ReadingCache.defaultURL.flatMap(ReadingCache.load)?.items ?? []
        var attributes: [WidgetRelevanceAttribute<WindowIntent>] = []
        for item in items where item.provider.isLive {
            if let window = item.provider.windowToFollow(now: now), let resetsAt = window.resetsAt {
                let start = max(now, resetsAt.addingTimeInterval(-RelayProvider.followHorizon))
                attributes.append(WidgetRelevanceAttribute(
                    configuration: WindowIntent(providerID: item.id, windowID: window.id),
                    context: .date(range: start...resetsAt, kind: .default)
                ))
            } else if let window = item.provider.windows.filter({ $0.isMetered && $0.used >= Self.busyUse }).max(by: { $0.used < $1.used }) {
                let end = min(window.resetsAt ?? now.addingTimeInterval(Self.busySpan), now.addingTimeInterval(Self.busySpan))
                guard end > now else { continue }
                attributes.append(WidgetRelevanceAttribute(
                    configuration: WindowIntent(providerID: item.id, windowID: window.id),
                    context: .date(range: now...end, kind: .default)
                ))
            }
        }
        return WidgetRelevance(attributes)
    }

    func entry(configuration: WindowIntent, context: Context) async throws -> ResetSoonEntry {
        let items = ReadingCache.defaultURL.flatMap(ReadingCache.load)?.items ?? []
        return ResetSoonEntry(item: items.first { $0.id == configuration.providerID }, windowID: configuration.windowID)
    }

    func placeholder(context: Context) -> ResetSoonEntry {
        let item = SampleData.cache().items.first { $0.id == Provider.claude.rawValue }
        return ResetSoonEntry(item: item, windowID: "session")
    }
}

struct ResetSoonWidget: Widget {
    var body: some WidgetConfiguration {
        RelevanceConfiguration(kind: "watch.resetSoon", provider: ResetSoonProvider()) { entry in
            ResetSoonView(entry: entry)
        }
        .configurationDisplayName("Resets Soon")
        .description("Shows up in the Smart Stack when a limit is at 80% or nears its reset.")
    }
}

private struct ResetSoonView: View {
    var entry: ResetSoonEntry

    var body: some View {
        if let item = entry.item, let window = item.provider.windows.first(where: { $0.id == entry.windowID }) ?? item.provider.primaryWindow {
            HStack(spacing: 8) {
                MonogramMark(provider: item.provider, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(item.provider.shortName) \(window.title.lowercased()) \(ReadingText.headline(window))")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let resetsAt = window.resetsAt, resetsAt > .now {
                        Text("Resets in \(Text(resetsAt, style: .relative))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .widgetURL(DeepLink.provider(item.id).url)
        } else {
            Text("No window resets soon")
                .font(.footnote)
        }
    }
}
