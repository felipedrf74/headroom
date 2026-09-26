import SwiftUI

@main
struct TokenroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The status item and the one Settings window are AppKit, in AppDelegate. SwiftUI needs a
        // scene, and this one never opens: ⌘, and the app menu's Settings item go to AppKit's
        // window, so a second Settings window can't appear.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.openSettings()
                }
                .keyboardShortcut(",")
            }
        }
    }
}
