import XCTest
@testable import Tokenroom

/// The shared logic the iPhone app, widgets, and Watch run, tested on the Mac.
final class MobileLogicTests: XCTestCase {
    private let now = Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 12))!

    override func tearDown() {
        TokenroomHTTP.overrideSession(nil)
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func snapshot(_ provider: Provider = .claude, used: Double = 40, fetchedAt: Date? = nil) -> QuotaSnapshot {
        let window = QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: used, resetsAt: now.addingTimeInterval(3 * 86_400), windowSeconds: 7 * 86_400)
        return try! QuotaSnapshot.headlined(by: [window], provider: provider, fetchedAt: fetchedAt ?? now)
    }

    // MARK: Status rules

    func testFailuresKeepTheLastReadingWhereItHelps() {
        let cached = snapshot(fetchedAt: now.addingTimeInterval(-3600))
        XCTAssertEqual(ProviderStatus.failure(.unreachable, cached: cached, lastChecked: nil, now: now), .stale(cached))
        XCTAssertEqual(ProviderStatus.failure(.unreachable, cached: nil, lastChecked: nil, now: now), .unreachable(cached: nil))
        XCTAssertEqual(ProviderStatus.failure(.expired("x"), cached: cached, lastChecked: now.addingTimeInterval(-3600), now: now), .expired("x", cached: cached))
        XCTAssertEqual(ProviderStatus.failure(.expired("x"), cached: cached, lastChecked: now.addingTimeInterval(-25 * 3600), now: now), .expired("x", cached: nil), "A day after expiry the reading is gone")
        XCTAssertEqual(ProviderStatus.failure(.rateLimited(until: now.addingTimeInterval(5)), cached: cached, lastChecked: nil, now: now), .rateLimited(until: now.addingTimeInterval(60), cached: cached))
        XCTAssertEqual(ProviderStatus.failure(.signedOut("hint"), cached: cached, lastChecked: nil, now: now), .signedOut("hint"))
        XCTAssertTrue(ProviderStatus.signedOut("hint").isDisconnected)
        XCTAssertFalse(ProviderStatus.stale(cached).isDisconnected)
    }

    func testRelayProviderCarriesReadingsAndStates() {
        let live = RelayProvider(provider: .claude, status: .live(snapshot()), checkedAt: now)
        XCTAssertEqual(live.state, "live")
        XCTAssertEqual(live.monogram, Provider.claude.monogram)
        XCTAssertEqual(live.primaryWindow?.used, 40)
        XCTAssertEqual(live.primaryWindow?.windowKind, .weekly)
        XCTAssertNil(live.message)
        XCTAssertFalse(live.isDisconnected)

        let signedOut = RelayProvider(provider: .claude, status: .signedOut(Provider.claude.signInHint), checkedAt: nil)
        XCTAssertEqual(signedOut.message, Provider.claude.signInHint)
        XCTAssertTrue(signedOut.isDisconnected)
        XCTAssertFalse(RelayProvider(provider: .claude, status: .expired("x", cached: snapshot()), checkedAt: nil).isDisconnected, "An expired session with a recent reading still shows it")
    }

    // MARK: Publishing

    func testPublishPolicy() {
        var policy = RelayPublishPolicy()
        let envelope = RelayEnvelope(producer: "iphone", appVersion: "1", checkedAt: now, providers: [RelayProvider(provider: .openrouter, status: .live(snapshot(.openrouter)), checkedAt: now)])
        XCTAssertTrue(policy.isDue(envelope, now: now), "The first reading always goes out")
        policy.didSend(envelope, at: now)
        XCTAssertFalse(policy.isDue(envelope, now: now.addingTimeInterval(29 * 60)), "Unchanged usage waits for the heartbeat")
        XCTAssertTrue(policy.isDue(envelope, now: now.addingTimeInterval(30 * 60)))

        let changed = RelayEnvelope(producer: "iphone", appVersion: "1", checkedAt: now, providers: [RelayProvider(provider: .openrouter, status: .live(snapshot(.openrouter, used: 60)), checkedAt: now)])
        XCTAssertFalse(policy.isDue(changed, now: now.addingTimeInterval(4 * 60)))
        XCTAssertTrue(policy.isDue(changed, now: now.addingTimeInterval(5 * 60)))

        let expired = RelayEnvelope(producer: "iphone", appVersion: "1", checkedAt: now, providers: [RelayProvider(provider: .openrouter, status: .expired("x", cached: nil), checkedAt: now)])
        XCTAssertTrue(policy.isDue(expired, now: now.addingTimeInterval(61)), "A status change goes out after a minute")
        policy.reset()
        XCTAssertTrue(policy.isDue(envelope, now: now.addingTimeInterval(1)))
    }

    // MARK: Ranking

    func testRankingPutsUrgentMeteredReadingsFirst() {
        func provider(_ name: String, used: Double, metered: Bool = true) -> RelayProvider {
            RelayProvider(id: name, name: name, shortName: name, monogram: "X", tint: "#000000", state: "live", checkedAt: now, fetchedAt: now,
                          primaryWindowID: "w", windows: [RelayWindow(id: "w", kind: "weekly", title: "Weekly", used: used, resetsAt: now.addingTimeInterval(86_400), periodSec: 7 * 86_400, metered: metered)])
        }
        let calm = provider("Calm", used: 90)
        let urgent = provider("Urgent", used: 50)
        let balance = provider("Balance", used: 0, metered: false)
        let tie = provider("Also calm", used: 90)
        let paces: [String: Pace] = ["Urgent": Pace(verdict: .ahead, delta: 20, elapsedFraction: 0.3, resetsAt: now, runsOutAt: now, severity: .tight)]
        let sorted = UsageRanking.sorted([balance, calm, urgent, tie], provider: { $0 }, pace: { paces[$0.name] })
        XCTAssertEqual(sorted.map(\.name), ["Urgent", "Also calm", "Calm", "Balance"])
    }

    // MARK: Sample data

    func testSampleDataIsCompleteAndRanked() throws {
        let cache = SampleData.cache(now: now)
        XCTAssertTrue(cache.isSample)
        XCTAssertGreaterThanOrEqual(cache.items.count, 10)
        XCTAssertTrue(cache.items.allSatisfy { $0.provider.isLive && $0.source == SampleData.sourceLabel })
        XCTAssertEqual(Set(cache.items.map(\.id)).count, cache.items.count)
        XCTAssertEqual(cache.items.first?.id, Provider.openai.rawValue, "The sample that's ahead of pace leads")
        XCTAssertEqual(cache.items.last?.id, Provider.deepseek.rawValue, "A balance without a limit comes last")
        let claude = try XCTUnwrap(cache.items.first { $0.id == "claude" })
        let week = try XCTUnwrap(claude.history["weekly"])
        XCTAssertEqual(Double(week.used.last.flatMap { $0 } ?? 0), 64, accuracy: 1, "History ends at the current reading")
        XCTAssertNil(claude.history["session"], "Sessions are too short for a week's chart")
        XCTAssertEqual(SampleData.cache(now: now), cache, "The same moment gives the same samples")
    }

    // MARK: Widget cache

    func testReadingCacheRoundTripsAndIgnoresCheckTimes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(ReadingCache.fileName)
        let cache = SampleData.cache(now: now)
        try cache.save(to: url)
        XCTAssertEqual(ReadingCache.load(from: url), cache)

        var rechecked = cache
        rechecked.savedAt = now.addingTimeInterval(600)
        rechecked.items[0].provider.checkedAt = now.addingTimeInterval(600)
        XCTAssertEqual(rechecked.materialHash, cache.materialHash, "Widgets only reload when a reading changes")
        rechecked.items[0].provider.windows[0].used += 5
        XCTAssertNotEqual(rechecked.materialHash, cache.materialHash)

        var newer = cache
        newer.v = ReadingCache.version + 1
        try newer.save(to: url)
        XCTAssertNil(ReadingCache.load(from: url), "A cache from a newer version isn't misread")
    }

    // MARK: Deep links and text

    func testDeepLinksRoundTrip() {
        for link in [DeepLink.provider("claude"), .provider("kimiCode"), .settings, .keys] {
            XCTAssertEqual(DeepLink(link.url), link)
        }
        XCTAssertNil(DeepLink(URL(string: "https://example.com/provider/claude")!))
        XCTAssertNil(DeepLink(URL(string: "tokenroom://provider/")!))
    }

    func testReadingText() {
        let balance = RelayWindow(id: "b", kind: "pool", title: "Balance", used: 0, amount: QuotaAmount(remaining: 12.4, unit: "usd"), metered: false)
        XCTAssertEqual(ReadingText.headline(balance), 12.4.formatted(.currency(code: "USD")))
        let meter = RelayWindow(id: "w", kind: "weekly", title: "Weekly", used: 63.6, resetsAt: now.addingTimeInterval(2 * 86_400 + 3600))
        XCTAssertEqual(ReadingText.headline(meter), "64%")
        XCTAssertEqual(ReadingText.caption(meter, now: now), "Weekly · resets in 2d 1h")
        XCTAssertEqual(ReadingText.amountDetail(QuotaAmount(used: 249, limit: 300, remaining: 51, unit: "requests")), "249 of 300 requests")
        XCTAssertEqual(ReadingText.amountDetail(QuotaAmount(used: 312.5, unit: "usd")), "\(312.5.formatted(.currency(code: "USD"))) spent")
    }

    // MARK: Nothing secret leaves the device

    func testNoKeyMaterialReachesAnyRecord() async throws {
        let secret = "tr-test-QXJ7ZKP9WM"
        let body = Data(#"{"data":{"label":"sk-or-v1-abc...xyz","limit":50,"limit_remaining":12.8,"limit_reset":"monthly","usage":37.2,"is_free_tier":false}}"#.utf8)
        StubURLProtocol.handler = { _ in (200, body) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        TokenroomHTTP.overrideSession(URLSession(configuration: configuration))

        let keys = APIKeyStore(servicePrefix: "app.tokenroom.tests.\(UUID().uuidString).")
        defer { try? keys.remove(for: .openrouter) }
        try keys.save(secret, for: .openrouter, region: nil)
        let snapshot = try await APIKeyClient(provider: .openrouter, keys: keys).fetch().get()
        XCTAssertEqual(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer \(secret)", "The key is used for the request")

        let history = await MainActor.run { () -> RelayHistory in
            let store = HistoryStore(directory: nil)
            store.record(snapshot)
            return store.relayHistory(for: [.openrouter])
        }
        let provider = RelayProvider(provider: .openrouter, status: .live(snapshot), checkedAt: now)
        let envelope = RelayEnvelope(producer: "iphone", appVersion: "1", checkedAt: now, providers: [provider])
        let cache = ReadingCache(savedAt: now, isSample: false, items: [ReadingCache.Item(provider: provider, source: "This iPhone", history: history.series)])
        let payloads = [try envelope.encoded(), try history.encoded(), try RelayEnvelope.encoder.encode(cache)].map { String(decoding: $0, as: UTF8.self) }
        for payload in payloads {
            XCTAssertFalse(payload.contains("QXJ7"), "No part of the key")
            XCTAssertFalse(payload.contains("ZKP9"), "Not even its last four characters")
            XCTAssertFalse(payload.contains("sk-or"), "Nor the key's label from the response")
            XCTAssertFalse(payload.localizedCaseInsensitiveContains("bearer"))
        }
        XCTAssertTrue(payloads[0].contains("openrouter"), "The reading itself is there")
    }
}
