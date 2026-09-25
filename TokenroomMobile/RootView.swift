import SwiftUI

enum AppTab: Hashable {
    case usage
    case news
    case settings
}

struct RootView: View {
    @Bindable var store: MobileStore
    @Bindable var news: NewsStore
    @State private var showsOnboarding = false
    @State private var tab: AppTab = .usage
    @State private var usagePath: [String] = []
    @State private var settingsPath: [SettingsRoute] = []

    var body: some View {
        #if DEBUG
        if let page = UserDefaults.standard.string(forKey: "TokenroomGallery") {
            WidgetGalleryView(cache: ReadingCache.defaultURL.flatMap(ReadingCache.load) ?? SampleData.cache(), page: page)
        } else {
            tabs
        }
        #else
        tabs
        #endif
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            Tab("Usage", systemImage: "gauge.with.dots.needle.50percent", value: .usage) {
                UsageView(store: store, path: $usagePath)
            }
            Tab("News", systemImage: "newspaper", value: .news) {
                NewsView(news: news, store: store)
            }
            Tab("Settings", systemImage: "gearshape", value: .settings) {
                MobileSettingsView(store: store, path: $settingsPath)
            }
        }
        .sheet(isPresented: $showsOnboarding, onDismiss: { store.hasOnboarded = true }) {
            OnboardingView(store: store)
        }
        .onAppear {
            showsOnboarding = !store.hasOnboarded
            #if DEBUG
            // Screenshots and simulator checks: `-TokenroomOpen tokenroom://provider/claude`.
            if let link = UserDefaults.standard.string(forKey: "TokenroomOpen").flatMap(URL.init(string:)) {
                open(link)
            }
            // `-TokenroomFollow claude` starts that provider's Live Activity, for checks.
            if let id = UserDefaults.standard.string(forKey: "TokenroomFollow") {
                let provider = store.reading(id: id)?.provider
                let window = provider.flatMap { LiveActivities.candidate(in: $0) }
                do {
                    let started = try provider.flatMap { provider in try window.map { try LiveActivities.start(provider, window: $0) } }
                    NSLog("%@", "TokenroomFollow \(id): enabled=\(LiveActivities.isEnabled) window=\(window?.id ?? "none") started=\(String(describing: started))")
                } catch {
                    NSLog("%@", "TokenroomFollow \(id): \(error)")
                }
            }
            #endif
        }
        .onOpenURL(perform: open)
    }

    private func open(_ url: URL) {
        guard let link = DeepLink(url) else { return }
        showsOnboarding = false
        switch link {
        case .provider(let id):
            tab = .usage
            usagePath = [id]
        case .news:
            tab = .news
        case .settings:
            tab = .settings
            settingsPath = []
        case .keys:
            tab = .settings
            settingsPath = [.keys]
        }
    }
}
