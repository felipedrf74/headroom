import SwiftUI

@main
struct HeadroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Status item is created in AppDelegate. This scene only exists so
        // Settings can be opened from the popover.
        Settings {
            SettingsView(store: appDelegate.store)
                .frame(width: 400)
        }
        .windowResizability(.contentSize)
    }
}
