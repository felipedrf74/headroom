import Foundation

struct SnapshotCache: Sendable {
    private var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(HeadroomIdentity.cacheFolderName, isDirectory: true)
    }

    private var fileURL: URL {
        directory.appendingPathComponent("snapshots.json")
    }

    func load() -> [Provider: QuotaSnapshot] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: QuotaSnapshot].self, from: data)
        else { return [:] }
        var result: [Provider: QuotaSnapshot] = [:]
        for (key, snapshot) in decoded {
            if let provider = Provider(rawValue: key) {
                result[provider] = snapshot
            }
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
}
