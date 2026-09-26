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
    var isSample = false
}

struct ComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> ComplicationEntry {
        ComplicationEntry(date: .now, items: SampleData.cache().items)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (ComplicationEntry) -> Void) {
        let saved = ReadingCache.defaultURL.flatMap(ReadingCache.load)
        let cache = context.isPreview && (saved?.items.isEmpty ?? true) ? SampleData.cache() : saved
        completion(ComplicationEntry(date: .now, items: cache?.items ?? [], isSample: cache?.isSample ?? false))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<ComplicationEntry>) -> Void) {
        let widget = "watch-\(context.family)"
        Task {
            let now = Date.now
            let reloads = WidgetReloadLog.record(widget, at: now)
            let cache = await RelayReadings.cache(at: ReadingCache.defaultURL, maxAge: 15 * 60, budget: 6, now: now)
            // One entry now and one at each reset in the next 8 hours, so rings empty on time.
            let horizon = now.addingTimeInterval(8 * 3600)
            let resets = Set((cache?.items ?? []).flatMap { $0.provider.windows.compactMap(\.resetsAt) }.filter { $0 > now && $0 < horizon })
            let entries = ([now] + resets.sorted().prefix(11)).map { date in
                ComplicationEntry(date: date, items: (cache?.items ?? []).map { $0.rolledOver(at: date) }, isSample: cache?.isSample ?? false)
            }
            completion(Timeline(entries: entries, policy: .after(WidgetSchedule.nextReload(after: now, items: cache?.items ?? [], reloads: reloads))))
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
        guard let first = entry.items.first, family == .accessoryCircular || family == .accessoryCorner else { return Self.listURL }
        return DeepLink.provider(first.id).url
    }

    /// Not a provider's link, so the Watch app opens on its list rather than where it was left.
    private static let listURL = URL(string: "\(DeepLink.scheme)://usage")

    @ViewBuilder
    private var content: some View {
        if let first = entry.items.first {
            let window = first.provider.primaryWindow
            let used = min(max(window?.used ?? 0, 0), 100)
            switch family {
            case .accessoryCorner:
                let balance = window.flatMap { $0.isMetered ? nil : $0.amount }
                // A balance has nothing to fill: its amount, and the provider's name for a label.
                Text(balance.map(ReadingText.circleAmount) ?? ReadingText.headline(window))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .widgetCurvesContent()
                    .widgetLabel {
                        if entry.isSample {
                            Text("Sample")
                        } else if balance != nil {
                            Text(first.provider.shortName)
                        } else {
                            Gauge(value: used, in: 0...100) {
                                Text(first.provider.shortName)
                            }
                            .tint(ringTint)
                        }
                    }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    // Samples give up a row to say so.
                    ForEach(entry.items.prefix(entry.isSample ? 2 : 3)) { item in
                        let row = item.provider.primaryWindow
                        HStack(spacing: 4) {
                            Text(item.provider.shortName)
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 52, alignment: .leading)
                                .lineLimit(1)
                            if row?.isMetered == false, row?.amount != nil {
                                // A balance: its amount, with no empty bar beside it.
                                Spacer(minLength: 0)
                            } else {
                                Gauge(value: min(max(row?.used ?? 0, 0), 100), in: 0...100) { EmptyView() }
                                    .gaugeStyle(.accessoryLinearCapacity)
                                    .tint(ringTint)
                            }
                            Text(ReadingText.headline(row))
                                .font(.system(size: 12).monospacedDigit())
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    if entry.isSample {
                        Text("Sample data")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            case .accessoryInline:
                Text(inlineText)
            default:
                if let window, !window.isMetered, let amount = window.amount {
                    // A balance has nothing to fill: its amount, rather than a ring reading 0.
                    ZStack {
                        AccessoryWidgetBackground()
                        VStack(spacing: 0) {
                            Text(ReadingText.circleAmount(amount))
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .minimumScaleFactor(0.5)
                            Text(entry.isSample ? "Sample" : first.provider.monogram)
                                .font(.system(size: 10, weight: .medium))
                                .minimumScaleFactor(0.6)
                        }
                        .lineLimit(1)
                        .padding(4)
                    }
                } else {
                    Gauge(value: used, in: 0...100) {
                        Text(first.provider.monogram)
                    } currentValueLabel: {
                        // Samples say so where the number goes; the ring still shows the level.
                        if entry.isSample {
                            Text("Sample")
                                .font(.system(size: 9, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        } else {
                            Text(TokenroomFormat.percentText(used))
                                .monospacedDigit()
                        }
                    }
                    .gaugeStyle(.accessoryCircular)
                    .tint(ringTint)
                }
            }
        } else {
            Image(systemName: "gauge.with.dots.needle.50percent")
        }
    }

    /// "Codex 78% · Claude 64%", after "Sample" for samples.
    private var inlineText: String {
        let readings = entry.items.prefix(2).map { "\($0.provider.shortName) \(ReadingText.headline($0.provider.primaryWindow))" }
        return ((entry.isSample ? ["Sample"] : []) + readings).joined(separator: " · ")
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
    var isSample = false
}

/// Relevant in the Smart Stack for the last 8 hours before a session or a busy window resets,
/// and for the next half day whenever a window is at 80% or more (`WidgetSchedule.relevance`).
struct ResetSoonProvider: RelevanceEntriesProvider {
    func relevance() async -> WidgetRelevance<WindowIntent> {
        let now = Date.now
        let items = ReadingCache.defaultURL.flatMap(ReadingCache.load)?.items ?? []
        let attributes = items.flatMap { item in
            WidgetSchedule.relevance(of: item.provider, now: now).map { relevant in
                WidgetRelevanceAttribute(
                    configuration: WindowIntent(providerID: item.id, windowID: relevant.window.id),
                    context: .date(range: relevant.span, kind: .default)
                )
            }
        }
        return WidgetRelevance(attributes)
    }

    func entry(configuration: WindowIntent, context: Context) async throws -> ResetSoonEntry {
        let cache = ReadingCache.defaultURL.flatMap(ReadingCache.load)
        return ResetSoonEntry(item: cache?.items.first { $0.id == configuration.providerID }, windowID: configuration.windowID, isSample: cache?.isSample ?? false)
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
                    Group {
                        if let resetsAt = window.resetsAt, resetsAt > .now {
                            Text("Resets in \(Text(resetsAt, style: .relative))")
                        }
                        if entry.isSample {
                            Text("Sample data")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .widgetURL(DeepLink.provider(item.id).url)
        } else {
            Text("No window resets soon")
                .font(.footnote)
        }
    }
}
