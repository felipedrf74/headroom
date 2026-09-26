import Foundation

/// A week of hourly usage per window, kept in `history.json` next to the readings cache (the Mac's
/// Application Support folder, the iPhone's App Group), plus the last six hours of raw readings in
/// memory for pace. Percentages only.
@MainActor
final class HistoryStore {
    /// Raw readings kept for pace: six hours at a five-minute refresh.
    static let recentCapacity = 72

    private(set) var weeks: [String: UsageHistory] = [:]
    private var recent: [String: [(date: Date, used: Double)]] = [:]
    private var dirty = false
    private let fileURL: URL?

    init(directory: URL?) {
        fileURL = directory?.appendingPathComponent(Self.fileName)
        let saved = Self.loadSaved(from: directory)
        weeks = Self.migrated(saved)
        // Written back under the new keys with the next save.
        dirty = weeks != saved
    }

    nonisolated static let fileName = "history.json"

    /// The saved weeks, keyed `provider/window`, for readers that don't record (widgets).
    nonisolated static func load(from directory: URL?) -> [String: UsageHistory] {
        migrated(loadSaved(from: directory))
    }

    private nonisolated static func loadSaved(from directory: URL?) -> [String: UsageHistory] {
        guard let url = directory?.appendingPathComponent(fileName),
              let data = try? Data(contentsOf: url),
              let saved = try? RelayEnvelope.decoder.decode([String: UsageHistory].self, from: data)
        else { return [:] }
        return saved
    }

    /// Copilot's month read with a token was `ai_credits` in 2.0.0; its week carries on under the
    /// ID the login and the token both use now.
    private nonisolated static func migrated(_ saved: [String: UsageHistory]) -> [String: UsageHistory] {
        let copilot = Provider.copilot.rawValue
        let old = RelayHistory.key(provider: copilot, window: CopilotBilling.legacyWindowID)
        guard let week = saved[old] else { return saved }
        var weeks = saved
        weeks[old] = nil
        let current = RelayHistory.key(provider: copilot, window: CopilotBilling.windowID)
        if weeks[current] == nil {
            weeks[current] = week
        }
        return weeks
    }

    func record(_ snapshot: QuotaSnapshot) {
        record(snapshot, now: .now)
    }

    /// - Parameter now: this device's clock. A reading dated more than an hour after it (a
    ///   file's time, or the clock set back since) is left out: it would move the week past
    ///   every later reading.
    func record(_ snapshot: QuotaSnapshot, now: Date) {
        guard snapshot.fetchedAt <= now.addingTimeInterval(UsageHistory.step) else { return }
        if Self.fold(snapshot, into: &weeks, now: now) {
            dirty = true
        }
        for window in snapshot.windows {
            let key = RelayHistory.key(provider: snapshot.provider.rawValue, window: window.id)
            var samples = recent[key] ?? []
            if samples.last?.date != snapshot.fetchedAt {
                samples.append((snapshot.fetchedAt, window.usedPercent))
                if samples.count > Self.recentCapacity {
                    samples.removeFirst(samples.count - Self.recentCapacity)
                }
                recent[key] = samples
            }
        }
        prune(now: now)
    }

    /// One reading into the weeks it belongs to; whether anything changed. The store records
    /// through it, and widgets use it to show readings the app hasn't taken in yet.
    nonisolated static func fold(_ snapshot: QuotaSnapshot, into weeks: inout [String: UsageHistory], now: Date) -> Bool {
        guard snapshot.fetchedAt <= now.addingTimeInterval(UsageHistory.step) else { return false }
        var anyChanged = false
        for window in snapshot.windows {
            let key = RelayHistory.key(provider: snapshot.provider.rawValue, window: window.id)
            var week = weeks[key] ?? UsageHistory(endingAt: snapshot.fetchedAt)
            // A week that ran ahead of the clock takes every new reading for one older than
            // itself, so it starts over.
            if week.start > now {
                week = UsageHistory(endingAt: snapshot.fetchedAt)
            }
            var changed = week.record(window.usedPercent, at: snapshot.fetchedAt)
            if let amount = window.amount, let remaining = amount.remainingOrComputed, amount.unit == "usd" || amount.unit == "cny" {
                changed = week.recordAmount(remaining, at: snapshot.fetchedAt) || changed
            }
            let length = window.resetsAt.flatMap {
                Pace.windowLength(kind: window.kind, resetsAt: $0, startsAt: window.startsAt, windowSeconds: window.windowSeconds)
            }
            changed = week.recordResetTime(window.resetsAt, used: window.usedPercent, length: length, at: snapshot.fetchedAt) || changed
            if changed || weeks[key] == nil {
                weeks[key] = week
                anyChanged = true
            }
        }
        return anyChanged
    }

    // MARK: Readings widgets took

    /// Readings widgets took with this iPhone's keys, waiting for the app to record them: a file
    /// per provider and hour, holding the hour's latest reading. The app is the one writer of
    /// `history.json`, so a widget never races it for that file, and widgets write files of their
    /// own rather than rewriting a shared list.
    nonisolated static let pendingFolderName = "history-pending"
    /// Where the app moves queued readings while it records them: one a widget queues meanwhile
    /// waits for the next refresh, and ones a refresh cut short are recorded by the next.
    nonisolated static let takingFolderName = "history-taking"

