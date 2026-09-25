import Foundation
import os

enum GrokParser {
    /// Plan name from `/v1/settings`; the rest of that response is ignored.
    static func planLabel(fromSettings data: Data) -> String? {
        guard let root = try? JSONFlex.object(from: data),
              let label = JSONFlex.string(root["subscription_tier_display"])?.trimmingCharacters(in: .whitespaces),
              !label.isEmpty
        else { return nil }
        return label
    }

    static func snapshot(from data: Data, fetchedAt: Date = .now) throws -> QuotaSnapshot {
        let root = try JSONFlex.object(from: data)
        let config = JSONFlex.dictionary(root["config"]) ?? root
        let period = JSONFlex.dictionary(config["currentPeriod"])
        let periodType = JSONFlex.string(period?["type"]) ?? ""
        let isWeekly = periodType.contains("WEEKLY")

        let usedPercent: Double
        if let percent = JSONFlex.number(config["creditUsagePercent"]) {
            usedPercent = JSONFlex.clampPercent(percent)
        } else if let used = JSONFlex.cent(config["used"]),
                  let limit = JSONFlex.cent(config["monthlyLimit"]), limit > 0 {
            usedPercent = JSONFlex.clampPercent(used / limit * 100)
        } else if period != nil || (config["isUnifiedBillingUser"] as? Bool) == true {
            usedPercent = 0
        } else {
            throw ProviderError.parse
        }

        let resetsAt = JSONFlex.date(period?["end"])
            ?? JSONFlex.date(config["billingPeriodEnd"])
        let title = isWeekly ? "Weekly" : "This cycle"
        let kind: WindowKind = isWeekly ? .weekly : .billingCycle

        var windows = [
            QuotaWindow(
                id: "primary",
                kind: kind,
                title: title,
                usedPercent: usedPercent,
                resetsAt: resetsAt,
                startsAt: JSONFlex.date(period?["start"])
            ),
        ]

        if let cap = JSONFlex.cent(config["onDemandCap"]), cap > 0 {
            let used = JSONFlex.cent(config["onDemandUsed"]) ?? 0
            let extraPercent = JSONFlex.clampPercent(used / cap * 100)
            windows.append(
                QuotaWindow(
                    id: "on-demand",
                    kind: .pool,
                    title: "Extra",
                    usedPercent: extraPercent,
                    resetsAt: resetsAt
                )
            )
        }

        return QuotaSnapshot(
            provider: .grok,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            fetchedAt: fetchedAt,
            primaryTitle: title,
            windows: windows
        )
    }
}

struct GrokClient: ProviderClient {
    var provider: Provider { .grok }

    /// The plan name rarely changes; look it up at most every six hours.
    private static let planCache = OSAllocatedUnfairLock<(label: String?, at: Date)?>(initialState: nil)
    private static let planTTL: TimeInterval = 6 * 3_600

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        do {
            let auth = try await BlockingIO.run { try CredentialReaders.grokAuth() }
            let token = try CredentialReaders.usableGrokToken(auth)
            let url = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
            var headers: [String: String] = [:]
            if let userID = auth.userID {
                headers["x-userid"] = userID
            }
            let data = try await TokenroomHTTP.get(url, token: token, headers: headers, provider: .grok)
            var snapshot = try GrokParser.snapshot(from: data)
            snapshot.planLabel = await planLabel(token: token, headers: headers)
            return .success(snapshot)
        } catch let error as ProviderError {
            return .failure(error)
        } catch {
            return .failure(.unreachable)
        }
    }

    /// `subscription_tier_display` from the CLI's settings. Best effort: never fails the reading.
    private func planLabel(token: String, headers: [String: String]) async -> String? {
        if let cached = Self.planCache.withLock({ $0 }), Date().timeIntervalSince(cached.at) < Self.planTTL {
            return cached.label
        }
        guard let data = try? await TokenroomHTTP.get(
            URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!,
            token: token,
            headers: headers,
            provider: .grok
        ) else {
            return Self.planCache.withLock { $0?.label }
        }
        let label = GrokParser.planLabel(fromSettings: data)
        Self.planCache.withLock { $0 = (label, Date()) }
        return label
    }
}
