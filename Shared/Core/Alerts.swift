import Foundation

/// One usage alert. Every device computes the same ID for the same event, so when two collectors
/// see the same crossing, iCloud keeps one record and the iPhone shows one notification.
struct UsageAlert: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        /// A window crossed 80% or 95%.
        case threshold
        /// A window that was at least 80% used has reset.
        case reset
        /// A banked reset became available.
        case bankedNew
        /// A banked reset expires soon.
        case bankedExpiring
        /// A balance or a spend budget crossed 80% or 95% of its reference.
        case lowBalance
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

    /// The key on the record of an alert an iPhone showed itself. No subscription lists it, so
    /// the record never comes back to it as a push.
    var shownKey: String {
        "shown:" + key
    }

    /// What the iPhone's subscription filters on: `threshold-80`, `reset`, `bankedExpiring-48`.
    var key: String {
        switch kind {
        case .threshold, .lowBalance, .bankedExpiring:
            "\(kind.rawValue)-\(level)"
        case .reset, .bankedNew:
            kind.rawValue
        }
    }
}

/// Shared by the iPhone and the Mac through iCloud; whichever changed them last wins.
struct AlertPreferences: Codable, Equatable, Sendable {
    var thresholds: [Int] = [80, 95]
    var resets = true
    var banked = true
    /// Balances and spend budgets crossing 80% or 95% of the reference the user set.
    var lowBalance = true
    /// New models from the labs News follows.
    var newModels = true
    var quietHours = true
    var quietStartHour = 22
    var quietEndHour = 8
    /// The time zone of the device that last changed them, so a Mac elsewhere keeps the same quiet hours.
    var timeZoneID = TimeZone.current.identifier
    /// When they were last changed, on either device.
    var updatedAt: Date? = nil

    static let supportedThresholds = [80, 95]

    init() {}

    /// Missing keys keep their defaults, so preferences saved by an older build still read.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AlertPreferences()
        thresholds = try container.decodeIfPresent([Int].self, forKey: .thresholds) ?? defaults.thresholds
        resets = try container.decodeIfPresent(Bool.self, forKey: .resets) ?? defaults.resets
        banked = try container.decodeIfPresent(Bool.self, forKey: .banked) ?? defaults.banked
        lowBalance = try container.decodeIfPresent(Bool.self, forKey: .lowBalance) ?? defaults.lowBalance
        newModels = try container.decodeIfPresent(Bool.self, forKey: .newModels) ?? defaults.newModels
        quietHours = try container.decodeIfPresent(Bool.self, forKey: .quietHours) ?? defaults.quietHours
        quietStartHour = try container.decodeIfPresent(Int.self, forKey: .quietStartHour) ?? defaults.quietStartHour
        quietEndHour = try container.decodeIfPresent(Int.self, forKey: .quietEndHour) ?? defaults.quietEndHour
        timeZoneID = try container.decodeIfPresent(String.self, forKey: .timeZoneID) ?? defaults.timeZoneID
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    /// Marks a change made on this device.
    mutating func touch(now: Date = .now, timeZone: TimeZone = .current) {
        updatedAt = now
        timeZoneID = timeZone.identifier
    }

    /// The copy changed last; on a tie (two copies never changed), the first, the shared copy,
    /// so a Mac keeps following an iPhone that set choices before they were dated.
    static func newest(_ shared: AlertPreferences?, _ local: AlertPreferences) -> AlertPreferences {
        guard let shared else { return local }
        return (shared.updatedAt ?? .distantPast) >= (local.updatedAt ?? .distantPast) ? shared : local
    }

