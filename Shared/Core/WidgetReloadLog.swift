import Foundation

/// When widgets rebuilt their timelines over the last two days, kept in the App Group so the
/// app can show it. WidgetKit budgets reloads; Tokenroom aims for fewer than 40 a day.
enum WidgetReloadLog {
    static let defaultsKey = "widgetReloads"
    static let keep: TimeInterval = 48 * 3600

    static func record(at date: Date = .now, defaults: UserDefaults = AppGroup.defaults) {
        let times = (defaults.array(forKey: defaultsKey) as? [Double] ?? [])
            .filter { date.timeIntervalSince1970 - $0 < keep }
        defaults.set(Array((times + [date.timeIntervalSince1970]).suffix(500)), forKey: defaultsKey)
    }

    /// Timelines built in the last 24 hours.
    static func count(lastDayBefore now: Date = .now, defaults: UserDefaults = AppGroup.defaults) -> Int {
        (defaults.array(forKey: defaultsKey) as? [Double] ?? [])
            .filter { now.timeIntervalSince1970 - $0 < 86_400 }
            .count
    }
}
