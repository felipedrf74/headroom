import Foundation

enum RelativeTime {
    static func resets(_ date: Date?, now: Date = .now) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "reset due" }
        let days = Int(seconds) / 86_400
        let hours = (Int(seconds) % 86_400) / 3_600
        let minutes = (Int(seconds) % 3_600) / 60
        if days > 0 { return "resets in \(days)d \(hours)h" }
        if hours > 0 { return "resets in \(hours)h \(minutes)m" }
        return "resets in \(max(minutes, 1))m"
    }

    static func ago(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "never" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 45 { return "just now" }
        if seconds < 3_600 { return "\(max(1, Int(seconds / 60)))m ago" }
        if seconds < 86_400 { return "\(max(1, Int(seconds / 3_600)))h ago" }
        return "\(max(1, Int(seconds / 86_400)))d ago"
    }

    static func cycleDay(_ date: Date?) -> String? {
        guard let date else { return nil }
        return "resets \(date.formatted(.dateTime.day().month(.abbreviated)))"
    }
}
