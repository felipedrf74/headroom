import UIKit
import UserNotifications

/// Registers for CloudKit pushes and reads the relay when a Mac publishes new readings. Owns the
/// app's stores, so a silent push that launches the app in the background, with no window, still
/// has one to refresh.
@MainActor
final class MobileAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let store = MobileStore()
    let news = NewsStore()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        WatchLink.shared.activate()
        return true
    }

    /// A silent push only means a Mac sent readings. iOS allows about 30 seconds; the answer goes
    /// back within 25 whatever iCloud does, and the refresh is cancelled then (its unfinished
    /// checks don't count). It says whether anything changed, which iOS weighs when it decides
    /// on later pushes.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        let store = self.store
        let changed = await TimeLimit.run(25, otherwise: false) { await store.refreshForPush() }
        return changed ? .newData : .noData
    }

    /// Alerts show as banners while the app is open too.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
