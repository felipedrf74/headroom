import Foundation

/// Readings for "Try sample data", previews, and screenshots: realistic, the same for a given
/// moment, and labelled as samples wherever they show. Built through the same code as real
/// readings.
enum SampleData {
    static let sourceLabel = "Sample"

    static func cache(now: Date = .now) -> ReadingCache {
        let items = snapshots(now: now).map { snapshot in
            ReadingCache.Item(
                provider: RelayProvider(provider: snapshot.provider, status: .live(snapshot), checkedAt: now.addingTimeInterval(-120)),
                source: sourceLabel,
                history: history(for: snapshot, now: now)
            )
        }
        let ranked = UsageRanking.sorted(items, provider: \.provider) { item in
            UsageRanking.pace(for: item.provider, history: item.provider.primaryWindowID.flatMap { item.history[$0] }, now: now)
        }
        return ReadingCache(savedAt: now, isSample: true, items: ranked)
    }

    static func snapshots(now: Date = .now) -> [QuotaSnapshot] {
        let hour: TimeInterval = 3600
        let day: TimeInterval = 86_400
        let calendar = Calendar.gregorianUTC
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? now.addingTimeInterval(30 * day)

        func weekly(_ id: String, _ title: String, _ used: Double, resetsIn: TimeInterval) -> QuotaWindow {
            QuotaWindow(id: id, kind: .weekly, title: title, usedPercent: used, resetsAt: now.addingTimeInterval(resetsIn), windowSeconds: 7 * day)
        }
        func session(_ used: Double, resetsIn: TimeInterval) -> QuotaWindow {
            QuotaWindow(id: "session", kind: .session, title: "Session", usedPercent: used, resetsAt: now.addingTimeInterval(resetsIn), windowSeconds: 5 * hour)
        }
        func month(_ id: String, _ title: String, used: Double, limit: Double, unit: String) -> QuotaWindow {
            QuotaWindow(
                id: id, kind: .monthly, title: title, usedPercent: used / limit * 100, resetsAt: nextMonth, startsAt: monthStart,
                amount: QuotaAmount(used: used, limit: limit, remaining: limit - used, unit: unit)
            )
        }
        func snapshot(_ provider: Provider, _ windows: [QuotaWindow], plan: String? = nil, banked: BankedResets? = nil, extra: ExtraUsage? = nil) -> QuotaSnapshot {
            var snapshot = try! QuotaSnapshot.headlined(by: windows, provider: provider, fetchedAt: now.addingTimeInterval(-120), planLabel: plan, extra: extra)
            snapshot.banked = banked
            return snapshot
        }

        return [
            snapshot(.claude, [
                weekly("weekly", "Weekly", 64, resetsIn: 2 * day + 5 * hour),
                session(18, resetsIn: 2 * hour + 10 * 60),
                weekly("opus-weekly", "Opus weekly", 41, resetsIn: 2 * day + 5 * hour),
            ], plan: "Max"),
            snapshot(.openai, [
                weekly("weekly", "Weekly", 78, resetsIn: 3 * day + 2 * hour),
                session(22, resetsIn: 3 * hour + 40 * 60),
            ], plan: "Pro", banked: BankedResets(available: 2, expiries: [now.addingTimeInterval(5 * day), now.addingTimeInterval(12 * day)]),
               extra: ExtraUsage(title: "Credits", amount: QuotaAmount(remaining: 18.4, unit: "usd"))),
            snapshot(.grok, [weekly("primary", "Weekly", 23, resetsIn: 4 * day + 6 * hour)], plan: "SuperGrok Heavy"),
            snapshot(.cursor, [
                QuotaWindow(id: "cycle", kind: .billingCycle, title: "This cycle", usedPercent: 57, resetsAt: now.addingTimeInterval(14 * day), startsAt: now.addingTimeInterval(-16 * day)),
            ], plan: "Pro"),
            snapshot(.copilot, [month("premium_interactions", "Premium requests", used: 249, limit: 300, unit: "requests")], plan: "Copilot Pro"),
            snapshot(.kimiCode, [
                weekly("weekly", "Weekly", 12, resetsIn: 5 * day),
                session(62, resetsIn: 90 * 60),
            ], plan: "Allegretto"),
            snapshot(.zai, [
                weekly("weekly", "Weekly", 34, resetsIn: 3 * day),
                session(9, resetsIn: 4 * hour),
            ], plan: "GLM Coding Pro"),
            snapshot(.openrouter, [month("key-limit", "This month", used: 37.2, limit: 50, unit: "usd")]),
            snapshot(.deepseek, [
                QuotaWindow(id: "balance-usd", kind: .pool, title: "Balance", usedPercent: 0, resetsAt: nil, amount: QuotaAmount(remaining: 12.4, unit: "usd"), metered: false),
            ]),
            snapshot(.anthropicOrg, [month("spend", "This month", used: 312.5, limit: 1000, unit: "usd")]),
        ]
    }

    /// A week that climbs to each window's reading since it opened, busier by day, after the
    /// previous window peaked and reset.
    static func history(for snapshot: QuotaSnapshot, now: Date) -> [String: UsageHistory] {
        var result: [String: UsageHistory] = [:]
        for (index, window) in snapshot.windows.enumerated() where window.isMetered && window.kind != .session {
            guard let resetsAt = window.resetsAt,
                  let length = Pace.windowLength(kind: window.kind, resetsAt: resetsAt, startsAt: window.startsAt, windowSeconds: window.windowSeconds)
            else { continue }
            let previousPeak = min(95, window.usedPercent + 20 + Double(index * 7 % 15))
            result[window.id] = week(current: window.usedPercent, opened: resetsAt.addingTimeInterval(-length), length: length, previousPeak: previousPeak, now: now)
        }
        return result
    }

    static func week(current: Double, opened: Date, length: TimeInterval, previousPeak: Double, now: Date) -> UsageHistory {
        var history = UsageHistory(endingAt: now)
        let step = UsageHistory.step
        // Hourly activity: busy from 08:00 to 23:00, a trickle overnight.
        func activity(_ date: Date) -> Double {
            (8..<23).contains(Calendar.gregorianUTC.component(.hour, from: date)) ? 1 : 0.12
        }
        func work(from start: Date, to end: Date) -> Double {
            var total = 0.0
            var time = start
            while time < end {
                total += activity(time)
                time = time.addingTimeInterval(step)
            }
            return total
        }
        let previousOpened = opened.addingTimeInterval(-length)
        let soFar = max(work(from: opened, to: now), 1)
        let previousTotal = max(work(from: previousOpened, to: opened), 1)
        var time = history.start
        while time <= now {
            if time >= opened {
                history.record(current * work(from: opened, to: time) / soFar, at: time)
            } else if time >= previousOpened {
                history.record(previousPeak * work(from: previousOpened, to: time) / previousTotal, at: time)
            }
            time = time.addingTimeInterval(step)
        }
        return history
    }
}
