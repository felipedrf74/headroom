import Foundation
import Observation
import WatchConnectivity
import WatchKit
import WidgetKit

/// The Watch's readings: straight from iCloud, so it keeps working with the iPhone away, and
/// sooner from the iPhone over WatchConnectivity when it's near. No keys, no logins.
@Observable
@MainActor
final class WatchStore {
    static let backgroundTaskID = "app.tokenroom.watch.refresh"
    /// How often to ask watchOS for a background refresh; it decides when.
    static let backgroundInterval: TimeInterval = 15 * 60

    private(set) var cache: ReadingCache?
    private(set) var isRefreshing = false
    /// iCloud didn't answer and there's nothing saved to show.
    private(set) var failed = false
    private var lastRefresh: Date?
    private let cacheURL = ReadingCache.defaultURL
    private let link = PhoneLink()

    init() {
        cache = cacheURL.flatMap(ReadingCache.load)
        link.onCache = { [weak self] cache in
            self?.apply(cache)
        }
        link.activate()
    }

    var items: [ReadingCache.Item] {
        cache?.items ?? []
    }

    func item(id: String) -> ReadingCache.Item? {
        items.first { $0.id == id }
    }

    func refresh(force: Bool = false, now: Date = .now) async {
        guard !isRefreshing else { return }
        if !force, let lastRefresh, now.timeIntervalSince(lastRefresh) < 60 { return }
        isRefreshing = true
        defer { isRefreshing = false }
        lastRefresh = now
        if let fresh = await RelayReadings.fetch(now: now) {
            failed = false
            apply(fresh)
        } else {
            failed = cache == nil
        }
    }

    /// The newer of what's shown and `fresh`, saved for complications, which reload only when
    /// something they'd draw changed.
    func apply(_ fresh: ReadingCache) {
        if let cache, cache.savedAt > fresh.savedAt { return }
        let changed = fresh.materialHash != cache?.materialHash
        cache = fresh
        if let cacheURL {
            try? fresh.save(to: cacheURL)
        }
        if changed {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func scheduleBackgroundRefresh(now: Date = .now) {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: now.addingTimeInterval(Self.backgroundInterval),
            userInfo: Self.backgroundTaskID as NSString
        ) { _ in }
    }
}

/// Readings the iPhone hands over while it's near.
final class PhoneLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    /// Set once, before activation.
    var onCache: (@MainActor (ReadingCache) -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        // What the iPhone sent while this app wasn't running.
        deliver(session.receivedApplicationContext)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        deliver(applicationContext)
    }

    private func deliver(_ context: [String: Any]) {
        guard let data = context[PhoneLink.readingsKey] as? Data,
              let cache = try? RelayEnvelope.decoder.decode(ReadingCache.self, from: data),
              let handler = onCache
        else { return }
        Task { @MainActor in handler(cache) }
    }

    static let readingsKey = "readings"
}
