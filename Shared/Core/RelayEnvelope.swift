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
    /// Ignores `checkedAt` and per-provider check times. Amounts count as they're shown, so a
    /// balance or a month's spend changes it. A measured run-out drifts a little on every check,
    /// so it's left out: `RelayPublishPolicy` sends one that moved an hour or more, and widgets
    /// don't draw it.
    var materialHash: Int {
        var hasher = Hasher()
        for provider in providers {
            hasher.combine(provider.id)
            hasher.combine(provider.state)
            hasher.combine(provider.plan)
            hasher.combine(provider.banked?.available)
            hasher.combine(provider.banked?.expiries.first)
            hasher.combine(provider.extra?.isEnabled)
            Self.combine(provider.extra?.amount, into: &hasher)
            for window in provider.windows {
                hasher.combine(window.id)
                hasher.combine(Int(window.used.rounded()))
                // To the nearest minute: a reset worked out as now plus seconds moves a second
                // either way between checks.
                hasher.combine(window.resetsAt.map { Int(($0.timeIntervalSince1970 / 60).rounded()) })
                Self.combine(window.amount, into: &hasher)
            }
        }
        return hasher.finalize()
    }

    /// How far a measured run-out moves before it counts as a change.
    static let runOutStep: TimeInterval = 3_600

    /// When each window with a measured pace would run out, keyed `provider/window`: its reset
    /// when it lasts until then (or runs out right at it), `distantFuture` without one.
    var runOuts: [String: Date] {
        var runOuts: [String: Date] = [:]
        for provider in providers {
            for window in provider.windows {
                guard let pace = window.pace else { continue }
                let end = window.resetsAt ?? .distantFuture
                runOuts[provider.id + "/" + window.id] = min(pace.runsOutAt ?? end, end)
            }
        }
        return runOuts
    }

    /// An amount at the precision `AmountFormat` shows it: cents for money, tenths otherwise.
    private static func combine(_ amount: QuotaAmount?, into hasher: inout Hasher) {
        hasher.combine(amount?.unit)
        guard let amount else { return }
        let scale: Double = amount.unit == "usd" || amount.unit == "cny" ? 100 : 10
        for value in [amount.used, amount.limit, amount.remaining] {
            hasher.combine(value.map { ($0 * scale).rounded() })
        }
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
    /// `subscription`, `apiBalance`, or `orgSpend`, for grouping; newer kinds read as unknown.
    var category: String? = nil

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
    /// Pace the collector worked out from its own frequent readings; readers with only the
    /// hourly week prefer it.
    var pace: RelayPace? = nil
}

/// What a collector measured about a window's pace.
struct RelayPace: Codable, Equatable, Sendable {
    /// When usage would reach 100% at the recent rate; nil when it wouldn't before the reset.
    var runsOutAt: Date?
}
