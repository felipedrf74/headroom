import SwiftUI

struct WatchRootView: View {
    var store: WatchStore

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    WatchEmptyView(store: store)
                } else {
                    List {
                        ForEach(store.items) { item in
                            NavigationLink(value: item.id) {
                                WatchRow(item: item)
                            }
                        }
                        if store.cache?.isSample == true {
                            Text("Sample data from your iPhone")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else if let checked = store.cache?.checkedAt {
                            Text("Checked \(RelativeTime.ago(checked))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Tokenroom")
            .navigationDestination(for: String.self) { id in
                if let item = store.item(id: id) {
                    WatchDetailView(item: item)
                }
            }
        }
    }
}

private struct WatchEmptyView: View {
    var store: WatchStore

    var body: some View {
        if store.isRefreshing {
            ProgressView()
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    Image(systemName: store.failed ? "icloud.slash" : "gauge.with.dots.needle.50percent")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    Text(store.failed ? "Couldn't reach iCloud" : "No readings yet")
                        .font(.headline)
                    Text("Open Tokenroom on your iPhone or Mac. The Watch shows what they send through your iCloud.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }
}

private struct WatchRow: View {
    var item: ReadingCache.Item

    var body: some View {
        let provider = item.provider
        let window = provider.primaryWindow
        HStack(spacing: 10) {
            if let window, window.isMetered {
                UsageRing(used: window.used, isStale: !provider.isLive, label: provider.monogram)
                    .frame(width: 40, height: 40)
            } else {
                MonogramMark(provider: provider, size: 36)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(provider.shortName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text(ReadingText.headline(window))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(headlineColor(window, isLive: provider.isLive))
                }
                if let window {
                    Text(ReadingText.reset(window) ?? window.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .opacity(provider.isLive ? 1 : 0.7)
    }
}

struct WatchDetailView: View {
    var item: ReadingCache.Item

    var body: some View {
        let provider = item.provider
        List {
            if let plan = provider.plan {
                Text(plan)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(provider.windows) { window in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(window.title)
                            .font(.caption)
                        Spacer()
                        Text(ReadingText.headline(window))
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(headlineColor(window, isLive: provider.isLive))
                    }
                    if window.isMetered {
                        MeterTrack(usedPercent: window.used, remaining: 100 - window.used, isStale: !provider.isLive, height: 6)
                    }
                    if let resetsAt = window.resetsAt, resetsAt > .now {
                        Text("Resets in \(Text(resetsAt, style: .relative))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let pace = UsageRanking.pace(for: window, isStale: !provider.isLive, history: item.history[window.id]),
                       pace.verdict == .ahead || pace.verdict == .limitReached {
                        Text(pace.caption())
                            .font(.caption2)
                            .foregroundStyle(TokenroomTokens.tight)
                    }
                }
                .padding(.vertical, 2)
            }
            if let banked = provider.banked, banked.available > 0 {
                Text(ReadingText.banked(banked))
                    .font(.footnote)
            }
            if let extra = provider.extra, let text = ReadingText.extra(extra) {
                Text(text)
                    .font(.footnote)
            }
            Text("From \(item.source)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .navigationTitle(provider.shortName)
    }
}

/// A ring for one window: used percent in the usage gradient, the monogram in the middle.
struct UsageRing: View {
    var used: Double
    var isStale: Bool
    var label: String

    var body: some View {
        Gauge(value: min(max(used, 0), 100), in: 0...100) {
            Text(label)
        } currentValueLabel: {
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(isStale ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(Gradient(colors: [TokenroomTokens.usageHealthy, TokenroomTokens.usageWatch, TokenroomTokens.usageTight, TokenroomTokens.usageCritical])))
    }
}

private func headlineColor(_ window: RelayWindow?, isLive: Bool) -> Color {
    guard let window, window.isMetered else { return .primary }
    return TokenroomTokens.ink(remaining: 100 - window.used, isStale: !isLive)
}
