import SwiftUI

@main
struct TokenroomWatchApp: App {
    @State private var store = WatchStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchRootView(store: store)
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
            // The next one first, so a refresh that runs out of time doesn't end them.
            await store.scheduleBackgroundRefresh()
            await store.refresh(force: true)
        }
    }
}
