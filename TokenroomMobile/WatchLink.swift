import Foundation
import WatchConnectivity

/// Hands the latest readings to the Watch app while it's near, sooner than iCloud. The Watch
/// reads iCloud itself too, so nothing depends on this.
final class WatchLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchLink()
    static let readingsKey = "readings"

    private let lock = NSLock()
    /// The newest readings, kept until the session can take them: activation finishes after
    /// the first refresh, and the Watch app may be installed later.
    private var latest: Data?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Replaces what the Watch last got; only the newest readings matter.
    func send(_ cache: ReadingCache) {
        guard WCSession.isSupported(), let data = try? RelayEnvelope.encoder.encode(cache) else { return }
        lock.withLock { latest = data }
        flush()
    }

    private func flush() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let data = lock.withLock({ latest }) ?? Self.savedReadings()
        else { return }
        try? session.updateApplicationContext([Self.readingsKey: data])
    }

    /// The readings saved for widgets, for when this launch hasn't sent any: it only sends when
    /// they change, and a Watch app installed since would otherwise get nothing until then.
    /// Sample readings stay on the iPhone.
    private static func savedReadings() -> Data? {
        guard let url = ReadingCache.defaultURL, let cache = ReadingCache.load(from: url), !cache.isSample else { return nil }
        return try? RelayEnvelope.encoder.encode(cache)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        flush()
    }

    /// Pairing changed, or the Watch app was installed or removed.
    func sessionWatchStateDidChange(_ session: WCSession) {
        flush()
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // After switching watches, talk to the new one.
        session.activate()
    }
}
