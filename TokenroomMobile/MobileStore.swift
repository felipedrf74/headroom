import CloudKit
import Foundation
import Observation

/// Readings relayed through the user's iCloud by their Macs.
@Observable
@MainActor
final class MobileStore {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        /// This build has no iCloud container (unsigned build).
        case unavailable
        case noAccount
        case failed(String)
    }

    struct Entry: Identifiable {
        var provider: RelayProvider
        var sourceLabel: String
        var id: String { provider.id }
    }

    private(set) var sources: [CloudRelay.Source] = []
    private(set) var phase: Phase = .idle
    private(set) var lastRefresh: Date?
    /// Last CloudKit error, for debug diagnostics only.
    private var lastErrorDescription: String?
    private let relay: CloudRelay?

    init(containerIdentifier: String? = RelayAvailability.containerIdentifier) {
        relay = containerIdentifier.map(CloudRelay.init(containerIdentifier:))
        if relay == nil {
            phase = .unavailable
        }
    }

    /// One entry per provider. When several Macs report the same provider, the live reading
    /// checked most recently wins; a stale or expired one never hides another Mac's live one.
    var entries: [Entry] {
        var best: [String: (entry: Entry, live: Bool, checked: Date)] = [:]
        for source in sources {
            guard let envelope = source.envelope else { continue }
            for provider in envelope.providers {
                let live = provider.state == "live"
                let checked = provider.checkedAt ?? provider.fetchedAt ?? .distantPast
                let candidate = (Entry(provider: provider, sourceLabel: source.label), live, checked)
                if let current = best[provider.id] {
                    if (live && !current.live) || (live == current.live && checked > current.checked) {
                        best[provider.id] = candidate
                    }
                } else {
                    best[provider.id] = candidate
                }
            }
        }
        return best.values
            .map(\.entry)
            .sorted { ($0.provider.primaryWindow?.used ?? -1) > ($1.provider.primaryWindow?.used ?? -1) }
    }

    /// When the freshest Mac last checked, even if nothing changed.
    var lastChecked: Date? {
        sources.compactMap { $0.envelope?.checkedAt }.max()
    }

    var needsNewerApp: Bool {
        sources.contains(where: \.needsNewerApp)
    }

    func refresh() async {
        guard let relay else { return }
        phase = .loading
        do {
            guard try await relay.accountStatus() == .available else {
                phase = .noAccount
                return
            }
            sources = try await relay.sources()
            lastRefresh = .now
            lastErrorDescription = nil
            phase = .ready
        } catch {
            lastErrorDescription = (error as? CKError).map { "CKError \($0.code.rawValue): \($0.localizedDescription)" } ?? String(describing: type(of: error))
            phase = .failed("Couldn't reach iCloud.")
        }
        writeDiagnostics()
    }

    /// Debug builds leave a small summary (counts and provider IDs, no readings) in Caches,
    /// so a device run can be checked with `devicectl device copy from`.
    private func writeDiagnostics() {
        #if DEBUG
        let summary: [String: Any] = [
            "phase": String(describing: phase),
            "sources": sources.count,
            "providers": entries.map(\.provider.id),
            "lastChecked": lastChecked.map { Int($0.timeIntervalSince1970) } ?? 0,
            "at": Int(Date().timeIntervalSince1970),
            "error": lastErrorDescription ?? "",
        ]
        guard let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        else { return }
        try? data.write(to: folder.appendingPathComponent("relay-diagnostics.json"), options: .atomic)
        #endif
    }

    /// Subscribes to source changes (silent) and alert events (visible notifications).
    func prepareNotifications() async {
        guard let relay else { return }
        try? await relay.ensureSubscriptions()
    }
}
