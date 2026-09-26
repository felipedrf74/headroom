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
    /// The window it's about, and that window's instance (`AlertRules.instance`). Nil in alerts
    /// raised by 2.0.0, and for banked resets.
    var window: String? = nil
    var instance: String? = nil
    /// A budget alert's text before its countdown, so a held alert can say how long is left
    /// when it goes out rather than when it was raised.
    var detail: String? = nil

    /// The key on the record of an alert an iPhone showed itself. No subscription lists it, so
    /// the record never comes back to it as a push.
    var shownKey: String {
        "shown:" + key
    }

    /// The instance part of the ID: the reset time bucket, or `d<day>` for a window without one.
    var instanceName: String {
        instance ?? id.components(separatedBy: "-").last ?? ""
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
    /// Choices a newer Tokenroom saved that this one doesn't know, kept as they came so saving
    /// here doesn't drop them from the shared copy.
    private var unknown: [String: JSONValue] = [:]

    static let supportedThresholds = [80, 95]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case thresholds, resets, banked, lowBalance, newModels, quietHours, quietStartHour, quietEndHour, timeZoneID, updatedAt
    }

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
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        let everything = try decoder.container(keyedBy: AnyCodingKey.self)
        for key in everything.allKeys where !known.contains(key.stringValue) {
            unknown[key.stringValue] = try? everything.decode(JSONValue.self, forKey: key)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        for (key, value) in unknown {
            try container.encode(value, forKey: AnyCodingKey(key))
        }
        try container.encode(thresholds, forKey: AnyCodingKey(CodingKeys.thresholds.rawValue))
        try container.encode(resets, forKey: AnyCodingKey(CodingKeys.resets.rawValue))
        try container.encode(banked, forKey: AnyCodingKey(CodingKeys.banked.rawValue))
        try container.encode(lowBalance, forKey: AnyCodingKey(CodingKeys.lowBalance.rawValue))
        try container.encode(newModels, forKey: AnyCodingKey(CodingKeys.newModels.rawValue))
        try container.encode(quietHours, forKey: AnyCodingKey(CodingKeys.quietHours.rawValue))
        try container.encode(quietStartHour, forKey: AnyCodingKey(CodingKeys.quietStartHour.rawValue))
        try container.encode(quietEndHour, forKey: AnyCodingKey(CodingKeys.quietEndHour.rawValue))
        try container.encode(timeZoneID, forKey: AnyCodingKey(CodingKeys.timeZoneID.rawValue))
        try container.encodeIfPresent(updatedAt, forKey: AnyCodingKey(CodingKeys.updatedAt.rawValue))
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
        }
        // Balances have their own switch, at both levels, whatever the usage levels are.
        if lowBalance {
            keys += Self.supportedThresholds.map { "lowBalance-\($0)" }
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

    /// Whether these choices still want this kind of alert; one held back for quiet hours is
    /// dropped when its switch is turned off meanwhile.
    func allows(_ alert: UsageAlert) -> Bool {
        switch alert.kind {
        case .threshold: thresholds.contains(alert.level)
        case .lowBalance: lowBalance
        case .reset: resets
        case .bankedNew, .bankedExpiring: banked
        }
    }

    /// The same choices, whenever they were made. A saved copy's `updatedAt` can come back a
    /// hair off (dates are stored as seconds since 1970), so syncing compares choices only.
    func sameChoices(as other: AlertPreferences?) -> Bool {
        guard var other else { return false }
        other.updatedAt = updatedAt
        return self == other
    }

    /// How long quiet hours last, or 0 when they're off.
    var quietLength: TimeInterval {
        guard quietHours, quietStartHour != quietEndHour else { return 0 }
        return TimeInterval((quietEndHour - quietStartHour + 24) % 24) * 3600
    }

    /// `remote` with the choices this device changed since `base`, its last copy that matched
    /// iCloud, so two devices changing different choices both keep theirs. Choices only
    /// `remote` knows (from a newer Tokenroom) stay.
    static func merged(base: AlertPreferences, local: AlertPreferences, remote: AlertPreferences) -> AlertPreferences {
        guard let baseFields = fields(of: base), let localFields = fields(of: local), var result = fields(of: remote) else {
            return local
        }
        let byLevel: Set<String> = [CodingKeys.updatedAt.rawValue, CodingKeys.thresholds.rawValue]
        for (key, value) in localFields where !byLevel.contains(key) && baseFields[key] != value {
            result[key] = value
        }
        guard var merged = decoded(result) else { return local }
        // Levels merge one by one: 80% turned off here and 95% there both stay off.
        let added = Set(local.thresholds).subtracting(base.thresholds)
        let removed = Set(base.thresholds).subtracting(local.thresholds)
        merged.thresholds = Set(remote.thresholds).union(added).subtracting(removed).sorted()
        merged.updatedAt = [local.updatedAt, remote.updatedAt].compactMap { $0 }.max()
        return merged
    }

    /// Every choice `local` has, laid over `remote`: for a device new to syncing whose copy is
    /// newer. Choices only `remote` knows (from a newer Tokenroom) stay.
    static func overlaying(_ local: AlertPreferences, on remote: AlertPreferences) -> AlertPreferences {
        guard let localFields = fields(of: local), var result = fields(of: remote) else { return local }
        for (key, value) in localFields {
            result[key] = value
        }
        return decoded(result) ?? local
    }

    private static func decoded(_ fields: [String: JSONValue]) -> AlertPreferences? {
        guard let data = try? RelayEnvelope.encoder.encode(fields) else { return nil }
        return try? RelayEnvelope.decoder.decode(AlertPreferences.self, from: data)
    }

    private static func fields(of preferences: AlertPreferences) -> [String: JSONValue]? {
        guard let data = try? RelayEnvelope.encoder.encode(preferences) else { return nil }
        return try? RelayEnvelope.decoder.decode([String: JSONValue].self, from: data)
    }
}

