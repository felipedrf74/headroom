import Foundation

/// When each widget rebuilt its timeline over the last two days, kept in the App Group so the
/// app can show it. WidgetKit budgets reloads per widget; Tokenroom aims for fewer than 40 a day.
enum WidgetReloadLog {
    static let defaultsKey = "widgetReloads"
    static let keep: TimeInterval = 48 * 3600

    /// Notes a timeline build and returns how many that widget has had in the last 24 hours,
    /// this one included.
    /// - Parameter widget: the widget's family and settings; widgets set up alike count as one.
    @discardableResult
    static func record(_ widget: String = "usage", at date: Date = .now, defaults: UserDefaults = AppGroup.defaults) -> Int {
        let now = date.timeIntervalSince1970
        var log = entries(defaults)
        log[widget, default: []].append(now)
        log = log.compactMapValues { times in
            let kept = times.filter { now - $0 < keep }.suffix(500)
            return kept.isEmpty ? nil : Array(kept)
        }
        defaults.set(log, forKey: defaultsKey)
        return lastDay(log[widget] ?? [], before: date)
    }

    /// Timelines the busiest widget built in the last 24 hours, since the budget is per widget:
    /// three widgets that each reload 20 times a day are all well within it.
    static func count(lastDayBefore now: Date = .now, defaults: UserDefaults = AppGroup.defaults) -> Int {
        entries(defaults).values.map { lastDay($0, before: now) }.max() ?? 0
    }

    /// Build times by widget. The single list earlier builds kept didn't say which widget
    /// reloaded, so it reads as empty.
    private static func entries(_ defaults: UserDefaults) -> [String: [Double]] {
        defaults.dictionary(forKey: defaultsKey) as? [String: [Double]] ?? [:]
    }

    private static func lastDay(_ times: [Double], before now: Date) -> Int {
        times.filter { now.timeIntervalSince1970 - $0 < 86_400 }.count
    }
}