    /// Kinds the iPhone's alert subscription lets through, as `UsageAlert.key` values.
    var subscribedKeys: [String] {
        var keys: [String] = []
        for level in Self.supportedThresholds where thresholds.contains(level) {
            keys.append("threshold-\(level)")
            if lowBalance {
                keys.append("lowBalance-\(level)")
            }
        }
        if resets {
            keys.append("reset")
        }
        if banked {
            keys += ["bankedNew", "bankedExpiring-48", "bankedExpiring-6"]
        }
        keys.append("test")
        return keys
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
            let isMoney = isMoneyWindow(window)
            // Only the highest threshold crossed in one step.
            let crossed = preferences.thresholds.sorted(by: >).first { level in
                window.used >= Double(level) && (!sameInstance || before.used < Double(level))
            }
            if let level = crossed {
                if !isMoney {
                    alerts.append(threshold(current, window: window, level: level, now: now))
                } else if preferences.lowBalance {
                    alerts.append(lowBalance(current, window: window, level: level, now: now))
                }
            }
            if preferences.resets, !isMoney, !sameInstance, before.used >= resetWorthyUse, let oldReset = before.resetsAt, oldReset <= now.addingTimeInterval(resetJitter) {
                alerts.append(UsageAlert(
                    id: "evt-\(current.id)-\(window.id)-reset-\(instance(oldReset, window: before, now: now))",
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

    /// A balance or spend in money, measured against a reference or budget the user set.
    static func isMoneyWindow(_ window: RelayWindow) -> Bool {
        guard let unit = window.amount?.unit else { return false }
        return unit == "usd" || unit == "cny"
    }

    private static func threshold(_ provider: RelayProvider, window: RelayWindow, level: Int, now: Date) -> UsageAlert {
        let reset = window.resetsAt.flatMap { RelativeTime.resets($0, now: now) }.map { $0.prefix(1).uppercased() + $0.dropFirst() + "." }
        return UsageAlert(
            id: "evt-\(provider.id)-\(window.id)-\(level)-\(instance(window.resetsAt, window: window, now: now))",
            provider: provider.id,
            kind: .threshold,
            level: level,
            title: "\(provider.name): \(level)% of \(window.title.lowercased()) used",
            body: reset ?? "It resets when \(provider.name) says so.",
            resetsAt: window.resetsAt,
            isUrgent: level >= 95
        )
    }

    /// "DeepSeek balance is low: $4.20 left of your $20.00 reference." A spend budget with a
    /// monthly reset reads as spend instead.
    private static func lowBalance(_ provider: RelayProvider, window: RelayWindow, level: Int, now: Date) -> UsageAlert {
        let amount = window.amount
        let unit = amount?.unit ?? "usd"
        let title: String
        let body: String
        if window.resetsAt == nil {
            title = "\(provider.name): balance is low"
            let left = amount?.remainingOrComputed.map { AmountFormat.text(max($0, 0), unit: unit) }
            let reference = amount?.limit.map { AmountFormat.text($0, unit: unit) }
            switch (left, reference) {
            case let (left?, reference?):
                body = "\(left) left of your \(reference) reference."
            case let (left?, nil):
                body = "\(left) left."
            default:
                body = "\(level)% of your reference is used."
            }
        } else {
            title = "\(provider.name): \(level)% of the budget spent"
            let spent = amount?.used.map { AmountFormat.text($0, unit: unit) }
            let budget = amount?.limit.map { AmountFormat.text($0, unit: unit) }
            let reset = window.resetsAt.flatMap { RelativeTime.resets($0, now: now) }.map { " It \($0)." } ?? ""
            if let spent, let budget {
                body = "\(spent) of \(budget) so far.\(reset)"
            } else {
                body = "\(level)% of your budget.\(reset)"
            }
        }
        return UsageAlert(
            id: "evt-\(provider.id)-\(window.id)-low-\(level)-\(instance(window.resetsAt, window: window, now: now))",
            provider: provider.id,
            kind: .lowBalance,
            level: level,
            title: title,
            body: body,
            resetsAt: window.resetsAt,
            isUrgent: level >= 95
        )
    }

    /// A window instance, named by its reset time. Short windows round to 10 minutes, a day or
    /// longer to the hour, so two devices whose readings disagree by a few minutes still agree.
    /// A balance has no reset: its instance is the day, so a top-up re-arms it the next day.
    static func instance(_ resetsAt: Date?, window: RelayWindow? = nil, now: Date = .now) -> String {
        guard let resetsAt else {
            return window.map { _ in "d\(Int(now.timeIntervalSince1970 / 86_400))" } ?? "open"
        }
        let length = window?.periodSec ?? window.map { Self.typicalLength(kind: $0.kind) } ?? 0
        let bucket: Double = length >= 86_400 ? 3600 : 600
        return String(Int((resetsAt.timeIntervalSince1970 / bucket).rounded()) * Int(bucket / 600))
    }

    /// Rough length by kind when the provider doesn't say; only picks the rounding above.
    static func typicalLength(kind: String) -> TimeInterval {
        switch WindowKind(rawValue: kind) {
        case .session: 5 * 3600
        case .daily: 86_400
        case .weekly: 7 * 86_400
        case .monthly, .billingCycle: 30 * 86_400
        case .pool, nil: 0
        }
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
    /// An alert that's been raised but not delivered yet: quiet hours, or iCloud didn't answer.
    struct Pending: Codable, Equatable, Sendable {
        var alert: UsageAlert
        var raisedAt: Date
    }

    /// The last reading per provider, for spotting crossings.
    var lastSeen: [String: RelayProvider] = [:]
    /// Alert IDs already sent, with when, pruned after two weeks.
    var sent: [String: Date] = [:]
    /// Raised, waiting to go out.
    var pending: [Pending] = []
    /// Alerts already shown as notifications on this device, so one waiting for iCloud isn't
    /// shown twice.
    var shownHere: [String: Date] = [:]

    static let memory: TimeInterval = 14 * 86_400
    /// A held alert older than this has lost its point.
    static let pendingLifetime: TimeInterval = 18 * 3600
    static let fileName = "alerts.json"

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastSeen = try container.decodeIfPresent([String: RelayProvider].self, forKey: .lastSeen) ?? [:]
        sent = try container.decodeIfPresent([String: Date].self, forKey: .sent) ?? [:]
        pending = (try? container.decodeIfPresent([Pending].self, forKey: .pending)) ?? []
        shownHere = (try? container.decodeIfPresent([String: Date].self, forKey: .shownHere)) ?? [:]
    }

    /// Raises alerts for these readings and queues them; returns the ones raised now. Readings
    /// that aren't live (stale, expired) don't move `lastSeen`, so a crossing is judged against
    /// the last real one.
    @discardableResult
    mutating func process(_ providers: [RelayProvider], preferences: AlertPreferences, now: Date = .now) -> [UsageAlert] {
        var fresh: [UsageAlert] = []
        for provider in providers where provider.isLive {
            for alert in AlertRules.alerts(previous: lastSeen[provider.id], current: provider, preferences: preferences, now: now)
            where sent[alert.id] == nil && !pending.contains(where: { $0.alert.id == alert.id }) && !fresh.contains(where: { $0.id == alert.id }) {
                fresh.append(alert)
                pending.append(Pending(alert: alert, raisedAt: now))
            }
            lastSeen[provider.id] = provider
        }
        prune(now: now)
        return fresh
    }

    /// Queued alerts that should go out now: urgent ones always, the rest once quiet hours end.
    func due(preferences: AlertPreferences, now: Date = .now) -> [UsageAlert] {
        pending.map(\.alert).filter { preferences.shouldSend($0, at: now) }
    }

    /// Delivered: never send these again.
    mutating func markSent(_ ids: [String], at now: Date = .now) {
        let delivered = Set(ids)
        for id in delivered {
            sent[id] = now
        }
        pending.removeAll { delivered.contains($0.alert.id) }
    }

    /// Shown as notifications on this device.
    mutating func markShownHere(_ ids: [String], at now: Date = .now) {
        for id in ids {
            shownHere[id] = now
        }
    }

    /// Drops held alerts that no longer mean anything: too old, or their window already reset.
    private mutating func prune(now: Date) {
        sent = sent.filter { now.timeIntervalSince($0.value) < Self.memory }
        shownHere = shownHere.filter { now.timeIntervalSince($0.value) < Self.memory }
        pending.removeAll { item in
            if now.timeIntervalSince(item.raisedAt) > Self.pendingLifetime { return true }
            switch item.alert.kind {
            case .threshold, .lowBalance, .bankedExpiring:
                return item.alert.resetsAt.map { $0 <= now } ?? false
            case .reset, .bankedNew:
                return false
            }
        }
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
