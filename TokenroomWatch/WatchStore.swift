import Foundation
import Observation
import OSLog
import WatchConnectivity
import WatchKit
import WidgetKit

/// The Watch's readings: straight from iCloud, so it keeps working with the iPhone away, and
/// sooner from the iPhone over WatchConnectivity when it's near. No keys, no logins.
@Observable
@MainActor
final class WatchStore {
    static let backgroundTaskID = "app.tokenroom.watch.refresh"
    /// The Smart Stack widget's kind, in TokenroomWatchWidgets.
    static let resetSoonKind = "watch.resetSoon"
    /// How often to ask watchOS for a background refresh; it decides when.
    static let backgroundInterval: TimeInterval = 15 * 60

    enum Problem: Equatable {
        case noAccount
        case unreachable
    }

    private(set) var cache: ReadingCache?
    private(set) var isRefreshing = false
    /// Why there's nothing to show, when there isn't.
    private(set) var problem: Problem?
    /// Opened from a complication or the Smart Stack: the provider to show.
    var openedProvider: String?
    private var lastRefresh: Date?
    private let cacheURL = ReadingCache.defaultURL
    private let link = PhoneLink()

    init() {
        cache = cacheURL.flatMap(ReadingCache.load)
        #if DEBUG
        // Screenshots and simulator checks: `-sampleMode YES` shows sample readings.
        if UserDefaults.standard.bool(forKey: "sampleMode") {
            cache = SampleData.cache()
        }
        // `-TokenroomOpen tokenroom://provider/claude` opens a provider, for screenshots.
        if let link = UserDefaults.standard.string(forKey: "TokenroomOpen").flatMap(URL.init(string:)),
           case .provider(let id) = DeepLink(link) {
            openedProvider = id
        }
        #endif
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
        switch await RelayReadings.read(now: now) {
        case .readings(let fresh):
            problem = nil
            apply(fresh)
        case .noAccount:
            problem = cache == nil ? .noAccount : nil
        case .failed:
            problem = cache == nil ? .unreachable : nil
        case .unavailable:
            // A build without iCloud (no team): sample readings, clearly marked.
            if cache == nil {
                cache = SampleData.cache(now: now)
            }
            problem = nil
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
            // The Smart Stack widget picks its moments from the readings; let it look again.
            WidgetCenter.shared.invalidateRelevance(ofKind: WatchStore.resetSoonKind)
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
        guard let data = context[PhoneLink.readingsKey] as? Data else { return }
        let cache: ReadingCache
        do {
            cache = try RelayEnvelope.decoder.decode(ReadingCache.self, from: data)
        } catch {
            Self.logger.error("readings from iPhone unreadable: \(String(describing: error), privacy: .public)")
            return
        }
        guard let handler = onCache else { return }
        Task { @MainActor in handler(cache) }
    }

    private static let logger = Logger(subsystem: "app.tokenroom.watch", category: "phone-link")

    static let readingsKey = "readings"
}
