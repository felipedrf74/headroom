import AppIntents

/// Siri, Spotlight, and the Shortcuts app offer this without any setup.
struct TokenroomShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: FollowUsageIntent(),
            phrases: [
                "Follow usage in \(.applicationName)",
                "Follow my limit in \(.applicationName)",
            ],
            shortTitle: "Follow Usage",
            systemImageName: "timer"
        )
    }
}
