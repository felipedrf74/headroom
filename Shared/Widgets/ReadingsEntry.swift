import SwiftUI
import WidgetKit

struct ReadingsEntry: TimelineEntry {
    var date: Date
    /// The chosen provider first, then most urgent first.
    var items: [ReadingCache.Item]
    var isSample: Bool
    /// When the freshest reading was last confirmed; the cache itself is saved on every rebuild,
    /// however old the readings in it.
    var checkedAt: Date?
    var isPlaceholder = false

    /// The readings as they stand at `date`, the chosen provider first.
    static func make(_ cache: ReadingCache?, choice: ProviderOption, date: Date) -> ReadingsEntry {
        var items = (cache?.items ?? []).map { $0.rolledOver(at: date) }
        if let id = choice.providerID, let index = items.firstIndex(where: { $0.id == id }) {
            items.insert(items.remove(at: index), at: 0)
        }
        return ReadingsEntry(date: date, items: items, isSample: cache?.isSample ?? false, checkedAt: cache?.checkedAt)
    }
}

/// Lets the app's debug gallery draw a widget as a family and rendering mode it picks; WidgetKit
/// sets both itself everywhere else.
struct WidgetPreviewStyle: Equatable {
    var family: WidgetFamily
    var renderingMode: WidgetRenderingMode = .fullColor
}

extension EnvironmentValues {
    @Entry var widgetPreviewStyle: WidgetPreviewStyle? = nil
}
