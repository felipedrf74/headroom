import SwiftUI
import UserNotifications

@main
struct TokenroomMobileApp: App {
    @UIApplicationDelegateAdaptor(MobileAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        let store = appDelegate.store
        let news = appDelegate.news
        WindowGroup {
            RootView(store: store, news: news)
                .task {
                    // Also saves the push subscriptions, once iCloud answers.
                    await store.refresh(force: true)
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        Task {
                            await store.refresh()
                            // Feeds older than an hour, so the News badge is current on open.
                            await news.refresh(maxAge: NewsFetcher.openInterval, preferences: store.alertPreferences)
                        }
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
