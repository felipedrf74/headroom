import Foundation
import os

/// Codex usage from `chatgpt.com/backend-api/wham/usage`. The response also carries the
/// account's email and IDs; they are never read.
enum OpenAIParser {
    private static let weekSeconds: Double = 6 * 24 * 60 * 60

    static func snapshot(from data: Data, fetchedAt: Date = .now) throws -> QuotaSnapshot {
        let root = try JSONFlex.object(from: data)
        let rateLimit = JSONFlex.dictionary(root["rate_limit"]) ?? [:]
        let primary = window(from: JSONFlex.dictionary(rateLimit["primary_window"]))
        let secondary = window(from: JSONFlex.dictionary(rateLimit["secondary_window"]))

        // Decide by window length, not position: a weekly-only plan reports its week as primary.
        let candidates = [primary, secondary].compactMap { $0 }
        guard let weekly = candidates.first(where: { $0.limitSeconds >= weekSeconds }) ?? secondary ?? primary else {
            throw ProviderError.parse
        }
        let session = candidates.first { $0 != weekly }

        var windows = [makeWindow(weekly, id: "weekly")]
        if let session {
            windows.append(makeWindow(session, id: "session", title: "Session", kind: .session))
        }

        if let review = window(from: JSONFlex.dictionary(JSONFlex.dictionary(root["code_review_rate_limit"])?["primary_window"])) {
            windows.append(makeWindow(review, id: "code-review", title: "Code review"))
        }

        if let extras = JSONFlex.array(root["additional_rate_limits"]) {
            for (index, extra) in extras.enumerated() {
                guard let object = JSONFlex.dictionary(extra) else { continue }
                let name = JSONFlex.string(object["limit_name"]) ?? "Extra"
                let nested = JSONFlex.dictionary(object["rate_limit"]) ?? [:]
                let parts = [
                    window(from: JSONFlex.dictionary(nested["secondary_window"])),
                    window(from: JSONFlex.dictionary(nested["primary_window"])),
                ].compactMap { $0 }
                // Named limits only earn a line once they're in use.
                if let used = parts.first(where: { $0.used >= 1 }) {
                    windows.append(makeWindow(used, id: "extra-\(index)", title: name))
                }
            }
        }

        if let spend = spendWindow(from: JSONFlex.dictionary(JSONFlex.dictionary(root["spend_control"])?["individual_limit"])) {
            windows.append(spend)
        }

        return QuotaSnapshot(
            provider: .openai,
            usedPercent: weekly.used,
            resetsAt: weekly.resetsAt,
            fetchedAt: fetchedAt,
            primaryTitle: windows[0].title,
            windows: windows,
            planLabel: planLabel(JSONFlex.string(root["plan_type"])),
            banked: banked(from: JSONFlex.dictionary(root["rate_limit_reset_credits"])),
            extra: credits(from: JSONFlex.dictionary(root["credits"]))
        )
    }

    /// Expiry dates of reset credits that are still available, soonest first.
    /// From `wham/rate-limit-reset-credits`; titles, images, and IDs are ignored.
    static func availableResetExpiries(from data: Data, now: Date = .now) throws -> [Date] {
        let root = try JSONFlex.object(from: data)
        return (JSONFlex.array(root["credits"]) ?? []).compactMap { item -> Date? in
            guard let credit = JSONFlex.dictionary(item),
                  credit["redeemed_at"] == nil || credit["redeemed_at"] is NSNull,
                  credit["redeem_started_at"] == nil || credit["redeem_started_at"] is NSNull,
                  (credit["is_supported_by_plan"] as? Bool) != false,
                  let expires = JSONFlex.date(credit["expires_at"]), expires > now
            else { return nil }
            return expires
        }
        .sorted()
    }

    private struct ParsedWindow: Equatable {
        var used: Double
        var resetsAt: Date?
        var limitSeconds: Double
    }

    private static func window(from object: [String: Any]?) -> ParsedWindow? {
        guard let object else { return nil }
        guard let used = JSONFlex.number(object["used_percent"]) else { return nil }
        let remaining = JSONFlex.number(object["remaining_percent"])
        let percent = remaining.map { JSONFlex.clampPercent(100 - $0) } ?? JSONFlex.clampPercent(used)
        return ParsedWindow(
            used: percent,
            resetsAt: JSONFlex.date(object["reset_at"]),
            limitSeconds: JSONFlex.number(object["limit_window_seconds"]) ?? 0
        )
    }

