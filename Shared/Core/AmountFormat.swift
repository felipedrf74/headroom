import Foundation

/// Money and credit amounts for captions: "$12.40", "¥80", "1,240 credits".
enum AmountFormat {
    static func text(_ value: Double, unit: String, locale: Locale = .current) -> String {
        switch unit {
        case "usd":
            return value.formatted(.currency(code: "USD").locale(locale))
        case "cny":
            return value.formatted(.currency(code: "CNY").locale(locale))
        default:
            let number = value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
            return unit.isEmpty ? number : "\(number) \(unit)"
        }
    }
}
