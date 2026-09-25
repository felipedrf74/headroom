import Foundation

extension QuotaSnapshot {
    /// A budget the user sets turns amount-only windows into meters: spend against the budget,
    /// or a balance against the amount it started from. Metered windows are left alone. The budget
    /// is in the currency of the first amount (a DeepSeek account's USD row, a Moonshot China
    /// account's CNY), so rows in other currencies stay plain amounts.
    func applyingBudget(_ budget: Double?) -> QuotaSnapshot {
        guard let budget, budget > 0 else { return self }
        let currency = budgetUnit
        var copy = self
        copy.windows = windows.map { window in
            guard !window.isMetered, var amount = window.amount, amount.unit == currency else { return window }
            var metered = window
            if let used = amount.used, amount.remaining == nil {
                metered.usedPercent = JSONFlex.clampPercent(used / budget * 100)
            } else if let remaining = amount.remainingOrComputed {
                metered.usedPercent = JSONFlex.clampPercent((1 - remaining / budget) * 100)
                // What the meter shows: spent from the reference, not a lifetime total.
                amount.used = max(budget - remaining, 0)
            } else {
                return window
            }
            amount.limit = budget
            metered.amount = amount
            metered.metered = true
            return metered
        }
        if let first = copy.windows.first {
            copy.usedPercent = first.usedPercent
            copy.resetsAt = first.resetsAt
        }
        return copy
    }

    /// The unit a budget is set in: the first amount's, e.g. `usd` or `cny`.
    var budgetUnit: String? {
        windows.first { $0.amount != nil }?.amount?.unit
    }

    /// ISO code for the budget field: `CNY` for a yuan balance, else `USD`.
    var budgetCurrencyCode: String {
        budgetUnit == "cny" ? "CNY" : "USD"
    }
}