    private static func makeWindow(_ parsed: ParsedWindow, id: String, title: String? = nil, kind: WindowKind? = nil) -> QuotaWindow {
        let isWeekly = parsed.limitSeconds >= weekSeconds
        return QuotaWindow(
            id: id,
            kind: kind ?? (isWeekly ? .weekly : .session),
            title: title ?? (isWeekly ? "Weekly" : "Session"),
            usedPercent: parsed.used,
            resetsAt: parsed.resetsAt,
            windowSeconds: parsed.limitSeconds > 0 ? parsed.limitSeconds : nil
        )
    }

    /// `spend_control.individual_limit`: a dollar cap an admin set for this seat.
    private static func spendWindow(from object: [String: Any]?) -> QuotaWindow? {
        guard let object else { return nil }
        let limit = JSONFlex.number(object["limit"])
        let used = JSONFlex.number(object["used"])
        let percent: Double
        if let remaining = JSONFlex.number(object["remaining_percent"]) {
            percent = JSONFlex.clampPercent(100 - remaining)
        } else if let limit, limit > 0, let used {
            percent = JSONFlex.clampPercent(used / limit * 100)
        } else {
            return nil
        }
        return QuotaWindow(
            id: "spend",
            kind: .pool,
            title: "Spend limit",
            usedPercent: percent,
            resetsAt: JSONFlex.date(object["resets_at"]),
            amount: QuotaAmount(used: used, limit: limit, unit: "usd")
        )
    }

    private static func credits(from object: [String: Any]?) -> ExtraUsage? {
        guard let object,
              (object["has_credits"] as? Bool) == true,
              (object["unlimited"] as? Bool) != true,
              let balance = JSONFlex.number(object["balance"])
        else { return nil }
        return ExtraUsage(title: "Credits", amount: QuotaAmount(remaining: balance, unit: "credits"))
    }

    private static func banked(from object: [String: Any]?) -> BankedResets? {
        guard let object,
              let count = JSONFlex.number(object["applicable_available_count"]) ?? JSONFlex.number(object["available_count"]),
              count > 0
        else { return nil }
        return BankedResets(available: Int(count))
    }

    private static func planLabel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct OpenAIClient: ProviderClient {
    var provider: Provider { .openai }

    /// Reset-credit expiries change rarely; look them up at most every six hours.
    private static let expiryCache = OSAllocatedUnfairLock<(count: Int, expiries: [Date], at: Date)?>(initialState: nil)
    private static let expiryTTL: TimeInterval = 6 * 3_600

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        do {
            let auth = try await BlockingIO.run { try CredentialReaders.codexAuth() }
            var headers = [
                "OpenAI-Beta": "codex-1",
                "originator": "Tokenroom",
            ]
            if let accountID = auth.accountID {
                headers["ChatGPT-Account-ID"] = accountID
            }
            let data = try await TokenroomHTTP.get(
                URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
                token: auth.accessToken,
                headers: headers,
                provider: .openai
            )
            var snapshot = try OpenAIParser.snapshot(from: data)
            if let banked = snapshot.banked {
                snapshot.banked?.expiries = await expiries(count: banked.available, token: auth.accessToken, headers: headers)
            }
            return .success(snapshot)
        } catch let error as ProviderError {
            return .failure(error)
        } catch {
            return .failure(.unreachable)
        }
    }

    /// Best effort: a failure here never fails the usage reading.
    private func expiries(count: Int, token: String, headers: [String: String]) async -> [Date] {
        if let cached = Self.expiryCache.withLock({ $0 }), cached.count == count,
           Date().timeIntervalSince(cached.at) < Self.expiryTTL {
            return cached.expiries
        }
        guard let data = try? await TokenroomHTTP.get(
            URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!,
            token: token,
            headers: headers,
            provider: .openai
        ), let expiries = try? OpenAIParser.availableResetExpiries(from: data) else {
            return Self.expiryCache.withLock { $0?.expiries } ?? []
        }
        Self.expiryCache.withLock { $0 = (count, expiries, Date()) }
        return expiries
    }
}
