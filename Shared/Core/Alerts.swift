import Foundation

/// One usage alert. Every device computes the same ID for the same event, so when two collectors
/// see the same crossing, iCloud keeps one record and the iPhone shows one notification.
struct UsageAlert: Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        /// A window crossed 80% or 95%.
        case threshold
        /// A window that was at least 80% used has reset.
        case reset
        /// A banked reset became available.
        case bankedNew
        /// A banked reset expires soon.
        case bankedExpiring
    }

    var id: String
    var provider: String
    var kind: Kind
    /// The threshold for crossings (80, 95); hours left for expiring resets (48, 6); 0 otherwise.
    var level: Int
    var title: String
    var body: String
    var resetsAt: Date?
    /// Worth interrupting quiet hours for: 95% and above, or a reset expiring within 6 hours.
    var isUrgent: Bool
}

/// The iPhone owns these; Macs read them from iCloud before sending alerts.
struct AlertPreferences: Codable, Equatable, Sendable {
    var thresholds: [Int] = [80, 95]
    var resets = true
    var banked = true
    /// New models from the labs the News tab follows (iPhone only).
    var newModels = true
    var quietHours = true
    var quietStartHour = 22
    var quietEndHour = 8
    /// The iPhone's time zone, so a Mac elsewhere keeps the same quiet hours.
    var timeZoneID = TimeZone.current.identifier

    static let supportedThresholds = [80, 95]

    init() {}

    /// Missing keys keep their defaults, so preferences saved by an older build still read.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AlertPreferences()
        thresholds = try container.decodeIfPresent([Int].self, forKey: .thresholds) ?? defaults.thresholds
        resets = try container.decodeIfPresent(Bool.self, forKey: .resets) ?? defaults.resets
        banked = try container.decodeIfPresent(Bool.self, forKey: .banked) ?? defaults.banked
        newModels = try container.decodeIfPresent(Bool.self, forKey: .newModels) ?? defaults.newModels
        quietHours = try container.decodeIfPresent(Bool.self, forKey: .quietHours) ?? defaults.quietHours
        quietStartHour = try container.decodeIfPresent(Int.self, forKey: .quietStartHour) ?? defaults.quietStartHour
        quietEndHour = try container.decodeIfPresent(Int.self, forKey: .quietEndHour) ?? defaults.quietEndHour
        timeZoneID = try container.decodeIfPresent(String.self, forKey: .timeZoneID) ?? defaults.timeZoneID
    }

    /// When quiet hours next end after `date`, for holding back a notification that can wait.
    func quietEnd(after date: Date) -> Date? {
        guard isQuiet(at: date) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        return calendar.nextDate(after: date, matching: DateComponents(hour: quietEndHour, minute: 0), matchingPolicy: .nextTime)
    }

    /// Whether `date` falls in quiet hours, which can run past midnight (22:00–08:00).
    func isQuiet(at date: Date) -> Bool {
        guard quietHours, quietStartHour != quietEndHour else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        let hour = calendar.component(.hour, from: date)
        return quietStartHour < quietEndHour
            ? (quietStartHour..<quietEndHour).contains(hour)
            : hour >= quietStartHour || hour < quietEndHour
    }

    /// Alerts to send now: urgent ones always, the rest outside quiet hours.
    func shouldSend(_ alert: UsageAlert, at date: Date) -> Bool {
        alert.isUrgent || !isQuiet(at: date)
    }
}

enum AlertRules {
    /// A reset is worth a "fresh headroom" alert only after heavy use.
    static let resetWorthyUse = 80.0
    /// Readings of the same window instance can report slightly different reset times.
    static let resetJitter: TimeInterval = 30 * 60

