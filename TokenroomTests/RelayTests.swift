import XCTest
@testable import Tokenroom

final class RelayTests: XCTestCase {
    private func envelope(used: Double = 42, checkedAt: Date = Date(timeIntervalSince1970: 1_000)) -> RelayEnvelope {
        RelayEnvelope(
            producer: "mac",
            appVersion: "2.0.0",
            checkedAt: checkedAt,
            providers: [
                RelayProvider(
                    id: "claude",
                    name: "Claude",
                    shortName: "Claude",
                    monogram: "C",
                    tint: "#D97757",
                    state: "live",
                    message: nil,
                    checkedAt: checkedAt,
                    fetchedAt: checkedAt,
                    plan: nil,
                    primaryWindowID: "weekly",
                    windows: [
                        RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: used, resetsAt: Date(timeIntervalSince1970: 90_000)),
                        RelayWindow(id: "session", kind: "session", title: "Session", used: 12, resetsAt: nil),
                    ]
                ),
            ]
        )
    }

    func testEnvelopeRoundTripsWithEpochDates() throws {
        let original = envelope()
        let data = try original.encoded()
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(object["checkedAt"] as? Double, 1_000, "Dates travel as epoch seconds")
        XCTAssertEqual(try RelayEnvelope.decode(data), original)
    }

    func testUnknownFieldsAreIgnored() throws {
        var object = try JSONSerialization.jsonObject(with: envelope().encoded()) as! [String: Any]
        object["futureTopLevel"] = ["x": 1]
        var providers = object["providers"] as! [[String: Any]]
        providers[0]["futureField"] = "y"
        var windows = providers[0]["windows"] as! [[String: Any]]
        windows[0]["kind"] = "someFutureKind"
        providers[0]["windows"] = windows
        object["providers"] = providers
        let decoded = try RelayEnvelope.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.providers.first?.windows.first?.kind, "someFutureKind")
        XCTAssertTrue(decoded.isReadable)
    }

    func testNewerFormatIsDetected() throws {
        var newer = envelope()
        newer.v = 7
        newer.minReader = 5
        let decoded = try RelayEnvelope.decode(newer.encoded())
        XCTAssertFalse(decoded.isReadable)
    }

    func testMaterialHashIgnoresCheckTimesButSeesUsage() {
        let base = envelope()
        XCTAssertEqual(base.materialHash, envelope(checkedAt: Date(timeIntervalSince1970: 5_000)).materialHash)
        XCTAssertEqual(base.materialHash, envelope(used: 42.3).materialHash, "Sub-percent noise isn't a change")
        XCTAssertNotEqual(base.materialHash, envelope(used: 43).materialHash)
    }

    func testPrimaryWindowFallsBackToFirst() {
        var provider = envelope().providers[0]
        XCTAssertEqual(provider.primaryWindow?.id, "weekly")
        provider.primaryWindowID = "missing"
        XCTAssertEqual(provider.primaryWindow?.id, "weekly")
    }

    @MainActor
    func testStoreEnvelopeHasEnabledProvidersAndNoIdentity() throws {
        let suite = "tokenroom.tests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(["claude", "grokBot"], forKey: "enabledProviders")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = QuotaStore(
            settings: AppSettings(defaults: defaults),
            clients: [],
            cache: SnapshotCache(directory: folder)
        )
        let relayed = store.relayEnvelope(at: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(Set(relayed.providers.map(\.id)), ["claude", "grokBot"])
        XCTAssertEqual(relayed.producer, "mac")

        let json = String(decoding: try relayed.encoded(), as: UTF8.self).lowercased()
        for forbidden in ["token", "email", "@", "user_id", "account", "/users/"] {
            XCTAssertFalse(json.contains(forbidden), "Relay payload must not contain \(forbidden)")
        }
    }
}