/// Keeps one device's alert choices in step with the shared copy in iCloud. `base` is the copy
/// this device last knew to match iCloud; whatever changed here since then is this device's own
/// change, laid over the shared copy, so a choice made on another device meanwhile isn't undone.
enum AlertPreferencesSync {
    struct Resolution: Equatable {
        /// What this device should use now.
        var preferences: AlertPreferences
        /// Whether iCloud needs these, because they hold a change made here.
        var needsPublish: Bool
    }

    static func resolve(base: AlertPreferences?, local: AlertPreferences, remote: AlertPreferences?) -> Resolution {
        guard let remote else {
            // Nothing shared (never yet, or deleted since): share choices someone made.
            guard local.updatedAt != nil else { return Resolution(preferences: local, needsPublish: false) }
            return publishing(local, over: [base])
        }
        guard let base else {
            // Never in step (a device new to syncing): the newer copy wins, as before.
            if AlertPreferences.newest(remote, local) == remote {
                return Resolution(preferences: remote, needsPublish: false)
            }
            return publishing(AlertPreferences.overlaying(local, on: remote), over: [remote])
        }
        if local.sameChoices(as: base) {
            return Resolution(preferences: remote, needsPublish: false)
        }
        if remote.sameChoices(as: base) {
            return publishing(local, over: [base, remote])
        }
        return publishing(AlertPreferences.merged(base: base, local: local, remote: remote), over: [base])
    }

    /// Choices to send, dated no earlier than the copies they build on, so a device whose clock
    /// runs behind doesn't make them look older than they are where the newest copy wins.
    private static func publishing(_ preferences: AlertPreferences, over others: [AlertPreferences?]) -> Resolution {
        var preferences = preferences
        preferences.updatedAt = ([preferences.updatedAt] + others.map { $0?.updatedAt }).compactMap { $0 }.max()
        return Resolution(preferences: preferences, needsPublish: true)
    }
}

