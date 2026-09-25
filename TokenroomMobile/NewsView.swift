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
            .onAppear {
                // Clears the tab's badge; this visit's new items stay marked.
                news.markSeen()
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
                    ModelReleaseRow(release: release, isNew: news.isNew(release.created))
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
                    ModelReleaseRow(release: release)
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
                    AnnouncementRow(item: item, isNew: news.isNew(item.published))
                }
            } footer: {
                Text("From each provider's official changelog or blog.")
            }
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
                ForEach(FeedSource.toggles) { source in
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
