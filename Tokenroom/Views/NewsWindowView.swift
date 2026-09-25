import SwiftUI

enum NewsSection: String, CaseIterable, Identifiable {
    case models = "Models"
    case announcements = "Announcements"

    var id: String { rawValue }

    static let defaultsKey = "macNewsSection"
}

/// The Mac's News window: new models from followed labs, and official announcements. Off until
/// turned on, since it's the one thing the Mac fetches that isn't your own usage.
struct NewsWindowView: View {
    @Bindable var store: QuotaStore
    var onOpenSettings: () -> Void
    @AppStorage(NewsSection.defaultsKey) private var section: NewsSection = .models
    @State private var showsAllLabs = false

    var body: some View {
        Group {
            if store.settings.newsEnabled, let news = store.news {
                content(news)
            } else {
                optIn
            }
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 520, idealHeight: 640)
    }

    private var optIn: some View {
        VStack(spacing: 14) {
            Image(systemName: "newspaper")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("News")
                .font(.title2.weight(.semibold))
            Text("New models from the labs you follow, and official changelogs and blogs from the tools you use. Tokenroom reads OpenRouter's public model list and each provider's own feed. Nothing about you or your usage is sent.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
            Button("Turn On News") {
                store.settings.newsEnabled = true
                Task { await store.refreshNews(force: true) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(_ news: NewsStore) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Show", selection: $section) {
                    ForEach(NewsSection.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                Spacer()
                if news.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    Task { await store.refreshNews(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(news.isRefreshing)
                .help("Check now")
                .accessibilityLabel("Check now")
                Button("Follow…", action: onOpenSettings)
                    .buttonStyle(.borderless)
                    .help("Choose labs and feeds")
            }
            .padding(12)
            Divider()
            List {
                switch section {
                case .models:
                    modelSections(news)
                case .announcements:
                    announcementSection(news)
                }
            }
            .listStyle(.inset)
            .overlay {
                if isEmpty(news) {
                    if news.isRefreshing {
                        ProgressView()
                    } else {
                        ContentUnavailableView("Nothing yet", systemImage: "newspaper", description: Text("Tokenroom checks for news every few hours."))
                    }
                }
            }
        }
    }

    private func isEmpty(_ news: NewsStore) -> Bool {
        switch section {
        case .models: news.models(all: showsAllLabs).isEmpty
        case .announcements: news.announcements.isEmpty
        }
    }

    @ViewBuilder
    private func modelSections(_ news: NewsStore) -> some View {
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
                    Button(showsAllLabs ? "Followed only" : "Show all") { showsAllLabs.toggle() }
                        .buttonStyle(.borderless)
                        .font(.caption.weight(.semibold))
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
    private func announcementSection(_ news: NewsStore) -> some View {
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
