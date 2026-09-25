import Foundation

extension QuotaSnapshot {
    /// A budget the user sets turns amount-only windows into meters: spend against the budget,
    /// or a balance against the amount it started from. Metered windows are left alone.
    func applyingBudget(_ budget: Double?) -> QuotaSnapshot {
        guard let budget, budget > 0 else { return self }
        var copy = self
        copy.windows = windows.map { window in
            guard !window.isMetered, var amount = window.amount else { return window }
            var metered = window
            if let used = amount.used, amount.remaining == nil {
                metered.usedPercent = JSONFlex.clampPercent(used / budget * 100)
            } else if let remaining = amount.remainingOrComputed {
                metered.usedPercent = JSONFlex.clampPercent((1 - remaining / budget) * 100)
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
}
