import XCTest
@testable import Tokenroom

/// What the widgets and complications decide, tested on the Mac: their time limits, when they
/// reload, what the Smart Stack offers, and how long samples last.
final class WidgetTests: XCTestCase {
    private let now = Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 12))!
    private var suites: [String] = []
    private var folders: [URL] = []

    override func tearDown() {
        suites.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        suites = []
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        folders = []
        super.tearDown()
    }

    /// A throwaway stand-in for the App Group's defaults. A fixed name: macOS keeps an empty
    /// preferences file for every name used.
    private func makeDefaults() -> UserDefaults {
        let name = "tokenroom.tests.\(Self.self).\(suites.count)"
        suites.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeCacheURL() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        folders.append(folder)
        return folder.appendingPathComponent(ReadingCache.fileName)
    }

    private func window(_ id: String, kind: String = "weekly", used: Double, resetsIn: TimeInterval, from start: Date? = nil) -> RelayWindow {
        RelayWindow(id: id, kind: kind, title: id.capitalized, used: used, resetsAt: (start ?? now).addingTimeInterval(resetsIn))
    }

    private func reading(_ windows: [RelayWindow], state: String = "live") -> RelayProvider {
        RelayProvider(
            id: "claude", name: "Claude", shortName: "Claude", monogram: "C", tint: "#D97757", state: state,
            checkedAt: now, fetchedAt: now, primaryWindowID: windows.first?.id, windows: windows
        )
    }

    /// The iPhone's handover is saved now even when it carries readings older than the Watch's.
    func testTheWatchKeepsNewerReadingsNotALaterSave() {
        func item(_ id: String, checked: Date) -> ReadingCache.Item {
            var provider = reading([window("weekly", used: 40, resetsIn: 86_400)])
            provider.id = id
            provider.checkedAt = checked
            return ReadingCache.Item(provider: provider, source: "Mac")
        }
        let own = ReadingCache(savedAt: now, isSample: false, items: [item("claude", checked: now), item("openai", checked: now)])
        let carried = ReadingCache(savedAt: now.addingTimeInterval(60), isSample: false, items: [item("claude", checked: now.addingTimeInterval(-3600)), item("openai", checked: now.addingTimeInterval(30))])
        XCTAssertFalse(carried.isAtLeastAsFresh(as: own), "Saved later, but with an hour-old Claude reading")
        let keyRemoved = ReadingCache(savedAt: now.addingTimeInterval(60), isSample: false, items: [item("openai", checked: now)])
        XCTAssertTrue(keyRemoved.isAtLeastAsFresh(as: own), "A provider gone doesn't hold it back")
        XCTAssertTrue(ReadingCache(savedAt: now, isSample: false, items: []).isAtLeastAsFresh(as: own), "Nor does iCloud data deleted")
    }

    /// MiniMax and OpenCode Go report seconds until the reset: worked out from the clock, the
    /// reset lands a second either side of the hour it's on.
    func testAResetWorkedOutFromTheClockIsTheSameReset() {
        let onTheHour = Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 17))!
        func cache(resetsAt reset: Date) -> ReadingCache {
            let provider = reading([RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: 40, resetsAt: reset)])
            return ReadingCache(savedAt: now, isSample: false, items: [ReadingCache.Item(provider: provider, source: "Mac")])
        }
        let early = cache(resetsAt: onTheHour.addingTimeInterval(-1))
        let late = cache(resetsAt: onTheHour.addingTimeInterval(1))
        XCTAssertEqual(early.reloadSignature, late.reloadSignature, "No widget reload for it")
        XCTAssertEqual(early.materialHash, late.materialHash, "Nor a send")
    }

    private func cache(savedAt: Date, used: Double, isSample: Bool = false) -> ReadingCache {
        let provider = reading([window("weekly", used: used, resetsIn: 3 * 86_400)])
        return ReadingCache(savedAt: savedAt, isSample: isSample, items: [ReadingCache.Item(provider: provider, source: "Mac")])
    }

    // MARK: Time limits

    func testACheckThatCarriesOnWhenCancelledIsGivenUpOnAtItsBudget() async {
        let started = Date()
        let result = await StubbornClient(delay: 3).fetchWithinBudget(0.1)
        XCTAssertEqual(result, .failure(.unreachable))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "A hard limit: the check isn't waited for, like iCloud's account status")
    }

    func testTheCheckLeftBehindIsCancelled() async {
        let cancelled = expectation(description: "The check that ran out of time is cancelled")
        let result = await SleepingClient { cancelled.fulfill() }.fetchWithinBudget(0.1)
        XCTAssertEqual(result, .failure(.unreachable))
        await fulfillment(of: [cancelled], timeout: 1)
    }

    func testCancellingTheCallerCancelsTheCheckAndReturnsAtOnce() async {
        let cancelled = expectation(description: "The check sees the caller's cancellation")
        let started = Date()
        let caller = Task {
            let result = await SleepingClient { cancelled.fulfill() }.fetchWithinBudget(10)
            return (result, Task.isCancelled)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        caller.cancel()
        let (result, isCancelled) = await caller.value
        XCTAssertEqual(result, .failure(.unreachable))
        XCTAssertTrue(isCancelled, "The Mac can still tell a cancelled pass's checks aren't attempts")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        await fulfillment(of: [cancelled], timeout: 1)
    }

    func testACallerCancelledOnArrivalGetsTheFallbackAtOnce() async {
        let caller = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return await TimeLimit.run(10, otherwise: -1) {
                await stubbornWait(3)
                return 1
            }
        }
        caller.cancel()
        let started = Date()
        let answer = await caller.value
        XCTAssertEqual(answer, -1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testAnAnswerInTimeIsKept() async throws {
        let window = QuotaWindow(id: "key-limit", kind: .monthly, title: "This month", usedPercent: 40, resetsAt: now.addingTimeInterval(86_400))
        let snapshot = try QuotaSnapshot.headlined(by: [window], provider: .openrouter, fetchedAt: now)
        let result = await QuickClient(result: .success(snapshot)).fetchWithinBudget(1)
        XCTAssertEqual(result, .success(snapshot))
        let nothing: Int? = await TimeLimit.run(1, otherwise: 5) { nil }
        XCTAssertNil(nothing, "Nil is an answer too, not a timeout")
    }

    // MARK: Complications' cache

    func testComplicationsShowTheirCacheWhenICloudIsSlow() async throws {
        let url = makeCacheURL()
        let saved = cache(savedAt: now.addingTimeInterval(-3600), used: 40)
        try saved.save(to: url)
        let fresh = cache(savedAt: now, used: 70)
        let started = Date()
        let shown = await RelayReadings.cache(at: url, maxAge: 15 * 60, budget: 0.1, now: now) {
            await stubbornWait(3)
            return fresh
        }
        XCTAssertEqual(shown, saved)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "The complication's seconds are a hard limit")
        XCTAssertEqual(ReadingCache.load(from: url), saved)
    }

    func testComplicationsSaveWhatICloudSends() async throws {
        let url = makeCacheURL()
        try cache(savedAt: now.addingTimeInterval(-3600), used: 40).save(to: url)
        let fresh = cache(savedAt: now, used: 70)
        let shown = await RelayReadings.cache(at: url, maxAge: 15 * 60, budget: 1, now: now) { fresh }
        XCTAssertEqual(shown, fresh)
        XCTAssertEqual(ReadingCache.load(from: url), fresh, "Saved for the next timeline")
    }

    func testARecentCacheIsShownWithoutReadingICloud() async throws {
        let url = makeCacheURL()
        let saved = cache(savedAt: now.addingTimeInterval(-60), used: 40)
        try saved.save(to: url)
        let read = expectation(description: "iCloud read")
        read.isInverted = true
        let shown = await RelayReadings.cache(at: url, maxAge: 15 * 60, budget: 1, now: now) {
            read.fulfill()
            return nil
        }
        XCTAssertEqual(shown, saved)
        await fulfillment(of: [read], timeout: 0.1)
    }

    func testAnOldSampleCacheAgesLikeAnyOther() {
        let maxAge: TimeInterval = 15 * 60
        let sample = SampleData.cache(now: now.addingTimeInterval(-3600))
        XCTAssertFalse(RelayReadings.isRecent(sample, maxAge: maxAge, now: now, keepsSamples: false), "Samples the iPhone once sent don't outlive sample mode")
        XCTAssertTrue(RelayReadings.isRecent(sample, maxAge: maxAge, now: now, keepsSamples: true), "Debug builds keep them, for screenshots")
        XCTAssertTrue(RelayReadings.isRecent(SampleData.cache(now: now), maxAge: maxAge, now: now.addingTimeInterval(60), keepsSamples: false))
        XCTAssertFalse(RelayReadings.isRecent(cache(savedAt: now.addingTimeInterval(-3600), used: 40), maxAge: maxAge, now: now, keepsSamples: true))
    }

    // MARK: Reloads

    func testTheReloadLogCountsEachWidgetOnItsOwn() {
        let defaults = makeDefaults()
        for minute in 0..<20 {
            WidgetReloadLog.record("usage-systemSmall-claude", at: now.addingTimeInterval(Double(minute - 60) * 60), defaults: defaults)
        }
        var reloads = 0
        for minute in 0..<25 {
            reloads = WidgetReloadLog.record("usage-systemMedium-automatic", at: now.addingTimeInterval(Double(minute - 60) * 60), defaults: defaults)
        }
        XCTAssertEqual(reloads, 25, "That widget's own count, this build included")
        XCTAssertEqual(WidgetReloadLog.count(lastDayBefore: now, defaults: defaults), 25, "The busiest widget, not all of them added up")
    }

    func testTheReloadLogForgetsAfterTwoDays() {
        let defaults = makeDefaults()
        defaults.set([now.timeIntervalSince1970], forKey: WidgetReloadLog.defaultsKey)
        XCTAssertEqual(WidgetReloadLog.count(lastDayBefore: now, defaults: defaults), 0, "An earlier build's single list doesn't say which widget reloaded")
        WidgetReloadLog.record("small", at: now.addingTimeInterval(-50 * 3600), defaults: defaults)
        WidgetReloadLog.record("medium", at: now.addingTimeInterval(-30 * 3600), defaults: defaults)
        XCTAssertEqual(WidgetReloadLog.record("small", at: now, defaults: defaults), 1)
        let kept = defaults.dictionary(forKey: WidgetReloadLog.defaultsKey) as? [String: [Double]]
        XCTAssertEqual(kept?["small"]?.count, 1, "Older than two days is dropped")
        XCTAssertEqual(kept?["medium"]?.count, 1)
        XCTAssertEqual(WidgetReloadLog.count(lastDayBefore: now, defaults: defaults), 1, "Kept for two days, counted for one")
    }

    func testAWidgetWaitsTheHourOnceItHasReloaded32TimesInADay() {
        let busy = [ReadingCache.Item(provider: reading([window("session", kind: "session", used: 90, resetsIn: 3 * 3600)]), source: "Mac")]
        XCTAssertEqual(WidgetSchedule.nextReload(after: now, items: busy, reloads: 31), now.addingTimeInterval(30 * 60))
        XCTAssertEqual(WidgetSchedule.nextReload(after: now, items: busy, reloads: 32), now.addingTimeInterval(3600))
        XCTAssertEqual(WidgetSchedule.nextReload(after: now, items: [], reloads: 1), now.addingTimeInterval(3600))
    }

    func testADayBusyThroughoutStaysWithinFortyReloadsAWidget() {
        let defaults = makeDefaults()
        var builds: [Date] = []
        var time = now
        while time < now.addingTimeInterval(3 * 86_400) {
            builds.append(time)
            let reloads = WidgetReloadLog.record("usage-systemSmall-automatic", at: time, defaults: defaults)
            // A session at 90% that always resets within hours.
            let session = window("session", kind: "session", used: 90, resetsIn: 3 * 3600, from: time)
            time = WidgetSchedule.nextReload(after: time, items: [ReadingCache.Item(provider: reading([session]), source: "Mac")], reloads: reloads)
        }
        let busiestDay = builds.map { start in builds.filter { $0 >= start && $0 < start.addingTimeInterval(86_400) }.count }.max() ?? 0
        XCTAssertLessThanOrEqual(busiestDay, 40, "WidgetKit's budget is about 40 a widget")
        XCTAssertGreaterThan(busiestDay, 24, "Still more often than hourly while busy")
    }

    // MARK: Smart Stack

    func testTheSmartStackOffersABusyWeekBesideASessionResettingSoon() throws {
        let provider = reading([
            window("weekly", used: 92, resetsIn: 3 * 86_400),
            window("session", kind: "session", used: 10, resetsIn: 3 * 3600),
        ])
        let spans = WidgetSchedule.relevance(of: provider, now: now)
        XCTAssertEqual(spans.map(\.window.id), ["session", "weekly"])
        let session = try XCTUnwrap(spans.first)
        XCTAssertEqual(session.span, now...now.addingTimeInterval(3 * 3600), "The session until its reset")
        let weekly = try XCTUnwrap(spans.last)
        XCTAssertEqual(weekly.span, now...now.addingTimeInterval(12 * 3600), "The week at 92% for the next half day")
    }

    func testTheSmartStackOffersEachWindowOnceAndOnlyLiveOnes() {
        let busySession = reading([window("session", kind: "session", used: 85, resetsIn: 2 * 3600)])
        XCTAssertEqual(WidgetSchedule.relevance(of: busySession, now: now).map(\.window.id), ["session"], "A session at 85% is offered once")

        let nearlySpent = reading([window("weekly", used: 91, resetsIn: 5 * 3600)])
        let spans = WidgetSchedule.relevance(of: nearlySpent, now: now)
        XCTAssertEqual(spans.map(\.window.id), ["weekly"])
        XCTAssertEqual(spans.first?.span, now...now.addingTimeInterval(5 * 3600), "Until the reset, not past it")

        XCTAssertTrue(WidgetSchedule.relevance(of: reading([window("weekly", used: 40, resetsIn: 3 * 86_400)]), now: now).isEmpty, "Nothing near a limit or a reset")
        XCTAssertTrue(WidgetSchedule.relevance(of: reading([window("weekly", used: 95, resetsIn: -60)]), now: now).isEmpty, "Nor a window that has already reset")
        XCTAssertTrue(WidgetSchedule.relevance(of: reading([window("weekly", used: 92, resetsIn: 3600)], state: "stale"), now: now).isEmpty, "Nor a reading that isn't live")
    }
}

/// Waits without noticing cancellation, like iCloud's account status.
private func stubbornWait(_ seconds: TimeInterval) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            continuation.resume()
        }
    }
}

/// A check that carries on when cancelled.
private struct StubbornClient: ProviderClient {
    var delay: TimeInterval
    var provider: Provider { .openrouter }

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        await stubbornWait(delay)
        return .failure(.parse)
    }
}

/// A check that stops when cancelled, and says so.
private struct SleepingClient: ProviderClient {
    var onCancel: @Sendable () -> Void
    var provider: Provider { .openrouter }

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        do {
            try await Task.sleep(nanoseconds: 10_000_000_000)
        } catch {
            onCancel()
        }
        return .failure(.parse)
    }
}

private struct QuickClient: ProviderClient {
    var result: Result<QuotaSnapshot, ProviderError>
    var provider: Provider { .openrouter }

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        result
    }
}
