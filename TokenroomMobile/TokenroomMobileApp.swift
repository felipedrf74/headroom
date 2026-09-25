import SwiftUI
import UserNotifications

@main
struct TokenroomMobileApp: App {
    @UIApplicationDelegateAdaptor(MobileAppDelegate.self) private var appDelegate
    @State private var store = MobileStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            UsageListView(store: store)
                .task {
                    appDelegate.store = store
                    // Readings first; the permission prompt can wait for the person to answer.
                    await store.refresh()
                    await store.prepareNotifications()
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await store.refresh() }
                    }
                }
        }
    }
}
