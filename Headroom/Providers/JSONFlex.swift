import Foundation

enum JSONFlex {
    private final class ISOBox: @unchecked Sendable {
        private let lock = NSLock()
        private let fractional: ISO8601DateFormatter
        private let basic: ISO8601DateFormatter

        init() {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            self.fractional = fractional
            let basic = ISO8601DateFormatter()
            basic.formatOptions = [.withInternetDateTime]
            self.basic = basic
        }

        func date(from string: String) -> Date? {
            lock.lock()
            defer { lock.unlock() }
            return fractional.date(from: string) ?? basic.date(from: string)
        }

        func string(from date: Date) -> String {
            lock.lock()
            defer { lock.unlock() }
            return fractional.string(from: date)
        }
    }

    private static let iso = ISOBox()

    static func object(from data: Data) throws -> [String: Any] {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let object = raw as? [String: Any] else {
            throw ProviderError.parse
        }
        return object
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            return number.doubleValue
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }

    static func cent(_ value: Any?) -> Double? {
        if let number = number(value) { return number }
        if let object = dictionary(value) {
            return number(object["val"]) ?? 0
        }
        return nil
    }

    static func date(_ value: Any?) -> Date? {
        if let number = number(value) {
            if number > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: number / 1000)
            }
            if number > 1_000_000_000 {
                return Date(timeIntervalSince1970: number)
            }
        }
        guard let string = string(value), !string.isEmpty else { return nil }
        if let millis = Double(string), millis > 1_000_000_000 {
            return date(millis)
        }
        return parseISO(string)
    }

    static func parseISO(_ string: String) -> Date? {
        iso.date(from: string)
    }

    static func isoString(from date: Date) -> String {
        iso.string(from: date)
    }

    static func clampPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }
}
