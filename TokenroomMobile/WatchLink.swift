import Foundation
import WatchConnectivity

/// Hands the latest readings to the Watch app while it's near, sooner than iCloud. The Watch
/// reads iCloud itself too, so nothing depends on this.
final class WatchLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchLink()
    static let readingsKey = "readings"

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Replaces what the Watch last got; only the newest readings matter.
    func send(_ cache: ReadingCache) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let data = try? RelayEnvelope.encoder.encode(cache)
        else { return }
        try? session.updateApplicationContext([Self.readingsKey: data])
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // After switching watches, talk to the new one.
        session.activate()
    }
}
