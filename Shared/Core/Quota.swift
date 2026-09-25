import Foundation

enum WindowKind: String, Codable, Sendable {
    case weekly
    case session
    case daily
    case monthly
    case billingCycle
    case pool

    /// Unknown kinds (from a newer build) read as a generic pool instead of failing the snapshot.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = WindowKind(rawValue: raw) ?? .pool
    }
}

struct QuotaWindow: Equatable, Codable, Sendable, Identifiable {
    var id: String
    var kind: WindowKind
    var title: String
    var usedPercent: Double
    var resetsAt: Date?
    /// Window length when the provider reports it (e.g. Codex `limit_window_seconds`).
    var windowSeconds: Double? = nil
    /// Window start when the provider reports it (e.g. a billing cycle's first day).
    var startsAt: Date? = nil
    /// Dollars, credits, or requests behind the window, when the provider reports them.
    var amount: QuotaAmount? = nil
    /// False for amount-only windows (a balance with no limit): no meter, never in the menu bar.
    var metered: Bool? = nil

    var isMetered: Bool {
        metered ?? true
    }

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
}

struct QuotaSnapshot: Equatable, Codable, Sendable {
    var provider: Provider
    var usedPercent: Double
    var resetsAt: Date?
    var fetchedAt: Date
    var primaryTitle: String
    var windows: [QuotaWindow]
    /// Plan name the provider reports, e.g. "SuperGrok Heavy".
    var planLabel: String? = nil
    /// Saved limit resets (e.g. Codex reset credits).
    var banked: BankedResets? = nil
    /// Paid usage beyond the plan (e.g. Codex credits, Claude extra usage).
    var extra: ExtraUsage? = nil
    /// Where the reading came from when it isn't the provider's usage call, e.g. "bridge"
    /// for Claude Code's status line.
    var source: String? = nil

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
}

/// An amount of money, credits, or requests. Values are in `unit`.
struct QuotaAmount: Equatable, Codable, Sendable {
    var used: Double? = nil
    var limit: Double? = nil
    var remaining: Double? = nil
    /// `usd`, `cny`, `credits`, `requests`, `tokens`, or `points`.
    var unit: String

    var remainingOrComputed: Double? {
        remaining ?? limit.flatMap { limit in used.map { limit - $0 } }
    }
}

/// Resets saved for later: a count, and when each expires (soonest first).
struct BankedResets: Equatable, Codable, Sendable {
    var available: Int
    var expiries: [Date] = []

    func nextExpiry(after now: Date = .now) -> Date? {
        expiries.filter { $0 > now }.min()
    }
}

struct ExtraUsage: Equatable, Codable, Sendable {
    /// e.g. "Credits", "Extra usage".
    var title: String
    var amount: QuotaAmount
    var isEnabled: Bool = true
}

enum ProviderError: Error, Equatable, Sendable {
    case signedOut(String)
    case expired(String)
    case notEntitled(String)
    case rateLimited(until: Date?)
    case unreachable
    case parse
}

enum ProviderStatus: Equatable, Sendable {
    case loading
    case live(QuotaSnapshot)
    case stale(QuotaSnapshot)
    case signedOut(String)
    /// The session expired. `cached` is the last reading, kept for a day so meters don't blank.
    case expired(String, cached: QuotaSnapshot?)
    case notEntitled(String)
    case rateLimited(until: Date, cached: QuotaSnapshot?)
    case unreachable(cached: QuotaSnapshot?)

    var snapshot: QuotaSnapshot? {
        switch self {
        case .live(let snapshot), .stale(let snapshot):
            snapshot
        case .unreachable(let cached), .expired(_, let cached), .rateLimited(_, let cached):
            cached
        default:
            nil
        }
    }

    var isStale: Bool {
        switch self {
        case .stale, .unreachable(cached: .some), .expired(_, cached: .some), .rateLimited(_, cached: .some):
            true
        default:
            false
        }
    }
}
