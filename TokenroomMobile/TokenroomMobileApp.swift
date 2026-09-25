import SwiftUI
import UserNotifications

@main
struct TokenroomMobileApp: App {
    @UIApplicationDelegateAdaptor(MobileAppDelegate.self) private var appDelegate
    @State private var store = MobileStore()
    @State private var news = NewsStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(store: store, news: news)
                .task {
                    appDelegate.store = store
                    await store.refresh(force: true)
                    await store.prepareNotifications()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        Task { await store.refresh() }
                    case .background:
                        Task { await store.scheduleBackgroundRefresh() }
                    default:
                        break
                    }
                }
                .onChange(of: store.hasOnboarded, initial: true) { _, onboarded in
                    // Ask once the person has chosen how to use Tokenroom, not on first sight.
                    guard onboarded, !store.sampleMode else { return }
                    Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
                }
        }
        .backgroundTask(.appRefresh(MobileStore.backgroundTaskID)) {
            await store.backgroundRefresh()
            await news.refresh(preferences: store.alertPreferences)
        }
    }
}
