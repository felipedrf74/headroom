import SwiftUI

@main
struct TokenroomWatchApp: App {
    @State private var store = WatchStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchRootView(store: store)
                .onOpenURL { url in
                    // Complications and the Smart Stack link to a provider.
                    if case .provider(let id) = DeepLink(url) {
                        store.openedProvider = id
                    }
                }
                .task {
                    await store.refresh(force: true)
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        Task { await store.refresh() }
                    case .background:
                        store.scheduleBackgroundRefresh()
                    default:
                        break
                    }
                }
        }
        .backgroundTask(.appRefresh(WatchStore.backgroundTaskID)) {
            await store.refresh(force: true)
            await store.scheduleBackgroundRefresh()
        }
    }
}
