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

    /// The newer of this Mac's alert preferences and the copy in iCloud, which either device may
    /// have changed. iCloud is checked at most every half hour.
    func alertPreferences(local: AlertPreferences, now: Date = .now) async -> AlertPreferences {
        if let cached = preferencesCache, now.timeIntervalSince(cached.readAt) < 30 * 60 {
            return AlertPreferences.newest(cached.preferences, local)
        }
        guard let relay, isEnabled, let remote = try? await relay.alertPreferences() else {
            return AlertPreferences.newest(preferencesCache?.preferences, local)
        }
        preferencesCache = (remote, now)
        return AlertPreferences.newest(remote, local)
    }

    /// Shares preferences changed on this Mac.
    func publishAlertPreferences(_ preferences: AlertPreferences, now: Date = .now) async {
        preferencesCache = (preferences, now)
        guard let relay, isEnabled else { return }
        do {
            try await relay.publishAlertPreferences(preferences)
        } catch {
            handle(error, now: now)
        }
    }

    /// Sends alerts to the iPhone; returns the IDs iCloud saved. The rest stay queued.
    func sendAlerts(_ alerts: [UsageAlert], now: Date = .now) async -> [String] {
        guard let relay, isEnabled else { return [] }
        if let retryAt, retryAt > now { return [] }
        var saved: [String] = []
        for alert in alerts {
            do {
                try await relay.saveAlert(alert)
                saved.append(alert.id)
                logger.notice("relay alert sent \(alert.kind.rawValue, privacy: .public) \(alert.level, privacy: .public)")
            } catch {
                if handle(error, now: now).stopsBatch { break }
            }
        }
        return saved
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

    @discardableResult
    private func handle(_ error: Error, now: Date) -> RelayErrorPolicy.Outcome {
        logger.error("relay failed: \(String(describing: error), privacy: .public)")
        let outcome = RelayErrorPolicy.outcome(for: error, defaultRetry: Self.minimumInterval)
        switch outcome {
        case .noAccount:
            state = .noAccount
        case .paused(let message):
            state = .paused(message)
        case .retry(let after, let message):
            retryAt = now.addingTimeInterval(after)
            state = .failed(message)
        case .unavailable:
            state = .unavailable
        case .cancelled:
            break
        case .failed(let message):
            state = .failed(message)
        }
        return outcome
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