    /// The readings waiting, oldest first.
    nonisolated static func pending(in directory: URL?) -> [QuotaSnapshot] {
        guard let directory else { return [] }
        let files = queuedFiles(in: directory.appendingPathComponent(takingFolderName))
            + queuedFiles(in: directory.appendingPathComponent(pendingFolderName))
        return files.compactMap(queuedSnapshot(at:)).sorted { $0.fetchedAt < $1.fetchedAt }
    }

    /// Adds readings a widget took, for the app to record the next time it refreshes. A later
    /// reading of a provider in the same hour takes an earlier one's place, and readings older
    /// than the week history holds are dropped.
    nonisolated static func queue(_ snapshots: [QuotaSnapshot], in directory: URL?, now: Date = .now) {
        guard !snapshots.isEmpty, let directory else { return }
        let folder = directory.appendingPathComponent(pendingFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for snapshot in snapshots {
            let hour = Int(UsageHistory.hourStart(snapshot.fetchedAt).timeIntervalSince1970)
            let url = folder.appendingPathComponent("\(snapshot.provider.rawValue)-\(hour).json")
            if let queued = queuedSnapshot(at: url), queued.fetchedAt > snapshot.fetchedAt { continue }
            guard let data = try? RelayEnvelope.encoder.encode(snapshot) else { continue }
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        let cutoff = now.addingTimeInterval(-Double(UsageHistory.capacity) * UsageHistory.step)
        for url in queuedFiles(in: folder) where (queuedHour(of: url) ?? .distantPast) < cutoff {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private nonisolated static func queuedFiles(in folder: URL) -> [URL] {
        let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        return (files ?? []).filter { $0.pathExtension == "json" }
    }

    private nonisolated static func queuedSnapshot(at url: URL) -> QuotaSnapshot? {
        (try? Data(contentsOf: url)).flatMap { try? RelayEnvelope.decoder.decode(QuotaSnapshot.self, from: $0) }
    }

    /// The hour a queued reading's file is named for.
    private nonisolated static func queuedHour(of url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let dash = name.lastIndex(of: "-"), let seconds = TimeInterval(name[name.index(after: dash)...]) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// The saved weeks with the readings widgets took since, for a widget to show.
    nonisolated static func loadWithPending(from directory: URL?, now: Date) -> [String: UsageHistory] {
        var weeks = load(from: directory)
        for snapshot in pending(in: directory) {
            _ = fold(snapshot, into: &weeks, now: now)
        }
        return weeks
    }

    /// Records the readings widgets took, oldest first. Called before this refresh's own, which
    /// are newer. They're moved aside first, so one a widget queues meanwhile stays queued, and
    /// deleted only once the week is saved, so a refresh cut short loses none.
    func takePending(now: Date = .now) {
        guard let directory = fileURL?.deletingLastPathComponent() else { return }
        let fileManager = FileManager.default
        let taking = directory.appendingPathComponent(Self.takingFolderName, isDirectory: true)
        let queued = Self.queuedFiles(in: directory.appendingPathComponent(Self.pendingFolderName))
        if !queued.isEmpty {
            try? fileManager.createDirectory(at: taking, withIntermediateDirectories: true)
            for url in queued {
                let destination = taking.appendingPathComponent(url.lastPathComponent)
                // One left by a refresh cut short is an earlier reading of the same hour.
                try? fileManager.removeItem(at: destination)
                try? fileManager.moveItem(at: url, to: destination)
            }
        }
        let taken = Self.queuedFiles(in: taking)
        guard !taken.isEmpty else { return }
        for snapshot in taken.compactMap(Self.queuedSnapshot(at:)).sorted(by: { $0.fetchedAt < $1.fetchedAt }) {
            record(snapshot, now: now)
        }
        saveIfNeeded()
        for url in taken {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Forgets windows with no reading in the last week: ones a provider stopped reporting,
    /// or providers turned off. They'd otherwise be saved and relayed forever.
    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Double(UsageHistory.capacity) * UsageHistory.step)
        let gone = weeks.compactMap { key, week in week.end <= cutoff ? key : nil }
        guard !gone.isEmpty else { return }
        for key in gone {
            weeks[key] = nil
            recent[key] = nil
        }
        dirty = true
    }

    /// Readings for pace: raw recent ones, else the hourly week.
    func samples(provider: Provider, window: String) -> [(date: Date, used: Double)] {
        let key = RelayHistory.key(provider: provider.rawValue, window: window)
        if let recent = recent[key], recent.count >= 3 {
            return recent
        }
        return weeks[key]?.points ?? []
    }

    /// One provider's weeks, keyed by window ID.
    func weeks(for provider: Provider) -> [String: UsageHistory] {
        let prefix = RelayHistory.key(provider: provider.rawValue, window: "")
        var result: [String: UsageHistory] = [:]
        for (key, week) in weeks where key.hasPrefix(prefix) {
            result[String(key.dropFirst(prefix.count))] = week
        }
        return result
    }

    /// History to relay, limited to the given providers.
    func relayHistory(for providers: [Provider]) -> RelayHistory {
        let ids = Set(providers.map(\.rawValue))
        return RelayHistory(series: weeks.filter { key, week in
            guard let provider = key.split(separator: "/").first else { return false }
            return ids.contains(String(provider)) && !week.isEmpty
        })
    }

    func saveIfNeeded() {
        guard dirty, let fileURL else { return }
        dirty = false
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? RelayEnvelope.encoder.encode(weeks) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
