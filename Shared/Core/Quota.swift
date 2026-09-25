import Foundation

enum WindowKind: String, Codable, Sendable {
    case weekly
    case session
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

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
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
