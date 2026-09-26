import Foundation

extension QuotaSnapshot {
    /// A budget the user sets turns amount-only windows into meters: spend against the budget,
    /// or a balance against the amount it started from. Metered windows are left alone. The budget
    /// is in the currency of the first amount (a DeepSeek account's USD row, a Moonshot China
    /// account's CNY), so rows in other currencies stay plain amounts. An organization's monthly
    /// budget only measures spend: an xAI team's prepaid credits stay an amount.
    func applyingBudget(_ budget: Double?) -> QuotaSnapshot {
        guard let budget, budget > 0 else { return self }
        let currency = budgetUnit
        let measuresBalances = provider.category != .orgSpend
        var copy = self
        copy.windows = windows.map { window in
            guard !window.isMetered, let amount = window.amount, amount.unit == currency,
                  let meter = amount.meter(against: budget, measuresBalances: measuresBalances)
            else { return window }
            var metered = window
            metered.usedPercent = meter.used
            metered.amount = meter.amount
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

extension QuotaAmount {
    /// This amount measured against a budget: spend against it, or a balance against the amount
    /// it started from. Nil when the budget doesn't measure it (a balance, for an organization's
    /// monthly budget).
    func meter(against budget: Double, measuresBalances: Bool) -> (used: Double, amount: QuotaAmount)? {
        var amount = self
        let used: Double
        if let spent = self.used, remaining == nil {
            used = JSONFlex.clampPercent(spent / budget * 100)
        } else if measuresBalances, let remaining = remainingOrComputed {
            used = JSONFlex.clampPercent((1 - remaining / budget) * 100)
            // What the meter shows: spent from the reference, not a lifetime total.
            amount.used = max(budget - remaining, 0)
        } else {
            return nil
        }
        amount.limit = budget
        amount.isBudget = true
        return (used, amount)
    }
}

extension RelayProvider {
    /// A saved reading with the budget or reference set now rather than the one it was saved
    /// with: a stand-in for a provider this launch hasn't read (its calls are spaced, or it's
    /// rate limited) shows a new budget at once. Windows metered against a budget are measured
    /// again; the provider's own meters are left alone.
    func applyingBudget(_ budget: Double?) -> RelayProvider {
        var copy = self
        copy.windows = windows.map { window in
            guard var amount = window.amount, amount.isBudget == true else { return window }
            var plain = window
            amount.limit = nil
            amount.isBudget = nil
            if amount.remaining != nil {
                // Worked out from the old reference.
                amount.used = nil
            }
            plain.amount = amount
            plain.used = 0
            plain.metered = false
            return plain
        }
        guard let budget, budget > 0 else { return copy }
        let currency = copy.windows.first { $0.amount != nil }?.amount?.unit
        let measuresBalances = category != ProviderDescriptor.Category.orgSpend.rawValue
        copy.windows = copy.windows.map { window in
            guard !window.isMetered, let amount = window.amount, amount.unit == currency,
                  let meter = amount.meter(against: budget, measuresBalances: measuresBalances)
            else { return window }
            var metered = window
            metered.used = meter.used
            metered.amount = meter.amount
            metered.metered = true
            return metered
        }
        return copy
    }
}
