import Foundation

extension ProviderStatus {
    /// An expired session keeps its last reading, faded, this long.
    static let expiredGrace: TimeInterval = 24 * 3600

    /// What a failed check leaves behind. The last reading stays, faded, where it still helps:
    /// through an outage or a rate limit, and for a day after a session expires.
    /// - Parameter lastChecked: when the cached reading was last confirmed.
    static func failure(_ error: ProviderError, cached: QuotaSnapshot?, lastChecked: Date?, now: Date) -> ProviderStatus {
        switch error {
        case .signedOut(let hint):
            return .signedOut(hint)
        case .notEntitled(let hint):
            return .notEntitled(hint)
        case .expired(let hint):
            let checked = lastChecked ?? cached?.fetchedAt
            let recent = checked.map { now.timeIntervalSince($0) < expiredGrace } ?? false
            return .expired(hint, cached: recent ? cached : nil)
        case .rateLimited(let until):
            return .rateLimited(until: clampedRetry(until, now: now), cached: cached)
        case .unreachable, .parse:
            return cached.map(ProviderStatus.stale) ?? .unreachable(cached: nil)
        }
    }

    /// Honors Retry-After, within one minute to six hours.
    static func clampedRetry(_ until: Date?, now: Date) -> Date {
        let wait = until.map { $0.timeIntervalSince(now) } ?? TokenroomHTTP.defaultRetryAfter
        return now.addingTimeInterval(min(max(wait, 60), longestRetry))
    }

    /// The longest Retry-After honored. A wait further off than this means the clock was set
    /// back since it was saved.
    static let longestRetry: TimeInterval = 6 * 60 * 60

    /// Not connected: nothing to show until the user signs in or adds a key.
    var isDisconnected: Bool {
        switch self {
        case .signedOut, .notEntitled, .expired(_, nil), .unreachable(nil):
            true
        default:
            false
        }
    }
}

// MARK: Relay records

extension RelayProvider {
    /// A provider as the user's other devices see it: readings only, never tokens, keys, or
    /// identities.
    init(provider: Provider, status: ProviderStatus, checkedAt: Date?) {
        let snapshot = status.snapshot
        self.init(
            id: provider.rawValue,
            name: provider.displayName,
            shortName: provider.shortName,
            monogram: provider.monogram,
            tint: provider.tintHex,
            state: status.relayState,
            message: status.relayMessage(for: provider),
            checkedAt: checkedAt,
            fetchedAt: snapshot?.fetchedAt,
            plan: snapshot?.planLabel,
            primaryWindowID: snapshot?.windows.first?.id,
            windows: snapshot?.windows.map(RelayWindow.init) ?? [],
            banked: snapshot?.banked,
            extra: snapshot?.extra,
            category: provider.category.rawValue
        )
    }

    var isLive: Bool {
        state == "live"
    }

    /// Nothing to show: signed out, not on a plan, or failed before a first reading.
    var isDisconnected: Bool {
        switch state {
        case "signedOut", "notEntitled":
            true
        case "expired", "unreachable", "loading":
            windows.isEmpty
        default:
            false
        }
    }
}

extension RelayProvider {
    /// Live Activities last about 8 hours, so only windows resetting within that are followed.
    static let followHorizon: TimeInterval = 8 * 3600

    /// The window worth a Live Activity: the one on screen when it qualifies, else a session,
    /// else the most used window at 80% or more, resetting within 8 hours.
    /// - Parameter preferred: the window a screen shows, e.g. Next up's.
    func windowToFollow(preferring preferred: String? = nil, now: Date = .now) -> RelayWindow? {
        let soon = windows.filter { window in
            guard window.isMetered, let resetsAt = window.resetsAt else { return false }
            return resetsAt > now && resetsAt.timeIntervalSince(now) <= Self.followHorizon
        }
        if let preferred, let shown = soon.first(where: { $0.id == preferred }) {
            return shown
        }
        return soon.first { $0.windowKind == .session }
            ?? soon.filter { $0.used >= 80 }.max { $0.used < $1.used }
    }
}

extension RelayWindow {
    init(_ window: QuotaWindow) {
        self.init(
            id: window.id,
            kind: window.kind.rawValue,
            title: window.title,
            used: window.usedPercent,
            resetsAt: window.resetsAt,
            periodSec: window.windowSeconds,
            startsAt: window.startsAt,
            amount: window.amount,
            metered: window.metered
        )
    }

    var windowKind: WindowKind {
        WindowKind(rawValue: kind) ?? .pool
    }

    var isMetered: Bool {
        metered ?? true
    }
}

extension ProviderStatus {
    /// The state name relay readers switch on.
    var relayState: String {
        switch self {
        case .loading: "loading"
        case .live: "live"
        case .stale: "stale"
        case .signedOut: "signedOut"
        case .expired: "expired"
        case .notEntitled: "notEntitled"
        case .rateLimited: "rateLimited"
        case .unreachable: "unreachable"
        }
    }

    /// One line for states without a fresh reading.
    func relayMessage(for provider: Provider) -> String? {
        switch self {
        case .signedOut(let hint), .expired(let hint, _), .notEntitled(let hint):
            hint
        case .rateLimited(let until, _):
            "Couldn't refresh. \(provider.displayName) asked to wait until \(until.formatted(date: .omitted, time: .shortened))."
        case .unreachable:
            "Couldn't reach \(provider.displayName)."
        case .loading, .live, .stale:
            nil
        }
    }
}
