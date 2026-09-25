import SwiftUI

enum AppTab: Hashable {
    case usage
    case settings
}

struct RootView: View {
    @Bindable var store: MobileStore
    @State private var showsOnboarding = false
    @State private var tab: AppTab = .usage
    @State private var usagePath: [String] = []
    @State private var settingsPath: [SettingsRoute] = []

    var body: some View {
        TabView(selection: $tab) {
            Tab("Usage", systemImage: "gauge.with.dots.needle.50percent", value: .usage) {
                UsageView(store: store, path: $usagePath)
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
        case .settings:
            tab = .settings
            settingsPath = []
        case .keys:
            tab = .settings
            settingsPath = [.keys]
        }
    }
}
