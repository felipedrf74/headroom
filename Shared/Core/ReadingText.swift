import Foundation

/// Words for readings, shared by the Mac popover, the iPhone, widgets, and the Watch.
enum ReadingText {
    /// A balance or spend where a percentage would go: "$12.40", or "$312.50 spent".
    static func amountHeadline(_ amount: QuotaAmount) -> String? {
        if let remaining = amount.remainingOrComputed {
            return AmountFormat.text(remaining, unit: amount.unit)
        }
        return amount.used.map { "\(AmountFormat.text($0, unit: amount.unit)) spent" }
    }

    /// "249 of 300 requests", "$37.20 of $50.00", "$12.40 left", or "$312.50 spent".
    static func amountDetail(_ amount: QuotaAmount) -> String? {
        if let used = amount.used, let limit = amount.limit {
            let limitText = AmountFormat.text(limit, unit: amount.unit)
            let usedText = ["usd", "cny"].contains(amount.unit)
                ? AmountFormat.text(used, unit: amount.unit)
                : used.formatted(.number.precision(.fractionLength(0...1)))
            return "\(usedText) of \(limitText)"
        }
        if let remaining = amount.remaining {
            return "\(AmountFormat.text(remaining, unit: amount.unit)) left"
        }
        return amount.used.map { "\(AmountFormat.text($0, unit: amount.unit)) spent" }
    }

    static func banked(_ banked: BankedResets, now: Date = .now) -> String {
        let count = banked.available == 1 ? "1 banked reset" : "\(banked.available) banked resets"
        guard let next = banked.nextExpiry(after: now) else { return count }
        return "\(count) · next expires \(next.formatted(.dateTime.month(.abbreviated).day()))"
    }

    static func extra(_ extra: ExtraUsage) -> String? {
        guard extra.isEnabled, let remaining = extra.amount.remainingOrComputed else { return nil }
        return "\(extra.title) · \(AmountFormat.text(remaining, unit: extra.amount.unit)) left"
    }

    /// Used % for metered windows, the amount for balances without a limit.
    static func headline(_ window: RelayWindow?) -> String {
        guard let window else { return "—" }
        if !window.isMetered, let amount = window.amount {
            return amountHeadline(amount) ?? "—"
        }
        return "\(TokenroomFormat.percentText(window.used))%"
    }

    /// "resets in 2d 5h"; billing cycles say the day: "resets Oct 9".
    static func reset(_ window: RelayWindow, now: Date = .now) -> String? {
        guard let resetsAt = window.resetsAt else { return nil }
        if window.windowKind == .billingCycle || window.windowKind == .monthly {
            return resetsAt > now ? "resets \(resetsAt.formatted(.dateTime.month(.abbreviated).day()))" : "reset due"
        }
        return RelativeTime.resets(resetsAt, now: now)
    }

    /// "Weekly · resets in 2d 5h".
    static func caption(_ window: RelayWindow, now: Date = .now) -> String {
        [window.title, reset(window, now: now)].compactMap { $0 }.joined(separator: " · ")
    }
}
