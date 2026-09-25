import Foundation

struct SnapshotCache: Sendable {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(TokenroomIdentity.cacheFolderName, isDirectory: true)
    }

    var fileURL: URL {
        directory.appendingPathComponent("snapshots.json")
    }

    /// When each provider last answered, which a reading's own time can't say: an unchanged
    /// reading keeps the time it first appeared.
    var checkedURL: URL {
        directory.appendingPathComponent("checked.json")
    }

    func loadChecked() -> [Provider: Date] {
        guard let data = try? Data(contentsOf: checkedURL),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data)
        else { return [:] }
        var result: [Provider: Date] = [:]
        for (key, date) in decoded {
            if let provider = Provider(rawValue: key) {
                result[provider] = date
            }
        }
        return result
    }

    func saveChecked(_ checked: [Provider: Date]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = Dictionary(uniqueKeysWithValues: checked.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: checkedURL, options: .atomic)
    }

    func load() -> [Provider: QuotaSnapshot] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return Self.decode(data)
    }

    /// Decodes entry by entry: an unknown provider or one bad entry never drops the rest.
    static func decode(_ data: Data) -> [Provider: QuotaSnapshot] {
        guard let decoded = try? JSONDecoder().decode([String: LenientEntry].self, from: data) else {
            return [:]
        }
        var result: [Provider: QuotaSnapshot] = [:]
        for (key, entry) in decoded {
            guard let provider = Provider(rawValue: key), let snapshot = entry.snapshot else { continue }
            result[provider] = migrated(snapshot)
        }
        return result
    }

    func save(_ snapshots: [Provider: QuotaSnapshot]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var payload: [String: QuotaSnapshot] = [:]
        for (provider, snapshot) in snapshots {
            payload[provider.rawValue] = snapshot
        }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Headroom 1.x stored Grok Bot's plan name as a fake "plan" window.
    private static func migrated(_ snapshot: QuotaSnapshot) -> QuotaSnapshot {
        guard let index = snapshot.windows.firstIndex(where: { $0.id == "plan" && $0.kind == .pool }) else {
            return snapshot
        }
        var copy = snapshot
        let window = copy.windows.remove(at: index)
        if copy.planLabel == nil {
            copy.planLabel = window.title
        }
        return copy
    }

    private struct LenientEntry: Decodable {
        let snapshot: QuotaSnapshot?

        init(from decoder: Decoder) throws {
            snapshot = try? QuotaSnapshot(from: decoder)
        }
    }
}
