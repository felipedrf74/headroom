import XCTest
@testable import Tokenroom

/// Files written by earlier builds, read by this one. Each golden fixture is exactly what an
/// older writer produced; they must keep decoding as long as a device might still hold one.
final class GoldenFixtureTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_337_600) // 2026-09-25 12:00 UTC

    private var folders: [URL] = []

    override func tearDown() {
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        folders = []
        super.tearDown()
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureURL(name))
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    /// A v1 Mac's record, from before providers carried a category and windows a pace.
    func testRelayEnvelopeFromAVersionOneMac() throws {
        let envelope = try RelayEnvelope.decode(fixture("relay-envelope-v1"))
        XCTAssertEqual(envelope.v, 1)
        XCTAssertTrue(envelope.isReadable)
        XCTAssertEqual(envelope.producer, "mac")
        XCTAssertEqual(envelope.appVersion, "2.0.0")
        XCTAssertEqual(envelope.checkedAt, now)
        XCTAssertEqual(envelope.providers.map(\.id), ["openai", "deepseek"])

        let openai = envelope.providers[0]
        XCTAssertEqual(openai.primaryWindow?.id, "weekly")
        XCTAssertEqual(openai.primaryWindow?.periodSec, 604_800)
        XCTAssertEqual(openai.windows.map(\.windowKind), [.weekly, .session])
        XCTAssertEqual(openai.banked, BankedResets(available: 2, expiries: [Date(timeIntervalSince1970: 1_790_769_600), Date(timeIntervalSince1970: 1_791_374_400)]))
        XCTAssertEqual(openai.extra?.amount.remaining, 18.4)
        XCTAssertNil(openai.category, "Older Macs don't say")
        XCTAssertTrue(openai.windows.allSatisfy { $0.pace == nil })

        let balance = try XCTUnwrap(envelope.providers[1].primaryWindow)
        XCTAssertFalse(balance.isMetered)
        XCTAssertNil(balance.resetsAt)
        XCTAssertEqual(balance.amount, QuotaAmount(remaining: 12.4, unit: "usd"))
        XCTAssertEqual(ReadingText.headline(balance), "\(AmountFormat.text(12.4, unit: "usd")) left")
        XCTAssertNil(envelope.providers[1].plan)

        let again = try RelayEnvelope.decode(envelope.encoded())
        XCTAssertEqual(again, envelope)
        XCTAssertEqual(again.materialHash, envelope.materialHash)
    }

    /// Hourly weeks from before balances and resets were kept.
    func testRelayHistoryFromAVersionOneMac() throws {
        let history = try RelayHistory.decode(fixture("relay-history-v1"))
        XCTAssertEqual(history.v, 1)
        XCTAssertEqual(Set(history.series.keys), ["claude/weekly", "openai/weekly"])
        let claude = try XCTUnwrap(history.series["claude/weekly"])
        XCTAssertEqual(claude.used.count, UsageHistory.capacity)
        XCTAssertEqual(claude.end, UsageHistory.hourStart(now).addingTimeInterval(UsageHistory.step), "The week ends with the hour of the reading")
        XCTAssertEqual(claude.points.last?.used, 64)
        XCTAssertEqual(claude.points.count, 58)
        XCTAssertNil(claude.amounts)
        XCTAssertNil(claude.resets)
        XCTAssertNil(claude.windowResetsAt)

        // A newer build keeps recording into an older week.
        var continued = claude
        XCTAssertTrue(continued.record(66, at: now.addingTimeInterval(3600)))
        XCTAssertTrue(continued.recordAmount(10, at: now.addingTimeInterval(3600)))
        XCTAssertEqual(continued.points.last?.used, 66)

        XCTAssertEqual(try RelayHistory.decode(history.encoded()), history)
    }

    /// The iPhone's widget cache as the first release saved it.
    func testWidgetCacheFromTheFirstRelease() throws {
        let cache = try XCTUnwrap(ReadingCache.load(from: fixtureURL("widget-cache-v1")))
        XCTAssertEqual(cache.v, ReadingCache.version)
        XCTAssertFalse(cache.isSample)
        XCTAssertEqual(cache.savedAt, now)
        XCTAssertEqual(cache.items.map(\.id), ["claude", "deepseek"])
        XCTAssertEqual(cache.items.map(\.source), ["Mac", "This iPhone"])
        XCTAssertEqual(cache.items[0].history["weekly"]?.points.last?.used, 64)
        XCTAssertTrue(cache.items[1].history.isEmpty)
        XCTAssertEqual(cache.checkedAt, now.addingTimeInterval(-120))
        XCTAssertEqual(cache.items[0].provider.windowToFollow(now: now)?.id, "session")

        let folder = try makeFolder()
        let url = folder.appendingPathComponent(ReadingCache.fileName)
        try cache.save(to: url)
        XCTAssertEqual(ReadingCache.load(from: url), cache)
        XCTAssertEqual(ReadingCache.load(from: url)?.materialHash, cache.materialHash)
    }

    /// Headroom 1.x's snapshot cache: dates since 2001, and Grok Bot's plan as a fake window.
    func testSnapshotCacheFromHeadroomOne() throws {
        let snapshots = SnapshotCache.decode(try fixture("snapshots-v1"))
        XCTAssertEqual(Set(snapshots.keys), [.grok, .grokBot, .claude, .openai, .cursor])

        let claude = try XCTUnwrap(snapshots[.claude])
        XCTAssertEqual(claude.fetchedAt, now.addingTimeInterval(-120))
        XCTAssertEqual(claude.resetsAt, Date(timeIntervalSince1970: 1_790_535_600))
        XCTAssertEqual(claude.windows.map(\.kind), [.weekly, .session])
        XCTAssertNil(claude.windows[0].windowSeconds, "1.x didn't keep window lengths")
        XCTAssertNil(claude.planLabel)
        XCTAssertNil(claude.source)

        let bot = try XCTUnwrap(snapshots[.grokBot])
        XCTAssertEqual(bot.planLabel, "SuperGrok Heavy", "The plan window becomes the plan")
        XCTAssertEqual(bot.windows.map(\.id), ["weekly"])
        XCTAssertEqual(bot.usedPercent, 8.708505, accuracy: 0.000001)

        let cursor = try XCTUnwrap(snapshots[.cursor])
        XCTAssertEqual(cursor.primaryTitle, "This cycle")
        XCTAssertEqual(cursor.windows.map(\.kind), [.billingCycle, .pool, .pool])
        XCTAssertEqual(snapshots[.grok]?.windows.map(\.id), ["primary", "on-demand"], "Only Grok Bot's plan window was a stand-in")

        let cache = SnapshotCache(directory: try makeFolder())
        cache.save(snapshots)
        XCTAssertEqual(cache.load(), snapshots)
    }
}
