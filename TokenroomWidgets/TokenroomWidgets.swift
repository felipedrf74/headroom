import SwiftUI
import WidgetKit

@main
struct TokenroomWidgetsBundle: WidgetBundle {
    var body: some Widget {
        UsageWidget()
        SessionActivityWidget()
        FollowUsageControl()
    }
}

struct UsageWidget: Widget {
    static let kind = "usage"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: SelectProviderIntent.self, provider: ReadingsTimelineProvider()) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Usage")
        .description("How much of each plan you've used, and when it resets.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct ReadingsTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ReadingsEntry {
        var entry = ReadingsEntry.make(SampleData.cache(), choice: .automatic, date: .now)
        entry.isPlaceholder = true
        return entry
    }

    func snapshot(for configuration: SelectProviderIntent, in context: Context) async -> ReadingsEntry {
        // The widget gallery shows samples until there are real readings.
        let cache = ReadingCache.defaultURL.flatMap(ReadingCache.load)
        return ReadingsEntry.make(context.isPreview && (cache?.items.isEmpty ?? true) ? SampleData.cache() : cache, choice: configuration.provider, date: .now)
    }

    func timeline(for configuration: SelectProviderIntent, in context: Context) async -> Timeline<ReadingsEntry> {
        let now = Date.now
        let cache = await WidgetRefresher.cache(now: now)
        // One entry now and one at each reset in the next 8 hours, so meters empty on time.
        let horizon = now.addingTimeInterval(8 * 3600)
        let resets = Set((cache?.items ?? []).flatMap { $0.provider.windows.compactMap(\.resetsAt) }.filter { $0 > now && $0 < horizon })
        let dates = [now] + resets.sorted().prefix(11)
        return Timeline(
            entries: dates.map { ReadingsEntry.make(cache, choice: configuration.provider, date: $0) },
            policy: .after(now.addingTimeInterval(30 * 60))
        )
    }
}
