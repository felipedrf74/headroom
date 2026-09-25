import CloudKit
import Foundation
import Observation
import os

/// Sends this Mac's readings to the user's iCloud so Tokenroom on iPhone and Apple Watch can show them.
/// Only percentages, reset times, labels, and plan names leave the Mac. Never tokens.
@Observable
@MainActor
final class RelayPublisher {
    enum State: Equatable {
        /// This copy isn't signed for iCloud (ad-hoc build).
        case unavailable
        case off
        case waiting
        case noAccount
        case sent(Date)
        case failed(String)
        case paused(String)
    }

    enum Keys {
        static let enabled = "relayEnabled"
        static let sourceID = "relaySourceID"
        static let label = "relayLabel"
    }

    static let minimumInterval = RelayPublishPolicy.minimumInterval

    private(set) var state: State
    var lastSent: Date? {
        policy.lastSent
    }

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.enabled)
            if !isEnabled {
                state = relay == nil ? .unavailable : .off
            } else if relay != nil, state == .off {
                state = .waiting
                policy.reset()
            }
        }
    }

    var label: String {
        didSet {
            defaults.set(label, forKey: Keys.label)
            policy.reset()
        }
    }

    let sourceID: String
    private let relay: CloudRelay?
    private let defaults: UserDefaults
    private var policy = RelayPublishPolicy()
    private var preferencesCache: (preferences: AlertPreferences, readAt: Date)?
    private var retryAt: Date?
    private var lastHistoryHour: Date?
    private var loggedAccount = false
    private let logger = Logger(subsystem: TokenroomIdentity.bundleID, category: "relay")

    init(defaults: UserDefaults = .standard, containerIdentifier: String? = RelayAvailability.containerIdentifier) {
        self.defaults = defaults
        if let existing = defaults.string(forKey: Keys.sourceID) {
            sourceID = existing
        } else {
            sourceID = "src-\(UUID().uuidString.lowercased())"
            defaults.set(sourceID, forKey: Keys.sourceID)
        }
        label = defaults.string(forKey: Keys.label) ?? "Mac"
        relay = containerIdentifier.map(CloudRelay.init(containerIdentifier:))
        let enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        isEnabled = enabled
        state = relay == nil ? .unavailable : (enabled ? .waiting : .off)
    }

    var isAvailable: Bool {
        relay != nil
    }

    /// Sends when usage changed materially (at most every 5 minutes), when a provider's status
    /// changed (after a minute), or every 30 minutes as a heartbeat.
    func publish(_ envelope: RelayEnvelope, force: Bool = false, now: Date = .now) async {
        guard let relay, isEnabled else { return }
        if let retryAt, retryAt > now, !force { return }
        guard policy.isDue(envelope, force: force, now: now) else { return }

        do {
            if case .noAccount = state {
                guard try await relay.accountStatus() == .available else { return }
            }
            try await relay.publish(sourceID: sourceID, kind: "mac", label: label, envelope: envelope)
            logger.notice("relay sent \(envelope.providers.count, privacy: .public) providers")
            if !loggedAccount, let fingerprint = try? await relay.accountFingerprint() {
                loggedAccount = true
                logger.notice("relay account \(fingerprint, privacy: .public)")
            }
            policy.didSend(envelope, at: now)
            retryAt = nil
            state = .sent(now)
        } catch {
            handle(error, now: now)
        }
    }

    /// Sends the week of hourly history once per hour.
    func publishHistory(_ history: RelayHistory, now: Date = .now) async {
        guard let relay, isEnabled, !history.series.isEmpty else { return }
        if let retryAt, retryAt > now { return }
        let hour = UsageHistory.hourStart(now)
        guard lastHistoryHour != hour else { return }
        do {
            try await relay.publishHistory(sourceID: sourceID, history: history)
            lastHistoryHour = hour
        } catch {
            handle(error, now: now)
        }
    }

    /// The iPhone's alert preferences, checked at most every half hour; defaults until it has set any.
    func alertPreferences(now: Date = .now) async -> AlertPreferences {
        if let cached = preferencesCache, now.timeIntervalSince(cached.readAt) < 30 * 60 {
            return cached.preferences
        }
        guard let relay, isEnabled, let preferences = try? await relay.alertPreferences() else {
            return preferencesCache?.preferences ?? AlertPreferences()
        }
        preferencesCache = (preferences, now)
        return preferences
    }

    /// Sends new alerts to the iPhone. Outside quiet hours, or urgent.
    func sendAlerts(_ alerts: [UsageAlert], preferences: AlertPreferences, now: Date = .now) async {
        guard let relay, isEnabled else { return }
        for alert in alerts where preferences.shouldSend(alert, at: now) {
            do {
                try await relay.saveAlert(alert)
                logger.notice("relay alert sent \(alert.kind.rawValue, privacy: .public) \(alert.level, privacy: .public)")
            } catch {
                handle(error, now: now)
                return
            }
        }
    }

    /// Creates an alert event the iPhone shows as a notification. Used by "Send Test Alert".
    func sendTestAlert(now: Date = .now) async {
        guard let relay, isEnabled else { return }
        do {
            try await relay.saveEvent(
                id: "evt-test-\(Int(now.timeIntervalSince1970))",
                provider: "tokenroom",
                level: 0,
                title: "Tokenroom",
                body: "Test alert from \(label). Usage alerts will look like this."
            )
            logger.notice("relay test alert sent")
        } catch {
            handle(error, now: now)
        }
    }

    private func handle(_ error: Error, now: Date) {
        logger.error("relay failed: \(String(describing: error), privacy: .public)")
        guard let error = error as? CKError else {
            state = .failed("Couldn't reach iCloud.")
            return
        }
        switch error.code {
        case .notAuthenticated:
            state = .noAccount
        case .userDeletedZone:
            state = .paused("Tokenroom's iCloud data was deleted. Turn sync off and on to start again.")
        case .quotaExceeded:
            state = .paused("Couldn't save: iCloud storage is full.")
        case .requestRateLimited, .zoneBusy, .serviceUnavailable:
            retryAt = now.addingTimeInterval(error.retryAfterSeconds ?? Self.minimumInterval)
            state = .failed("Couldn't reach iCloud. Trying again soon.")
        case .badContainer:
            // A newly created container takes a while to reach every CloudKit server.
            retryAt = now.addingTimeInterval(max(error.retryAfterSeconds ?? 0, Self.minimumInterval))
            state = .failed("Couldn't reach Tokenroom's iCloud container yet. Trying again soon.")
        case .missingEntitlement, .permissionFailure:
            state = .unavailable
        default:
            state = .failed("Couldn't reach iCloud.")
        }
    }

    var statusText: String {
        switch state {
        case .unavailable:
            "iPhone sync needs the signed download. This copy is signed on this Mac."
        case .off:
            "Off"
        case .waiting:
            "On · waiting for the first reading"
        case .noAccount:
            "Couldn't reach iCloud. Sign in to iCloud on this Mac."
        case .sent(let date):
            "On · sent \(RelativeTime.ago(date))"
        case .failed(let message), .paused(let message):
            message
        }
    }
}
