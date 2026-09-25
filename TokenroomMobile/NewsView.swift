import SwiftUI

struct NewsView: View {
    @Bindable var news: NewsStore
    @Bindable var store: MobileStore
    @AppStorage("newsSection") private var section: NewsSection = .models
    @State private var showsAllLabs = false

    enum NewsSection: String, CaseIterable, Identifiable {
        case models = "Models"
        case announcements = "Announcements"

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Show", selection: $section) {
                    ForEach(NewsSection.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                switch section {
                case .models:
                    modelSections
                case .announcements:
                    announcementSection
                }
            }
            .navigationTitle("News")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        NewsSettingsView(news: news, store: store)
                    } label: {
                        Label("Follow", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .refreshable {
                await news.refresh(maxAge: 0, preferences: store.alertPreferences)
            }
            .task {
                await news.refresh(maxAge: NewsFetcher.openInterval, preferences: store.alertPreferences)
            }
            .overlay {
                if isEmpty {
                    if news.isRefreshing {
                        ProgressView()
                    } else {
                        ContentUnavailableView("Nothing yet", systemImage: "newspaper", description: Text("Pull down to check for news."))
                    }
                }
            }
        }
    }

    private var isEmpty: Bool {
        switch section {
        case .models: news.models(all: showsAllLabs).isEmpty
        case .announcements: news.announcements.isEmpty
        }
    }

    @ViewBuilder
    private var modelSections: some View {
        let models = news.models(all: showsAllLabs)
        if !models.isEmpty {
            Section {
                ForEach(models.prefix(50)) { release in
                    ModelRow(release: release)
                }
            } header: {
                HStack {
                    Text(showsAllLabs ? "All labs" : "Labs you follow")
                    Spacer()
                    Button(showsAllLabs ? "Followed" : "All") { showsAllLabs.toggle() }
                        .font(.caption.weight(.semibold))
                        .textCase(nil)
                }
            } footer: {
                Text("From OpenRouter's public model list.")
            }
        }
        let retiring = news.retiring
        if !retiring.isEmpty {
            Section("Retiring") {
                ForEach(retiring) { release in
                    ModelRow(release: release)
                }
            }
        }
    }

    @ViewBuilder
    private var announcementSection: some View {
        let items = news.announcements
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    AnnouncementRow(item: item)
                }
            } footer: {
                Text("From each provider's official changelog or blog.")
            }
        }
    }
}

private struct ModelRow: View {
    var release: ModelRelease

    var body: some View {
        let row = VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(release.vendorName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let expires = release.expires, expires > .now {
                    Text("Retires \(expires.formatted(.dateTime.month(.abbreviated).day()))")
                        .font(.caption)
                        .foregroundStyle(TokenroomTokens.tight)
                } else {
                    Text(release.created.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(release.shortName)
                .font(.headline)
                .foregroundStyle(.primary)
            if let details {
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        if let link = release.link {
            // Links tint their labels; rows keep their own colors.
            Link(destination: link) { row }
                .foregroundStyle(.primary)
        } else {
            row
        }
    }

    /// "1M context · $4 in, $20 out per million tokens".
    private var details: String? {
        var parts: [String] = []
        if let context = release.contextLength, context > 0 {
            parts.append("\(context.formatted(.number.notation(.compactName))) context")
        }
        if let prompt = release.promptPrice, let completion = release.completionPrice {
            if prompt == 0, completion == 0 {
                parts.append("Free")
            } else {
                parts.append("\(Self.price(prompt)) in, \(Self.price(completion)) out per million tokens")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "$4", "$0.10", "$0.075".
    static func price(_ value: Double) -> String {
        // Per-token prices times a million carry float noise: 0.1 arrives as 0.0999….
        let value = (value * 1000).rounded() / 1000
        let digits = value == value.rounded() ? 0 : (value < 0.1 ? 3 : 2)
        return value.formatted(.currency(code: "USD").precision(.fractionLength(digits)))
    }
}

private struct AnnouncementRow: View {
    var item: FeedItem

    var body: some View {
        let row = VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(item.source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let published = item.published {
                    Text(RelativeTime.ago(published))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(item.title)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
        if let link = item.link {
            Link(destination: link) { row }
                .foregroundStyle(.primary)
        } else {
            row
        }
    }
}

struct NewsSettingsView: View {
    @Bindable var news: NewsStore
    @Bindable var store: MobileStore

    var body: some View {
        Form {
            Section {
                Toggle("Notify me about new models", isOn: $store.alertPreferences.newModels)
            } footer: {
                Text("One notification per batch, from the labs you follow, held until quiet hours end.")
            }
            Section("Labs") {
                ForEach(news.vendorChoices, id: \.id) { vendor in
                    Toggle(vendor.name, isOn: Binding(
                        get: { news.followedVendors.contains(vendor.id) },
                        set: { isOn in
                            if isOn { news.followedVendors.insert(vendor.id) } else { news.followedVendors.remove(vendor.id) }
                        }
                    ))
                }
            }
            Section {
                ForEach(FeedSource.catalog) { source in
                    Toggle(source.name, isOn: Binding(
                        get: { news.followedSources.contains(source.id) },
                        set: { isOn in
                            if isOn { news.followedSources.insert(source.id) } else { news.followedSources.remove(source.id) }
                        }
                    ))
                }
            } header: {
                Text("Announcements")
            } footer: {
                Text("Official changelogs and blogs only. Tokenroom shows titles and links, and opens the rest in Safari.")
            }
        }
        .navigationTitle("Follow")
        .navigationBarTitleDisplayMode(.inline)
    }
}
