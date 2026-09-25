import Foundation

/// What one collector (a Mac, or an iPhone with API keys) publishes to the user's iCloud.
///
/// Self-describing: each provider carries its own name, monogram, and tint, so an older phone
/// can show a provider that a newer Mac added. Unknown keys are ignored when decoding; additions
/// within a version are optional fields only. Never holds tokens, keys, emails, or account IDs.
struct RelayEnvelope: Codable, Equatable, Sendable {
    static let version = 1

    /// Format version of this payload.
    var v: Int = RelayEnvelope.version
    /// Oldest reader version that understands it.
    var minReader: Int = 1
    /// `mac` or `iphone`.
    var producer: String
    var appVersion: String
    /// When the collector last ran a refresh, even if nothing changed.
    var checkedAt: Date
    var providers: [RelayProvider]

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> RelayEnvelope {
        try decoder.decode(RelayEnvelope.self, from: data)
    }

    /// Whether this build can read the payload at all.
    var isReadable: Bool {
        minReader <= Self.version
    }

    /// Stable hash of what matters to readers, so unchanged usage isn't re-sent.
    /// Ignores `checkedAt` and per-provider check times.
    var materialHash: Int {
        var hasher = Hasher()
        for provider in providers {
            hasher.combine(provider.id)
            hasher.combine(provider.state)
            hasher.combine(provider.plan)
            hasher.combine(provider.banked?.available)
            hasher.combine(provider.banked?.expiries.first)
            hasher.combine(provider.extra?.amount.remainingOrComputed.map { Int($0.rounded()) })
            for window in provider.windows {
                hasher.combine(window.id)
                hasher.combine(Int(window.used.rounded()))
                hasher.combine(window.resetsAt.map { Int($0.timeIntervalSince1970 / 60) })
            }
        }
        return hasher.finalize()
    }
}

struct RelayProvider: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var shortName: String
    var monogram: String
    /// Brand tint as `#RRGGBB`, for monogram marks.
    var tint: String
    /// `live`, `stale`, `expired`, `rateLimited`, `signedOut`, `notEntitled`, `unreachable`, `loading`.
    var state: String
    /// Short status line for non-live states, e.g. "Session expired. Run claude once to refresh it."
    var message: String?
    /// Last successful check.
    var checkedAt: Date?
    /// When the shown reading was taken.
    var fetchedAt: Date?
    var plan: String?
    var primaryWindowID: String?
    var windows: [RelayWindow]
    var banked: BankedResets? = nil
    var extra: ExtraUsage? = nil

    var primaryWindow: RelayWindow? {
        windows.first { $0.id == primaryWindowID } ?? windows.first
    }
}

struct RelayWindow: Codable, Equatable, Sendable, Identifiable {
    var id: String
    /// `weekly`, `session`, `billingCycle`, `pool`, or newer kinds; unknown kinds read as a pool.
    var kind: String
    var title: String
    /// Used percent, 0–100.
    var used: Double
    var resetsAt: Date?
    /// Window length in seconds, when known; readers need it for pace.
    var periodSec: Double? = nil
    var startsAt: Date? = nil
    var amount: QuotaAmount? = nil
    /// False for amount-only windows (a balance with no limit).
    var metered: Bool? = nil
}
