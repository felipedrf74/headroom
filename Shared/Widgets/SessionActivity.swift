import ActivityKit
import AppIntents
import Foundation

/// A Live Activity that follows one window to its reset.
struct SessionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var used: Double
        var resetsAt: Date
        var isStale: Bool
    }

    var providerID: String
    var providerName: String
    var shortName: String
    var monogram: String
    var tint: String
    var windowID: String
    var windowTitle: String
}

/// Starting, updating, and ending the usage Live Activities. Starting only works in the app
/// (and intents it runs); updates arrive whenever the app refreshes.
enum LiveActivities {
    /// How long an ended activity stays on the Lock Screen.
    static let lingering: TimeInterval = 15 * 60

    static func candidate(in provider: RelayProvider, now: Date = .now) -> RelayWindow? {
        provider.windowToFollow(now: now)
    }

    static var isEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    static func activity(for providerID: String) -> Activity<SessionActivityAttributes>? {
        Activity<SessionActivityAttributes>.activities.first { $0.attributes.providerID == providerID && $0.activityState == .active }
    }

    /// One activity per provider; following it again keeps the one there is.
    @discardableResult
    static func start(_ provider: RelayProvider, window: RelayWindow) throws -> Bool {
        guard isEnabled, let resetsAt = window.resetsAt else { return false }
        if activity(for: provider.id) != nil { return true }
        let attributes = SessionActivityAttributes(
            providerID: provider.id,
            providerName: provider.name,
            shortName: provider.shortName,
            monogram: provider.monogram,
            tint: provider.tint,
            windowID: window.id,
            windowTitle: window.title
        )
        let state = SessionActivityAttributes.ContentState(used: window.used, resetsAt: resetsAt, isStale: !provider.isLive)
        _ = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: resetsAt, relevanceScore: window.used), pushType: nil)
        return true
    }

    /// Follows the most urgent window that qualifies, from the readings saved for widgets.
    static func startMostUrgent(now: Date = .now) throws -> Bool {
        let items = ReadingCache.defaultURL.flatMap(ReadingCache.load)?.items ?? []
        for item in items {
            if let window = candidate(in: item.provider, now: now) {
                return try start(item.provider, window: window)
            }
        }
        return false
    }

    /// Moves each activity to the latest reading, with an alert as it crosses 80% and 95%, and
    /// ends the ones whose window has reset.
    static func update(with providers: [RelayProvider], now: Date = .now) async {
        for activity in Activity<SessionActivityAttributes>.activities where activity.activityState == .active {
            let old = activity.content.state
            let provider = providers.first { $0.id == activity.attributes.providerID }
            let window = provider?.windows.first { $0.id == activity.attributes.windowID }
            guard let provider, let window, let resetsAt = window.resetsAt, AlertRules.isSameInstance(resetsAt, old.resetsAt) else {
                // A new window, or past the reset with nothing newer: done.
                if old.resetsAt <= now || window?.resetsAt != nil {
                    let final = SessionActivityAttributes.ContentState(used: 0, resetsAt: old.resetsAt, isStale: false)
                    await activity.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .after(now.addingTimeInterval(lingering)))
                }
                continue
            }
            let state = SessionActivityAttributes.ContentState(used: window.used, resetsAt: resetsAt, isStale: !provider.isLive)
            guard state != old else { continue }
            let crossed = [95, 80].first { old.used < Double($0) && window.used >= Double($0) }
            let alert = crossed.map { level in
                AlertConfiguration(
                    title: "\(provider.name): \(level)% used",
                    body: "\(window.title) \(RelativeTime.resets(resetsAt, now: now) ?? "resets soon").",
                    sound: .default
                )
            }
            await activity.update(ActivityContent(state: state, staleDate: resetsAt, relevanceScore: window.used), alertConfiguration: alert)
        }
    }

    static func stop(_ providerID: String) async {
        for activity in Activity<SessionActivityAttributes>.activities where activity.attributes.providerID == providerID {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

/// For Shortcuts, the Action button, and the Control Center control.
struct FollowUsageIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Follow Usage on Lock Screen"
    static let description = IntentDescription("Shows your most urgent limit that resets within 8 hours on the Lock Screen and in the Dynamic Island, until it resets.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let started = try LiveActivities.startMostUrgent()
        return .result(dialog: started ? "Following it until it resets." : "Nothing resets within 8 hours right now.")
    }
}