    /// Alerts raised going from `previous` to `current` for one provider. A provider seen for the
    /// first time raises nothing, so installing or restarting never floods notifications.
    static func alerts(previous: RelayProvider?, current: RelayProvider, preferences: AlertPreferences, now: Date = .now) -> [UsageAlert] {
        guard let previous, current.isLive else { return [] }
        var alerts: [UsageAlert] = []
        for window in current.windows where window.isMetered {
            guard let before = previous.windows.first(where: { $0.id == window.id }) else { continue }
            let sameInstance = isSameInstance(before.resetsAt, window.resetsAt)
            // Only the highest threshold crossed in one step.
            let crossed = preferences.thresholds.sorted(by: >).first { level in
                window.used >= Double(level) && (!sameInstance || before.used < Double(level))
            }
            if let level = crossed {
                alerts.append(threshold(current, window: window, level: level, now: now))
            }
            if preferences.resets, !sameInstance, before.used >= resetWorthyUse, let oldReset = before.resetsAt, oldReset <= now.addingTimeInterval(resetJitter) {
                alerts.append(UsageAlert(
                    id: "evt-\(current.id)-\(window.id)-reset-\(instance(oldReset))",
                    provider: current.id,
                    kind: .reset,
                    level: 0,
                    title: "\(current.name): \(window.title) reset",
                    body: "Fresh headroom. It was at \(TokenroomFormat.percentText(before.used))% before the reset.",
                    resetsAt: window.resetsAt,
                    isUrgent: false
                ))
            }
        }
        if preferences.banked, let banked = current.banked {
            let before = previous.banked?.available ?? 0
            if banked.available > before {
                let next = banked.nextExpiry(after: now)
                alerts.append(UsageAlert(
                    id: "evt-\(current.id)-banked-\(banked.available)-\(instance(next))",
                    provider: current.id,
                    kind: .bankedNew,
                    level: 0,
                    title: "\(current.name): banked reset available",
                    body: banked.available == 1 ? "You have 1 to use when a limit runs out." : "You have \(banked.available) to use when a limit runs out.",
                    resetsAt: next,
                    isUrgent: false
                ))
            }
            if let expiry = banked.nextExpiry(after: now) {
                let left = expiry.timeIntervalSince(now)
                for hours in [6, 48] where left <= Double(hours) * 3600 {
                    alerts.append(UsageAlert(
                        id: "evt-\(current.id)-banked-expiry-\(hours)-\(instance(expiry))",
                        provider: current.id,
                        kind: .bankedExpiring,
                        level: hours,
                        title: "\(current.name): banked reset expires soon",
                        body: "Use it by \(expiry.formatted(.dateTime.weekday(.abbreviated).hour().minute())), or it's gone.",
                        resetsAt: expiry,
                        isUrgent: hours <= 6
                    ))
                    break
                }
            }
        }
        return alerts
    }

    private static func threshold(_ provider: RelayProvider, window: RelayWindow, level: Int, now: Date) -> UsageAlert {
        let reset = window.resetsAt.flatMap { RelativeTime.resets($0, now: now) }.map { $0.prefix(1).uppercased() + $0.dropFirst() + "." }
        return UsageAlert(
            id: "evt-\(provider.id)-\(window.id)-\(level)-\(instance(window.resetsAt))",
            provider: provider.id,
            kind: .threshold,
            level: level,
            title: "\(provider.name): \(level)% of \(window.title.lowercased()) used",
            body: reset ?? "It resets when \(provider.name) says so.",
            resetsAt: window.resetsAt,
            isUrgent: level >= 95
        )
    }

    /// A window instance, named by its reset time to the nearest 10 minutes.
    static func instance(_ resetsAt: Date?) -> String {
        resetsAt.map { String(Int(($0.timeIntervalSince1970 / 600).rounded())) } ?? "open"
    }

    static func isSameInstance(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return abs(lhs.timeIntervalSince(rhs)) < resetJitter
        default:
            return false
        }
    }
}

/// What this device last saw and already sent, so each alert goes out once. Kept next to the
/// readings cache; percentages and IDs only.
struct AlertLedger: Codable, Equatable, Sendable {
    /// The last reading per provider, for spotting crossings.
    var lastSeen: [String: RelayProvider] = [:]
    /// Alert IDs already sent, with when, pruned after two weeks.
    var sent: [String: Date] = [:]

    static let memory: TimeInterval = 14 * 86_400
    static let fileName = "alerts.json"

    /// New alerts for these readings, recorded as seen and sent. Readings that aren't live
    /// (stale, expired) don't move `lastSeen`, so a crossing is judged against the last real one.
    mutating func process(_ providers: [RelayProvider], preferences: AlertPreferences, now: Date = .now) -> [UsageAlert] {
        var fresh: [UsageAlert] = []
        for provider in providers where provider.isLive {
            for alert in AlertRules.alerts(previous: lastSeen[provider.id], current: provider, preferences: preferences, now: now)
            where sent[alert.id] == nil && !fresh.contains(where: { $0.id == alert.id }) {
                sent[alert.id] = now
                fresh.append(alert)
            }
            lastSeen[provider.id] = provider
        }
        sent = sent.filter { now.timeIntervalSince($0.value) < Self.memory }
        return fresh
    }

    static func load(from directory: URL?) -> AlertLedger {
        guard let url = directory?.appendingPathComponent(fileName),
              let data = try? Data(contentsOf: url),
              let ledger = try? RelayEnvelope.decoder.decode(AlertLedger.self, from: data)
        else { return AlertLedger() }
        return ledger
    }

    func save(to directory: URL?) {
        guard let url = directory?.appendingPathComponent(Self.fileName),
              let data = try? RelayEnvelope.encoder.encode(self)
        else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
