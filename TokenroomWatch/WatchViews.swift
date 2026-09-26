import SwiftUI

struct WatchRootView: View {
    var store: WatchStore
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
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
                            Text("Sample data")
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
        .onOpenURL { url in
            // Complications and the Smart Stack link to a provider; the rest open the list.
            if case .provider(let id) = DeepLink(url) {
                store.openedProvider = id
            } else {
                store.openedProvider = nil
                path = []
            }
        }
        // Opened from a complication or the Smart Stack; if the readings aren't in yet, once they are.
        .onChange(of: store.openedProvider, initial: true) { _, _ in openRequestedProvider() }
        .onChange(of: store.items.map(\.id)) { _, _ in openRequestedProvider() }
    }

    private func openRequestedProvider() {
        guard let id = store.openedProvider, store.item(id: id) != nil else { return }
        path = [id]
        store.openedProvider = nil
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
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(.tint)
                    Text(title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private var symbol: String {
        switch store.problem {
        case .noAccount: "person.crop.circle.badge.questionmark"
        case .unreachable: "icloud.slash"
        case nil: "gauge.with.dots.needle.50percent"
        }
    }

    private var title: String {
        switch store.problem {
        case .noAccount: "Sign in to iCloud"
        case .unreachable: "Couldn't reach iCloud"
        case nil: "No readings yet"
        }
    }

    private var message: String {
        switch store.problem {
        case .noAccount: "Use the same Apple Account on this Watch as on your iPhone and Mac."
        case .unreachable: "The Watch shows what your iPhone and Mac send through iCloud. It tries again soon."
        case nil: "Open Tokenroom on your iPhone or Mac. The Watch shows what they send through your iCloud."
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
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 2)
                    Text(ReadingText.headline(window))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(headlineColor(window, isLive: provider.isLive))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
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
        .accessibilityElement(children: .combine)
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
                let pace = window.isMetered ? UsageRanking.pace(for: window, isStale: !provider.isLive, history: item.history[window.id]) : nil
                WindowRow(
                    title: window.title,
                    headline: ReadingText.headline(window),
                    usedPercent: window.isMetered ? window.used : nil,
                    isStale: !provider.isLive,
                    paceMark: pace?.elapsedFraction,
                    caption: detail(window, pace: pace),
                    titleFont: .caption,
                    captionFont: .caption2
                )
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

    /// "resets in 2h 10m · Ahead of pace".
    private func detail(_ window: RelayWindow, pace: Pace?) -> String? {
        var parts: [String] = []
        if let reset = ReadingText.reset(window) {
            parts.append(reset)
        }
        if let pace, pace.needsAttention {
            parts.append(pace.caption())
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private func headlineColor(_ window: RelayWindow?, isLive: Bool) -> Color {
    guard let window, window.isMetered else { return .primary }
    return TokenroomTokens.ink(remaining: 100 - window.used, isStale: !isLive)
}
