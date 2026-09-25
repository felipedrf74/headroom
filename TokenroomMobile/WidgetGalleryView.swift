#if DEBUG
import SwiftUI
import WidgetKit

/// Every widget size from the current readings, drawn in the app for screenshots and checks
/// without a Home Screen. Debug builds only: `-TokenroomGallery home` or `lock`.
struct WidgetGalleryView: View {
    var cache: ReadingCache
    var date: Date = .now

    private let homeSizes: [(family: WidgetFamily, size: CGSize)] = [
        (.systemSmall, CGSize(width: 170, height: 170)),
        (.systemMedium, CGSize(width: 364, height: 170)),
        (.systemLarge, CGSize(width: 364, height: 382)),
    ]
    private let lockSizes: [(family: WidgetFamily, size: CGSize)] = [
        (.accessoryCircular, CGSize(width: 76, height: 76)),
        (.accessoryRectangular, CGSize(width: 172, height: 76)),
        (.accessoryInline, CGSize(width: 250, height: 24)),
    ]

    /// `home` for the Home Screen sizes, `lock` for the Lock Screen and tinted ones.
    var page = "home"

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if page == "lock" {
                    HStack(spacing: 14) {
                        ForEach(lockSizes.prefix(2), id: \.family) { item in
                            widget(item.family, size: item.size, mode: .vibrant)
                        }
                    }
                    .padding(12)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .environment(\.colorScheme, .dark)
                    widget(.accessoryInline, size: CGSize(width: 250, height: 24), mode: .vibrant)
                        .environment(\.colorScheme, .dark)
                        .padding(8)
                        .background(.black.opacity(0.55), in: Capsule())
                    HStack(spacing: 14) {
                        widget(.systemSmall, size: CGSize(width: 170, height: 170), mode: .accented)
                            .background(.blue.opacity(0.25), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        widget(.systemSmall, size: CGSize(width: 170, height: 170), mode: .fullColor)
                            .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .environment(\.colorScheme, .dark)
                    }
                    widget(.systemMedium, size: CGSize(width: 364, height: 170), mode: .fullColor)
                        .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .environment(\.colorScheme, .dark)
                } else {
                    ForEach(homeSizes, id: \.family) { item in
                        widget(item.family, size: item.size, mode: .fullColor)
                            .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .background(Color.gray.opacity(0.25))
    }

    private func widget(_ family: WidgetFamily, size: CGSize, mode: WidgetRenderingMode) -> some View {
        UsageWidgetView(entry: ReadingsEntry.make(cache, choice: .automatic, date: date))
            .environment(\.widgetPreviewStyle, WidgetPreviewStyle(family: family, renderingMode: mode))
            .padding(family == .accessoryInline || family == .accessoryCircular || family == .accessoryRectangular ? 0 : 16)
            .frame(width: size.width, height: size.height)
    }
}
#endif