enum AlertRules {
    /// A reset is worth a "fresh headroom" alert only after heavy use.
    static let resetWorthyUse = 80.0
    /// Readings of the same window instance can report slightly different reset times.
    static let resetJitter: TimeInterval = 30 * 60
    /// A reset longer ago than this (a device asleep for days) isn't news anymore.
    static let resetNewsWindow: TimeInterval = 12 * 3600
    /// A fall in use this large means the window started over (a banked reset used early),
    /// not a provider moving its reset time.
    static let resetDrop = 10.0

    /// Alerts raised going from `previous` to `current` for one provider. A provider seen for the
    /// first time raises nothing, so installing or restarting never floods notifications.
    static func alerts(previous: RelayProvider?, current: RelayProvider, preferences: AlertPreferences, now: Date = .now) -> [UsageAlert] {
        guard let previous, current.isLive else { return [] }
        var alerts: [UsageAlert] = []
        for window in current.windows where window.isMetered {
            guard let before = previous.windows.first(where: { $0.id == window.id }) else { continue }
            let sameInstance = isSameInstance(before: before, current: window, now: now)
            let isMoney = isMoneyWindow(window)
            // Balances follow their own switch; usage windows, the 80% and 95% ones.
            let levels = isMoney ? (preferences.lowBalance ? AlertPreferences.supportedThresholds : []) : preferences.thresholds
            // Only the highest threshold crossed in one step.
            let crossed = levels.sorted(by: >).first { level in
                window.used >= Double(level) && (!sameInstance || before.used < Double(level))
            }
            if let level = crossed {
                alerts.append(isMoney ? lowBalance(current, window: window, level: level, now: now) : threshold(current, window: window, level: level, now: now))
            }
            if preferences.resets, !isMoney, !sameInstance, before.used >= resetWorthyUse, let oldReset = before.resetsAt,
               oldReset <= now.addingTimeInterval(resetJitter), oldReset > now.addingTimeInterval(-resetNewsWindow) {
                let name = instance(oldReset, window: before, now: now)
                alerts.append(UsageAlert(
                    id: "evt-\(current.id)-\(window.id)-reset-\(name)",
                    provider: current.id,
                    kind: .reset,
                    level: 0,
                    title: "\(current.name): \(window.title) reset",
                    body: "Fresh headroom. It was at \(TokenroomFormat.percentText(before.used))% before the reset.",
                    resetsAt: window.resetsAt,
                    isUrgent: false,
                    window: window.id,
                    instance: name
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
        let name = instance(window.resetsAt, window: window, now: now)
        return UsageAlert(
            id: "evt-\(provider.id)-\(window.id)-\(level)-\(name)",
            provider: provider.id,
            kind: .threshold,
            level: level,
            title: "\(provider.name): \(level)% of \(window.title.lowercased()) used",
            body: resetSentence(window.resetsAt, now: now) ?? "It resets when \(provider.name) says so.",
            resetsAt: window.resetsAt,
            isUrgent: level >= 95,
            window: window.id,
            instance: name
        )
    }

    /// "Resets in 3h 20m."
    private static func resetSentence(_ resetsAt: Date?, now: Date) -> String? {
        resetsAt.flatMap { RelativeTime.resets($0, now: now) }.map { $0.prefix(1).uppercased() + $0.dropFirst() + "." }
    }

    /// An alert as it goes out: one held back for quiet hours says how long is left now, not when
    /// it was raised.
    static func refreshed(_ alert: UsageAlert, now: Date) -> UsageAlert {
        guard let resetsAt = alert.resetsAt, resetsAt > now else { return alert }
        var alert = alert
        switch alert.kind {
        case .threshold:
            alert.body = resetSentence(resetsAt, now: now) ?? alert.body
        case .lowBalance:
            if let detail = alert.detail, let reset = RelativeTime.resets(resetsAt, now: now) {
                alert.body = "\(detail) It \(reset)."
            }
        case .reset, .bankedNew, .bankedExpiring:
            break
        }
        return alert
    }

    /// For an alert about a window without a reset (a balance), named by the day (UTC) it was
    /// seen: the same alert's names the day before and the day after. Two devices on either side
    /// of midnight name one crossing by different days, so each checks the other's first.
    static func neighbouringDayIDs(of alert: UsageAlert) -> [String] {
        let name = alert.instanceName
        guard alert.resetsAt == nil, name.hasPrefix("d"), let day = Int(name.dropFirst()), alert.id.hasSuffix(name) else { return [] }
        let stem = String(alert.id.dropLast(name.count))
        return [stem + "d\(day - 1)", stem + "d\(day + 1)"]
    }

    /// The same alert at a higher level, e.g. the 95% one for an 80% one.
    static func id(of alert: UsageAlert, atLevel level: Int) -> String? {
        guard let window = alert.window, let instance = alert.instance else { return nil }
        switch alert.kind {
        case .threshold: return "evt-\(alert.provider)-\(window)-\(level)-\(instance)"
        case .lowBalance: return "evt-\(alert.provider)-\(window)-low-\(level)-\(instance)"
        case .reset, .bankedNew, .bankedExpiring: return nil
        }
    }

    /// "DeepSeek balance is low: $4.20 left of your $20.00 reference." A spend budget with a
    /// monthly reset reads as spend instead.
    private static func lowBalance(_ provider: RelayProvider, window: RelayWindow, level: Int, now: Date) -> UsageAlert {
        let amount = window.amount
        let unit = amount?.unit ?? "usd"
        let title: String
        let body: String
        var detail: String?
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
            let spentText = if let spent, let budget { "\(spent) of \(budget) so far." } else { "\(level)% of your budget." }
            detail = spentText
            body = spentText + reset
        }
        let name = instance(window.resetsAt, window: window, now: now)
        return UsageAlert(
            id: "evt-\(provider.id)-\(window.id)-low-\(level)-\(name)",
            provider: provider.id,
            kind: .lowBalance,
            level: level,
            title: title,
            body: body,
            resetsAt: window.resetsAt,
            isUrgent: level >= 95,
            window: window.id,
            instance: name,
            detail: detail
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

    /// Whether two readings of a window belong to one instance: the same reset time, give or take
    /// `resetJitter`, or a reset time the provider moved while the window went on (the old time
    /// hasn't come and use didn't fall). A moved reset isn't a new window with new alerts.
    static func isSameInstance(before: RelayWindow, current: RelayWindow, now: Date) -> Bool {
        isSameInstance(before.resetsAt, current.resetsAt)
            || isMovedReset(from: before.resetsAt, to: current.resetsAt, usedBefore: before.used, usedNow: current.used,
                            length: current.periodSec ?? typicalLength(kind: current.kind), now: now)
    }

    /// A reset time that changed while the window kept going: the old time is still ahead, it
    /// moved by no more than a quarter of the window, and use didn't drop the way it does when a
    /// window starts over. Further than that, it's a different window.
    static func isMovedReset(from old: Date?, to new: Date?, usedBefore: Double, usedNow: Double, length: TimeInterval?, now: Date) -> Bool {
        guard let old, let new, old > now else { return false }
        return isSmallMove(from: old, to: new, usedBefore: usedBefore, usedNow: usedNow, length: length)
    }

    /// A reset time that moved by no more than a quarter of the window (or `resetJitter`), with
    /// use not dropping the way it does when a window starts over.
    static func isSmallMove(from old: Date, to new: Date, usedBefore: Double, usedNow: Double, length: TimeInterval?) -> Bool {
        abs(new.timeIntervalSince(old)) <= max(resetJitter, (length ?? 0) / 4) && usedNow > usedBefore - resetDrop
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
    /// The highest level sent for each window and kind (`provider/window/kind`), with when, so a
    /// lower one held back for quiet hours doesn't follow it, even when the window's reset time
    /// moved between them and their names differ.
    var levelsSent: [String: LevelSent] = [:]

    struct LevelSent: Codable, Equatable, Sendable {
        var level: Int
        var sentAt: Date
    }

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
        levelsSent = (try? container.decodeIfPresent([String: LevelSent].self, forKey: .levelsSent)) ?? [:]
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
        prune(preferences: preferences, now: now)
        return fresh
    }

    /// Queued alerts that should go out now: urgent ones always, the rest once quiet hours end.
    /// One waiting behind a higher level for the same window (80% held overnight, then 95%)
    /// doesn't follow it, and held ones say how long is left as they go out.
    func due(preferences: AlertPreferences, now: Date = .now) -> [UsageAlert] {
        let ready = pending.filter { preferences.allows($0.alert) && preferences.shouldSend($0.alert, at: now) }
        let readyIDs = Set(ready.map(\.alert.id))
        return ready
            .filter { !Self.isSuperseded($0, sent: sent, levelsSent: levelsSent, going: readyIDs) }
            .map { AlertRules.refreshed($0.alert, now: now) }
    }

    /// Whether the same window's alert at a higher level went out after this one was raised, or
    /// is going out now.
    private static func isSuperseded(_ item: Pending, sent: [String: Date], levelsSent: [String: LevelSent], going: Set<String>) -> Bool {
        let alert = item.alert
        if let key = levelKey(alert), let higher = levelsSent[key], higher.level > alert.level, higher.sentAt >= item.raisedAt {
            return true
        }
        return AlertPreferences.supportedThresholds.contains { level in
            guard level > alert.level, let higher = AlertRules.id(of: alert, atLevel: level) else { return false }
            return sent[higher] != nil || going.contains(higher)
        }
    }

    /// Crossings of a window's levels: `provider/window/kind`, for thresholds and budgets.
    private static func levelKey(_ alert: UsageAlert) -> String? {
        guard let window = alert.window, alert.kind == .threshold || alert.kind == .lowBalance else { return nil }
        return "\(alert.provider)/\(window)/\(alert.kind.rawValue)"
    }

    /// Delivered: never send these again.
    mutating func markSent(_ ids: [String], at now: Date = .now) {
        let delivered = Set(ids)
        for id in delivered {
            sent[id] = now
        }
        for item in pending where delivered.contains(item.alert.id) {
            guard let key = Self.levelKey(item.alert), (levelsSent[key]?.level ?? 0) <= item.alert.level else { continue }
            levelsSent[key] = LevelSent(level: item.alert.level, sentAt: now)
        }
        pending.removeAll { delivered.contains($0.alert.id) }
    }

    /// Shown as notifications on this device.
    mutating func markShownHere(_ ids: [String], at now: Date = .now) {
        for id in ids {
            shownHere[id] = now
        }
    }

    /// Drops held alerts that no longer mean anything: too old, turned off since, overtaken by a
    /// higher level, or their window already reset.
    private mutating func prune(preferences: AlertPreferences, now: Date) {
        sent = sent.filter { now.timeIntervalSince($0.value) < Self.memory }
        shownHere = shownHere.filter { now.timeIntervalSince($0.value) < Self.memory }
        levelsSent = levelsSent.filter { now.timeIntervalSince($0.value.sentAt) < Self.memory }
        // Held through at least one whole stretch of quiet hours, however long it is.
        let lifetime = max(Self.pendingLifetime, preferences.quietLength + 3600)
        let delivered = sent
        let levels = levelsSent
        pending.removeAll { item in
            if now.timeIntervalSince(item.raisedAt) > lifetime { return true }
            if !preferences.allows(item.alert) || Self.isSuperseded(item, sent: delivered, levelsSent: levels, going: []) { return true }
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
