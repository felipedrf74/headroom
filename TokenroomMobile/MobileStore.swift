import BackgroundTasks
import CloudKit
import Foundation
import Observation
import UIKit
import UserNotifications
import WidgetKit
import os

/// Everything the iPhone shows: readings your Macs relay through iCloud, providers read with keys
/// added on this iPhone, or sample data. Saves the merged readings for widgets and, while this
/// iPhone has keys, relays its own readings to your other devices. Readings only: keys never
/// leave this iPhone's Keychain.
@Observable
@MainActor
final class MobileStore {
    enum RelayPhase: Equatable {
        case idle
        case loading
        case ready
        /// This build has no iCloud container (an unsigned build).
        case unavailable
        case noAccount
        case failed(String)
    }

    /// One provider to show, and where its reading came from.
    struct Reading: Identifiable, Equatable {
        var provider: RelayProvider
        var source: String
        /// A week of hourly usage per window ID, when the source sent it.
        var history: [String: UsageHistory]
        var pace: Pace?

        var id: String { provider.id }

        init(_ item: ReadingCache.Item, now: Date = .now) {
            provider = item.provider
            source = item.source
            history = item.history
            pace = ReadingAssembler.pace(for: item, now: now)
        }
    }

    enum Keys {
        static let sourceID = "relaySourceID"
        static let sampleMode = "sampleMode"
        static let onboarded = "onboarded"
        static let budgets = "budgets"
        static let published = "relayPublished"
        static let alertPreferences = "alertPreferences"
        static let alertPreferencesShared = "alertPreferencesShared"
        static let alertPreferencesBase = "alertPreferencesBase"
        static let prunedAt = "eventsPrunedAt"
        static let alertsFiltered = "alertSubscriptionFiltered"
        static let unclaimedAlerts = "unclaimedAlerts"
        static let keyedProviders = "keyedProviders"
        static let followedTimeZone = "followedTimeZone"
    }

    static let localLabel = "This iPhone"
    /// Coming back to the app refreshes once this much time has passed.
    static let foregroundInterval: TimeInterval = 60
    /// How long a refresh asked for during another waits for the pass that follows it.
    static let passWait: TimeInterval = 120
    static let backgroundTaskID = "app.tokenroom.refresh"
    /// How often to ask iOS for a background refresh. iOS decides when it actually runs.
    static let backgroundInterval: TimeInterval = 30 * 60

    private(set) var relayPhase: RelayPhase = .idle
    /// Other collectors' records; this iPhone's own record is left out.
    private(set) var relaySources: [CloudRelay.Source] = []
    private(set) var relayHistories: [String: RelayHistory] = [:]
    private(set) var localStatuses: [Provider: ProviderStatus] = [:]
    private(set) var localCheckedAt: [Provider: Date] = [:]
    /// Connected providers, most urgent first.
    private(set) var readings: [Reading] = []
    /// Providers a Mac reports as signed out or not on a plan.
    private(set) var disconnected: [Reading] = []
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false
    /// Providers with a key on this iPhone.
    private(set) var keyedProviders: [Provider] = []

    var sampleMode: Bool {
        didSet {
            defaults.set(sampleMode, forKey: Keys.sampleMode)
            rebuild()
        }
    }

    var hasOnboarded: Bool {
        didSet { defaults.set(hasOnboarded, forKey: Keys.onboarded) }
    }

    /// Which alerts to send, and quiet hours. Shared through iCloud with Macs, which can change
    /// them too; the newer copy wins.
    var alertPreferences: AlertPreferences {
        didSet {
            // @Observable moves this observer to the backing storage, so stamping the change
            // below comes back through here; the flag ends that second pass at once.
            guard alertPreferences != oldValue, !stampingPreferences else { return }
            if !adoptingPreferences, !followingTimeZone {
                stampingPreferences = true
                alertPreferences.touch()
                stampingPreferences = false
            }
            if let data = try? JSONEncoder().encode(alertPreferences) {
                defaults.set(data, forKey: Keys.alertPreferences)
            }
            guard !adoptingPreferences else { return }
            defaults.set(false, forKey: Keys.alertPreferencesShared)
            let choicesChanged = !followingTimeZone
            Task {
                await shareAlertPreferences()
                if choicesChanged {
                    await prepareNotifications()
                }
            }
        }
    }
    /// Set while taking a newer copy from iCloud, so it isn't stamped and sent back.
    @ObservationIgnored private var adoptingPreferences = false
    /// Set while stamping a change made on this iPhone with its time.
    @ObservationIgnored private var stampingPreferences = false
    /// Set while quiet hours move to this iPhone's time zone: shared, but not a change of choices.
    @ObservationIgnored private var followingTimeZone = false

    let keys: APIKeyStore
    let sourceID: String
    private let relay: CloudRelay?
    private let defaults: UserDefaults
    private let history: HistoryStore
    private let cacheURL: URL?
    private var publishPolicy = RelayPublishPolicy()
    private var lastHistoryHour: Date?
    private var lastCacheHash: Int?
    private var rateLimitedUntil: [Provider: Date] = [:]
    /// When each key provider was last called, shared with the widgets.
    private let keyGate: KeyFetchGate
    /// iCloud asked to wait (rate limit, busy); reads and writes pause until then.
    private var relayRetryAt: Date?
    private var alertLedger: AlertLedger
    private var relayEvents: [(id: String, createdAt: Date?)] = []
    /// This iPhone's record as iCloud last had it. With the App Group cache, which widgets also
    /// write, it stands in for providers this launch hasn't read (keys not read yet, or resting).
    @ObservationIgnored private var ownRecord: RelayEnvelope?
    /// Whether this launch has read its keys. Until then it doesn't publish: a silent push
    /// launches the app without reading them, and its record would lose those providers.
    @ObservationIgnored private var keysRead = false
    /// Whether the push subscriptions are saved for the current choices; retried each refresh.
    @ObservationIgnored private var subscriptionsCurrent = false
    /// Whether this launch has read iCloud. Until it has, the saved cache's readings from other
    /// devices stand in, so a launch that can't reach it doesn't show only this iPhone's.
    @ObservationIgnored private var relayReadOnce = false
    /// The refresh pass under way, and the one asked for meanwhile, which follows it.
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var queued: Task<Void, Never>?
    @ObservationIgnored private var queuedReadsKeys = false
    /// The last refresh that read this iPhone's keys.
    @ObservationIgnored private var lastKeyRefresh: Date?
    /// The alert choices going out to iCloud, and whether they changed again meanwhile.
    @ObservationIgnored private var sharingPreferences: Task<Void, Never>?
    @ObservationIgnored private var shareAgain = false
    /// When this iPhone's choices last reached iCloud. A zone read that began before then may
    /// hold the copy from before, so its choices aren't taken.
    @ObservationIgnored private var preferencesSharedAt: Date?
    /// The run-outs the Watch was last handed, which it shows though widgets don't.
    @ObservationIgnored private var lastHandoverRunOuts: [String: Date] = [:]
    /// When this launch's last check of each key provider failed.
    @ObservationIgnored private var localFailedAt: [Provider: Date] = [:]
    /// What the widgets were last reloaded for, as far as a background reload goes (seeded from
    /// the saved readings, so a background launch doesn't reload for what they already show).
    @ObservationIgnored private var lastReloadSignature: Int?
    /// A reload held back in the background, made when the app comes forward.
    @ObservationIgnored private var reloadHeldBack = false
    @ObservationIgnored private var liveActivityUpdate: Task<Void, Never>?
    private let directory: URL?
    private let logger = Logger(subsystem: TokenroomIdentity.bundleID, category: "store")

    init(
        defaults: UserDefaults = AppGroup.defaults,
        containerIdentifier: String? = RelayAvailability.containerIdentifier,
        keys: APIKeyStore = APIKeyStore(accessGroup: AppGroup.keychainGroup),
        directory: URL? = AppGroup.containerURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ) {
        self.defaults = defaults
        self.keys = keys
        keyGate = KeyFetchGate(defaults: defaults)
        if let existing = defaults.string(forKey: Keys.sourceID) {
            sourceID = existing
        } else {
            sourceID = "src-\(UUID().uuidString.lowercased())"
            defaults.set(sourceID, forKey: Keys.sourceID)
        }
        relay = containerIdentifier.map(CloudRelay.init(containerIdentifier:))
        relayPhase = relay == nil ? .unavailable : .idle
        history = HistoryStore(directory: directory)
        self.directory = directory
        alertLedger = AlertLedger.load(from: directory)
        alertPreferences = defaults.data(forKey: Keys.alertPreferences).flatMap { try? JSONDecoder().decode(AlertPreferences.self, from: $0) } ?? AlertPreferences()
        cacheURL = directory?.appendingPathComponent(ReadingCache.fileName)
        sampleMode = defaults.bool(forKey: Keys.sampleMode)
        hasOnboarded = defaults.bool(forKey: Keys.onboarded)
        #if DEBUG
        // Launch arguments (`-sampleMode YES`) land in the standard defaults, not the App Group's.
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let sample = arguments[Keys.sampleMode] as? String { sampleMode = sample == "YES" }
        if let onboarded = arguments[Keys.onboarded] as? String { hasOnboarded = onboarded == "YES" }
        #endif
        // Which providers have keys, as the last launch found; read again, off the main thread,
        // on the first refresh that includes keys.
        keyedProviders = (defaults.array(forKey: Keys.keyedProviders) as? [String] ?? []).compactMap(Provider.init(rawValue:))
        showCachedReadings()
    }

    // MARK: Refresh

    /// Reads the relay and this iPhone's keys. Without `force`, does nothing within a minute of
    /// the last refresh that read them (a silent push in between reads only iCloud, so opening
    /// the app still reads the keys).
    /// - Parameter includeKeys: false for a silent push, which only means a Mac sent new readings.
    func refresh(force: Bool = false, includeKeys: Bool = true, now: Date = .now) async {
        if !force, !isDue(readingKeys: includeKeys, now: now) { return }
        if let running {
            // Asked for during another refresh (a key saved while a silent push is handled, the
            // app opened during one): one more pass follows it, rather than the ask being
            // dropped. It runs in a task of its own, so the other caller's deadline (a push's)
            // doesn't cut it short; this caller stops waiting at its own.
            let next = queuePass(after: running, readsKeys: includeKeys)
            _ = await TimeLimit.run(Self.passWait, otherwise: ()) { await next.value }
            return
        }
        // Stamped now, so a request that arrives before the pass starts sees it.
        let previousKeyRefresh = lastKeyRefresh
        lastRefresh = now
        if includeKeys {
            lastKeyRefresh = now
        }
        let pass = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshPass(readsKeys: includeKeys, now: now)
        }
        running = pass
        isRefreshing = true
        // Cancelled with its caller (a push's deadline, background time running out): the checks
        // it cuts short don't count.
        await withTaskCancellationHandler {
            await pass.value
        } onCancel: {
            pass.cancel()
        }
        if pass.isCancelled, includeKeys, lastKeyRefresh == now {
            // Its keys weren't all read, so coming back to the app reads them.
            lastKeyRefresh = previousKeyRefresh
        }
        if running == pass {
            running = nil
            isRefreshing = false
        }
    }

    /// The pass that follows the one running, for everything asked for meanwhile.
    private func queuePass(after running: Task<Void, Never>, readsKeys: Bool) -> Task<Void, Never> {
        queuedReadsKeys = queuedReadsKeys || readsKeys
        if let queued {
            return queued
        }
        let task = Task<Void, Never> { @MainActor [weak self] in
            await running.value
            guard let self else { return }
            if self.running == running {
                self.running = nil
                self.isRefreshing = false
            }
            let readsKeys = self.queuedReadsKeys
            self.queued = nil
            self.queuedReadsKeys = false
            // Through `refresh`, in case another pass started first.
            await self.refresh(force: true, includeKeys: readsKeys)
        }
        queued = task
        return task
    }

    /// Whether a refresh that isn't forced is due: a minute after the last one that read what
    /// this one would. One dated later than now means the clock was set back since.
    private func isDue(readingKeys: Bool, now: Date) -> Bool {
        guard let last = readingKeys ? lastKeyRefresh : lastRefresh else { return true }
        return !(0..<Self.foregroundInterval).contains(now.timeIntervalSince(last))
    }

    private func refreshPass(readsKeys: Bool, now: Date) async {
        // Readings the widgets took since the last refresh, before this one's newer ones.
        history.takePending(now: now)
        async let relayRead: Void = readRelay()
        async let keyRead: Void = readsKeys ? readKeys(now: now) : ()
        _ = await (relayRead, keyRead)

        followTimeZone()
        rebuild(now: now)
        // Before the pass ends, so a push handler or intent doesn't return first.
        await liveActivityUpdate?.value
        await publish(now: now)
        await sendAlerts(now: now)
        history.saveIfNeeded()
        // A silent push has seconds in the background: the upkeep waits for a full refresh.
        guard readsKeys else { return }
        await pruneEvents(now: now)
        // Last, so readings show first; claims meanwhile go by the last launch's answer.
        if relayPhase == .ready, !subscriptionsCurrent {
            await prepareNotifications()
        }
    }

    private func readRelay() async {
        guard let relay else {
            relayPhase = .unavailable
            return
        }
        if isWaitingForRelay(.now) { return }
        if relaySources.isEmpty {
            relayPhase = .loading
        }
        do {
            switch try await Self.iCloud({ try await relay.accountStatus() }) {
            case .available:
                break
            case .noAccount:
                // Signed out of iCloud: known to hold nothing now, so the saved readings of the
                // last account's devices don't stand in. (A launch that can't reach iCloud, or
                // asks before it's ready, keeps them.) Another account may sign in next, and
                // starts as if new: its choices, subscriptions, and records.
                relaySources = []
                relayHistories = [:]
                relayEvents = []
                ownRecord = nil
                relayReadOnce = true
                preferencesBase = nil
                preferencesSharedAt = nil
                subscriptionsCurrent = false
                publishPolicy.reset()
                lastHistoryHour = nil
                defaults.set(false, forKey: Keys.published)
                defaults.set(false, forKey: Keys.alertPreferencesShared)
                defaults.set(false, forKey: Keys.alertsFiltered)
                relayPhase = .noAccount
                return
            default:
                relayPhase = .noAccount
                return
            }
            let readStartedAt = Date()
            let contents = try await Self.iCloud { try await relay.contents() }
            ownRecord = contents.sources.first { $0.id == sourceID }?.envelope
            relaySources = contents.sources.filter { $0.id != sourceID }
            relayHistories = contents.histories
            relayEvents = contents.events
            relayPhase = .ready
            relayRetryAt = nil
            relayReadOnce = true
            adoptPreferences(contents.alertPreferences, readStartedAt: readStartedAt)
        } catch {
            logger.error("relay read failed: \(String(describing: error), privacy: .public)")
            handleRelayError(error)
        }
    }

    /// The alert choices this iPhone last knew to match iCloud. What differs from them here is a
    /// change made here that iCloud doesn't have yet.
    private var preferencesBase: AlertPreferences? {
        get { defaults.data(forKey: Keys.alertPreferencesBase).flatMap { try? RelayEnvelope.decoder.decode(AlertPreferences.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? RelayEnvelope.encoder.encode($0) }, forKey: Keys.alertPreferencesBase) }
    }

    /// Takes what a Mac changed in the shared alert choices. A change made here that iCloud
    /// doesn't have yet stays, on top, and goes out with `shareAlertPreferences`.
    private func adoptPreferences(_ remote: AlertPreferences?, readStartedAt: Date) {
        // While choices are going out, what they resolve to is taken when that's done; a read
        // that began before they last reached iCloud may hold the copy from before.
        guard sharingPreferences == nil else { return }
        if let preferencesSharedAt, readStartedAt < preferencesSharedAt { return }
        let resolution = AlertPreferencesSync.resolve(base: preferencesBase, local: alertPreferences, remote: remote)
        if resolution.needsPublish {
            defaults.set(false, forKey: Keys.alertPreferencesShared)
        } else if let remote, resolution.preferences.sameChoices(as: remote) {
            preferencesBase = remote
            defaults.set(true, forKey: Keys.alertPreferencesShared)
        }
        take(resolution.preferences)
    }

    /// Uses choices that came from iCloud (or were merged with them), without stamping them as a
    /// change made here.
    private func take(_ preferences: AlertPreferences) {
        guard preferences != alertPreferences else { return }
        let subscriptionsChange = preferences.subscribedKeys != alertPreferences.subscribedKeys
        adoptingPreferences = true
        alertPreferences = preferences
        adoptingPreferences = false
        if subscriptionsChange {
            Task { await prepareNotifications() }
        }
    }

    /// Quiet hours follow this iPhone, which goes where its owner goes: the shared choices take
    /// its time zone when it changes, so a Mac holds alerts for the same night. Not a change of
    /// choices, so it isn't stamped as one. Only when this iPhone's zone changes: two iPhones in
    /// different zones don't take turns rewriting it.
    private func followTimeZone() {
        let zone = TimeZone.current.identifier
        guard !sampleMode, defaults.string(forKey: Keys.followedTimeZone) != zone else { return }
        defaults.set(zone, forKey: Keys.followedTimeZone)
        guard alertPreferences.timeZoneID != zone else { return }
        followingTimeZone = true
        alertPreferences.timeZoneID = zone
        followingTimeZone = false
    }

    /// The choices as this iPhone applies them: quiet hours where it is now.
    private var preferencesHere: AlertPreferences {
        var preferences = alertPreferences
        preferences.timeZoneID = TimeZone.current.identifier
        return preferences
    }

    /// How long a refresh waits for any one iCloud call.
    static let iCloudBudget: TimeInterval = 20

    private struct ICloudTimeout: Error {}

    /// `work`'s answer within `iCloudBudget`, or `ICloudTimeout`: a call that never answers
    /// (account status, say, which ignores cancellation) counts as iCloud being unreachable
    /// rather than holding this refresh, and every one queued behind it, forever.
    private static func iCloud<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let result = await TimeLimit.run(iCloudBudget, otherwise: Result<T, any Error>.failure(ICloudTimeout())) {
            do {
                return .success(try await work())
            } catch {
                return .failure(error)
            }
        }
        // Let go because the refresh was cancelled (a push's deadline): not iCloud's doing.
        if case .failure(let error) = result, error is ICloudTimeout, Task.isCancelled {
            throw CancellationError()
        }
        return try result.get()
    }

    /// Whether iCloud asked to wait. A wait further off than an hour means the clock was set back
    /// since it was saved.
    private func isWaitingForRelay(_ now: Date) -> Bool {
        guard let relayRetryAt, relayRetryAt > now else { return false }
        return relayRetryAt.timeIntervalSince(now) <= 3600
    }

    private func handleRelayError(_ error: Error, now: Date = .now) {
        switch RelayErrorPolicy.outcome(for: error, defaultRetry: RelayPublishPolicy.minimumInterval) {
        case .noAccount:
            relayPhase = .noAccount
        case .paused(let message), .failed(let message):
            relayPhase = .failed(message)
        case .retry(let after, let message):
            relayRetryAt = now.addingTimeInterval(after)
            relayPhase = .failed(message)
        case .unavailable:
            relayPhase = .unavailable
        case .cancelled:
            break
        }
    }

    private func readKeys(now: Date) async {
        let keys = self.keys
        let providers = await BlockingIO.run {
            Provider.allCases.filter { $0.readsWithKey && keys.hasKey(for: $0) }
        }
        keyedProviders = providers
        keysRead = true
        defaults.set(providers.map(\.rawValue), forKey: Keys.keyedProviders)
        for provider in localStatuses.keys where !providers.contains(provider) {
            localStatuses[provider] = nil
            localCheckedAt[provider] = nil
            localFailedAt[provider] = nil
        }
        // Shared with the widgets: Anthropic's cost report allows a call every 15 minutes,
        // pull to refresh or not, and a 429 holds every caller off.
        let gate = keyGate
        let due = providers.filter { provider in
            if let until = rateLimitedUntil[provider], until > now { return false }
            return !gate.isResting(provider, now: now)
        }
        var earlierAttempts: [Provider: Date] = [:]
        for provider in due {
            earlierAttempts[provider] = gate.lastAttempt(provider)
            gate.recordAttempt(provider, at: now)
        }
        await withTaskGroup(of: (Provider, Result<QuotaSnapshot, ProviderError>).self) { group in
            for provider in due {
                if localStatuses[provider] == nil {
                    localStatuses[provider] = .loading
                }
                group.addTask {
                    await (provider, APIKeyClient(provider: provider, keys: keys).fetchWithinBudget())
                }
            }
            for await (provider, result) in group {
                // Cut short (background time ran out): not a failure, and not a call, so the
                // next refresh asks again and a saved reading stands in meanwhile.
                if Task.isCancelled, case .failure = result {
                    gate.recordAttempt(provider, at: earlierAttempts[provider])
                    if localStatuses[provider] == .loading {
                        localStatuses[provider] = nil
                    }
                    continue
                }
                apply(provider, result: result, now: now)
            }
        }
    }

    /// Readings are kept as read; the budget or reference set on this iPhone is applied when
    /// they're shown, so changing it shows at once, without a new call.
    private func apply(_ provider: Provider, result: Result<QuotaSnapshot, ProviderError>, now: Date) {
        switch result {
        case .success(let raw):
            localStatuses[provider] = .live(raw)
            localCheckedAt[provider] = raw.fetchedAt
            localFailedAt[provider] = nil
            rateLimitedUntil[provider] = nil
            keyGate.block(provider, until: nil)
            history.record(raw.applyingBudget(budget(for: provider)))
        case .failure(let error):
            let next = ProviderStatus.failure(error, cached: localStatuses[provider]?.snapshot, lastChecked: localCheckedAt[provider], now: now)
            if case .rateLimited(let until, _) = next {
                rateLimitedUntil[provider] = until
                keyGate.block(provider, until: until)
            }
            localStatuses[provider] = next
            localFailedAt[provider] = now
        }
    }

    /// A reading with the budget or reference set on this iPhone now.
    private func budgeted(_ status: ProviderStatus, for provider: Provider) -> ProviderStatus {
        let budget = budget(for: provider)
        switch status {
        case .live(let snapshot):
            return .live(snapshot.applyingBudget(budget))
        case .stale(let snapshot):
            return .stale(snapshot.applyingBudget(budget))
        case .expired(let message, let cached):
            return .expired(message, cached: cached?.applyingBudget(budget))
        case .rateLimited(let until, let cached):
            return .rateLimited(until: until, cached: cached?.applyingBudget(budget))
        case .unreachable(let cached):
            return .unreachable(cached: cached?.applyingBudget(budget))
        case .loading, .signedOut, .notEntitled:
            return status
        }
    }

    // MARK: Merged readings

    private func showCachedReadings() {
        if sampleMode {
            rebuild()
            return
        }
        guard let cacheURL, let cache = ReadingCache.load(from: cacheURL), !cache.isSample else { return }
        readings = cache.items.map { Reading($0) }
        lastCacheHash = cache.materialHash
        lastReloadSignature = cache.reloadSignature
        lastHandoverRunOuts = cache.runOuts
    }

    private func rebuild(now: Date = .now) {
        if sampleMode {
            let cache = SampleData.cache(now: now)
            readings = cache.items.map { Reading($0, now: now) }
            disconnected = []
            saveCache(cache)
            return
        }

        var sources = relaySources.compactMap { source in
            source.envelope.map { RelayMerge.Source(id: source.id, label: source.label, envelope: $0) }
        }
        var histories = relayHistories
        if !relayReadOnce, let previous = cacheURL.flatMap({ ReadingCache.load(from: $0) }) {
            // iCloud hasn't answered this launch (offline, a CloudKit error): the other devices'
            // readings from the saved cache stay, rather than leaving only this iPhone's in the
            // app, the widgets, and on the Watch.
            for carried in previous.carriedSources(excluding: Self.localLabel) {
                sources.append(carried.source)
                histories[carried.source.id] = carried.history
            }
        }
        let own = localEnvelope(now: now)
        if !own.providers.isEmpty {
            sources.append(RelayMerge.Source(id: sourceID, label: Self.localLabel, envelope: own))
            histories[sourceID] = RelayHistory(series: history.weeks)
        }
        let output = ReadingAssembler.assemble(sources: sources, histories: histories, now: now)
        readings = output.connected.map { Reading($0, now: now) }
        disconnected = output.disconnected.map { Reading($0, now: now) }
        saveCache(ReadingCache(savedAt: now, isSample: false, items: output.connected))
        let providers = output.connected.map(\.provider)
        let preferences = preferencesHere
        let previous = liveActivityUpdate
        liveActivityUpdate = Task {
            await previous?.value
            await LiveActivities.update(with: providers, preferences: preferences, now: now)
        }
    }

    /// Widgets redraw from this. When nothing they'd draw changed, only the save time moves, so
    /// they don't refetch, and they aren't reloaded.
    private func saveCache(_ cache: ReadingCache) {
        guard let cacheURL else { return }
        let hash = cache.materialHash
        do {
            try cache.save(to: cacheURL)
        } catch {
            logger.error("cache save failed: \(String(describing: error), privacy: .public)")
            return
        }
        let changed = hash != lastCacheHash
        let runOuts = cache.runOuts
        // The Watch shows a Mac's measured run-out, which widgets don't: one that moved an
        // hour goes to it too.
        guard changed || RelayPublishPolicy.runOutsMoved(runOuts, since: lastHandoverRunOuts) else { return }
        // Sample readings stay on this iPhone; the Watch keeps showing real ones.
        if !cache.isSample {
            WatchLink.shared.send(cache)
            lastHandoverRunOuts = runOuts
        }
        guard changed else { return }
        lastCacheHash = hash
        reloadWidgets(for: cache)
    }

    /// Reloads widgets for new readings. Reloads asked for in the background (a silent push)
    /// count against WidgetKit's daily budget, so then only what matters goes out at once
    /// (`ReadingCache.reloadSignature`); smaller moves wait for the widgets' next timeline, which
    /// reads this cache, or for the app to come forward.
    private func reloadWidgets(for cache: ReadingCache) {
        let signature = cache.reloadSignature
        guard UIApplication.shared.applicationState != .background || signature != lastReloadSignature else {
            reloadHeldBack = true
            return
        }
        lastReloadSignature = signature
        reloadHeldBack = false
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// The app came forward: a reload held back in the background goes out now.
    func becameActive() {
        guard reloadHeldBack else { return }
        reloadHeldBack = false
        WidgetCenter.shared.reloadAllTimelines()
    }

    func reading(id: String) -> Reading? {
        readings.first { $0.id == id } ?? disconnected.first { $0.id == id }
    }

    /// When the freshest source last checked.
    var lastChecked: Date? {
        readings.compactMap { $0.provider.checkedAt ?? $0.provider.fetchedAt }.max()
    }

    /// Where readings came from, e.g. "Mac" or "Mac and This iPhone".
    var sourceSummary: String? {
        let labels = Array(Set(readings.map(\.source))).sorted()
        switch labels.count {
        case 0: return nil
        case 1: return labels[0]
        default: return labels.dropLast().joined(separator: ", ") + " and " + labels[labels.count - 1]
        }
    }

    var needsNewerApp: Bool {
        relaySources.contains(where: \.needsNewerApp)
    }

    // MARK: This iPhone as a source

    /// Readings older than this don't stand in for a provider (the merge's own limit).
    private static let standInLimit = RelayMerge.maxSourceAge

    /// This iPhone's providers, each at its newest reading: what this launch read with its keys,
    /// or what its iCloud record or the App Group cache (which widgets also write) has, so none
    /// drops out, turns into "loading", or goes back to an older reading in between. A key that
    /// stopped working (signed out, expired, not on the plan) shows as that, whatever is saved.
    /// Saved readings take the budget or reference set now.
    private func localEnvelope(now: Date) -> RelayEnvelope {
        let saved = savedOwnReadings(now: now)
        let owned = keysRead || defaults.array(forKey: Keys.keyedProviders) != nil
            ? keyedProviders
            : Provider.allCases.filter { saved[$0.rawValue] != nil }
        let providers = owned.map { provider -> RelayProvider in
            let standIn = saved[provider.rawValue]?.applyingBudget(budget(for: provider))
            guard let status = localStatuses[provider], status != .loading else {
                return standIn ?? RelayProvider(provider: provider, status: .loading, checkedAt: nil)
            }
            let mine = RelayProvider(provider: provider, status: budgeted(status, for: provider), checkedAt: localCheckedAt[provider])
            guard var standIn, !["signedOut", "expired", "notEntitled"].contains(mine.state),
                  let standInTime = Self.readingTime(standIn),
                  standInTime > (Self.readingTime(mine) ?? .distantPast)
            else { return mine }
            if !mine.isLive, let failedAt = localFailedAt[provider], failedAt > standInTime {
                // This launch's check failed (offline, busy, rate limited) after the saved
                // reading was taken: it stands in with that failure, so it's shown faded, isn't
                // followed or relayed as live, and doesn't beat a fresher reading from another
                // device. One a widget took after the failure shows as it is.
                standIn.state = mine.state
                standIn.message = mine.message
            }
            return standIn
        }
        return RelayEnvelope(producer: "iphone", appVersion: TokenroomIdentity.version, checkedAt: now, providers: providers)
    }

    /// The newest reading of each of this iPhone's providers in its iCloud record and the cache,
    /// up to a week old.
    private func savedOwnReadings(now: Date) -> [String: RelayProvider] {
        let cache = cacheURL.flatMap { ReadingCache.load(from: $0) }
        let cached = cache.map { $0.isSample ? [] : $0.items.filter { $0.source == Self.localLabel }.map(\.provider) } ?? []
        var newest: [String: RelayProvider] = [:]
        for provider in (ownRecord?.providers ?? []) + cached {
            guard let time = Self.readingTime(provider), now.timeIntervalSince(time) < Self.standInLimit else { continue }
            if let kept = newest[provider.id], let keptTime = Self.readingTime(kept), keptTime >= time { continue }
            newest[provider.id] = provider
        }
        return newest
    }

    private static func readingTime(_ provider: RelayProvider) -> Date? {
        provider.checkedAt ?? provider.fetchedAt
    }

    /// Relays what this iPhone read with its keys, so the Watch and other devices can show it.
    /// Once this iPhone has published, it keeps its record current, even when that's empty.
    private func publish(now: Date) async {
        guard let relay, relayPhase == .ready, !sampleMode, keysRead else { return }
        let published = defaults.bool(forKey: Keys.published)
        guard !keyedProviders.isEmpty || published else { return }
        let envelope = localEnvelope(now: now)
        if let relayRetryAt, relayRetryAt > now { return }
        if publishPolicy.isDue(envelope, now: now) {
            do {
                let sourceID = sourceID
                try await Self.iCloud { try await relay.publish(sourceID: sourceID, kind: "iphone", label: "iPhone", envelope: envelope) }
                publishPolicy.didSend(envelope, at: now)
                defaults.set(true, forKey: Keys.published)
            } catch {
                logger.error("relay publish failed: \(String(describing: error), privacy: .public)")
                handleRelayError(error, now: now)
                return
            }
        }
        let hour = UsageHistory.hourStart(now)
        let relayHistory = history.relayHistory(for: keyedProviders)
        guard lastHistoryHour != hour, !relayHistory.series.isEmpty else { return }
        do {
            let sourceID = sourceID
            try await Self.iCloud { try await relay.publishHistory(sourceID: sourceID, history: relayHistory) }
            lastHistoryHour = hour
        } catch {
            logger.error("relay history failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Alerts

    /// Alerts for what only this iPhone reads, with its keys. A provider a Mac also reports live
    /// gets its alert from that Mac, through iCloud, so one crossing makes one notification.
    /// These are local: iCloud doesn't notify the device that saved a record.
    private func sendAlerts(now: Date) async {
        guard !sampleMode, !localStatuses.isEmpty else { return }
        await claimShownAlerts(now: now)
        // Only Macs count (two iPhones with the same key would each wait for the other), and only
        // for windows they meter: a balance with a reference set on this iPhone but not on the
        // Mac is this iPhone's to alert for.
        // Windows by the name this version gives them: a Mac on 2.0.0 names Copilot's month
        // `ai_credits` when it reads it with a token.
        let windowKey = { (provider: String, window: String) in
            provider + "/" + CopilotBilling.currentWindowID(provider: provider, window: window)
        }
        var coveredWindows = Set<String>()
        var coveredProviders = Set<String>()
        for envelope in relaySources.compactMap(\.envelope) where envelope.producer == "mac" && now.timeIntervalSince(envelope.checkedAt) < 3600 {
            for provider in envelope.providers where provider.isLive {
                coveredProviders.insert(provider.id)
                for window in provider.windows where window.isMetered {
                    coveredWindows.insert(windowKey(provider.id, window.id))
                }
            }
        }
        let isCovered = { (alert: UsageAlert) -> Bool in
            guard let window = alert.window else { return coveredProviders.contains(alert.provider) }
            return coveredWindows.contains(windowKey(alert.provider, window))
        }
        // Every provider this launch read keeps the ledger current (saved stand-ins could take it
        // back in time). Alerts a Mac covers come from that Mac, so here they stay pending:
        // claimed if the Mac goes quiet, dropped after 18 hours. Quiet hours are this iPhone's.
        let preferences = preferencesHere
        let read = keyedProviders.compactMap { provider in
            localStatuses[provider].map { RelayProvider(provider: provider, status: budgeted($0, for: provider), checkedAt: localCheckedAt[provider]) }
        }
        alertLedger.process(read, preferences: preferences, now: now)
        // Urgent ones now; the rest when quiet hours end.
        let due = alertLedger.due(preferences: preferences, now: now).filter { !isCovered($0) }
        var shown = unclaimed
        for alert in due {
            switch await claim(alert, now: now) {
            case .ours:
                Self.notify(alert)
            case .taken:
                break
            case .unasked:
                Self.notify(alert)
                shown.append(ShownAlert(alert: alert, shownAt: now))
            }
        }
        unclaimed = shown
        alertLedger.markSent(due.map(\.id), at: now)
        alertLedger.save(to: directory)
    }

    private enum Claim {
        /// Show it: this iPhone's record now stands for the alert, or another iPhone's does, which
        /// showed it there without a push reaching this one.
        case ours
        /// A Mac's record was there first; its notification came through iCloud.
        case taken
        /// iCloud couldn't be asked, or the alert subscription doesn't filter by kind yet (so a
        /// record of this iPhone's own would come back to it): show it, and claim it later.
        case unasked
    }

    private func claim(_ alert: UsageAlert, now: Date) async -> Claim {
        guard let relay, relayPhase == .ready, defaults.bool(forKey: Keys.alertsFiltered) else { return .unasked }
        do {
            // A balance crossing announced on the other side of midnight (UTC) went out under
            // that day's name; it isn't news again under this one's.
            if try await Self.iCloud({ try await relay.wentOutOnANeighbouringDay(alert, now: now) }) {
                return .taken
            }
            switch try await Self.iCloud({ try await relay.claimAlert(alert) }) {
            case .created, .shownElsewhere:
                return .ours
            case .pushed:
                return .taken
            }
        } catch {
            logger.error("alert claim failed: \(String(describing: error), privacy: .public)")
            return .unasked
        }
    }

    /// An alert shown before it could be claimed.
    private struct ShownAlert: Codable {
        var alert: UsageAlert
        var shownAt: Date
    }

    private var unclaimed: [ShownAlert] {
        get { defaults.data(forKey: Keys.unclaimedAlerts).flatMap { try? JSONDecoder().decode([ShownAlert].self, from: $0) } ?? [] }
        set { defaults.set(newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue), forKey: Keys.unclaimedAlerts) }
    }

    /// Claims alerts shown while iCloud was away, so a Mac that sees the same crossing later
    /// only updates the record and doesn't alert again. Ones older than 18 hours are dropped.
    private func claimShownAlerts(now: Date) async {
        let shown = unclaimed.filter { now.timeIntervalSince($0.shownAt) < AlertLedger.pendingLifetime }
        guard let relay, relayPhase == .ready, defaults.bool(forKey: Keys.alertsFiltered), !shown.isEmpty else {
            unclaimed = shown
            return
        }
        var left: [ShownAlert] = []
        for item in shown {
            do {
                let alert = item.alert
                _ = try await Self.iCloud { try await relay.claimAlert(alert) }
            } catch {
                left.append(item)
            }
        }
        unclaimed = left
    }

    private static func notify(_ alert: UsageAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        content.threadIdentifier = alert.provider
        // Not time-sensitive: that needs an entitlement, and alerts a Mac sends through iCloud
        // can't be; urgent ones already skip quiet hours.
        content.interruptionLevel = .active
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil))
    }

    /// Lets Macs follow this iPhone's choices, laid over the newest shared copy so a choice a Mac
    /// made since the last read stays. One round at a time: a change made while one goes out
    /// follows in another. Retried on the next refresh if iCloud is away.
    func shareAlertPreferences() async {
        if let sharingPreferences {
            shareAgain = true
            await sharingPreferences.value
            return
        }
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.shareAgain = false
                await self.sharePreferencesOnce()
            } while self.shareAgain && !Task.isCancelled
            // Here, not after the wait below: a caller arriving now starts a round of its own.
            self.sharingPreferences = nil
        }
        sharingPreferences = task
        await task.value
    }

    private func sharePreferencesOnce() async {
        guard let relay, relayPhase == .ready, !defaults.bool(forKey: Keys.alertPreferencesShared) else { return }
        let local = alertPreferences
        do {
            let remote = try await Self.iCloud { try await relay.alertPreferences() }
            let resolution = AlertPreferencesSync.resolve(base: preferencesBase, local: local, remote: remote)
            if resolution.needsPublish {
                let preferences = resolution.preferences
                try await Self.iCloud { try await relay.publishAlertPreferences(preferences) }
                preferencesSharedAt = Date()
            }
            if resolution.needsPublish || remote != nil {
                preferencesBase = resolution.preferences
            }
            if alertPreferences.sameChoices(as: local) {
                defaults.set(true, forKey: Keys.alertPreferencesShared)
                take(resolution.preferences)
            } else {
                // Changed again while this went out: that change stays, on top of what went
                // out, and follows in the next round.
                take(AlertPreferences.merged(base: local, local: alertPreferences, remote: resolution.preferences))
                shareAgain = true
            }
        } catch {
            logger.error("alert preferences not shared: \(String(describing: error), privacy: .public)")
        }
    }

    /// Alert records are only needed until their notification goes out. Once a day, those older
    /// than two weeks are deleted.
    private func pruneEvents(now: Date) async {
        await shareAlertPreferences()
        guard let relay, relayPhase == .ready else { return }
        if let pruned = defaults.object(forKey: Keys.prunedAt) as? Date, now.timeIntervalSince(pruned) < 86_400 { return }
        let old = relayEvents.filter { event in
            event.createdAt.map { now.timeIntervalSince($0) > CloudRelay.eventLifetime } ?? false
        }.map(\.id)
        do {
            try await Self.iCloud { try await relay.deleteRecords(named: old) }
            defaults.set(now, forKey: Keys.prunedAt)
        } catch {
            logger.error("alert pruning failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Deletes every Tokenroom record in iCloud, from every device. Macs with sync on send fresh
    /// readings on their next check.
    func deleteICloudData() async throws {
        guard let relay else { return }
        try await relay.deleteAllData()
        relaySources = []
        relayHistories = [:]
        // Known to be empty now, so the saved cache's readings don't stand in for it.
        relayReadOnce = true
        publishPolicy.reset()
        lastHistoryHour = nil
        relayEvents = []
        ownRecord = nil
        subscriptionsCurrent = false
        preferencesBase = nil
        defaults.set(false, forKey: Keys.published)
        defaults.set(false, forKey: Keys.alertPreferencesShared)
        rebuild()
        // The zone's subscriptions went with it; without new ones, pushes and alerts stop.
        await prepareNotifications()
    }

    /// A background app refresh: the next one is asked for first, so it's on the calendar even
    /// if this one runs out of time, then the relay and this iPhone's keys.
    func backgroundRefresh() async {
        await scheduleBackgroundRefresh()
        await refresh(force: true)
    }

    /// A silent push: a Mac sent new readings. Returns whether what this iPhone shows changed.
    func refreshForPush() async -> Bool {
        let before = lastCacheHash
        // Keys on this iPhone can wait for a full refresh.
        await refresh(force: true, includeKeys: false)
        return lastCacheHash != before
    }

    func scheduleBackgroundRefresh(now: Date = .now) async {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskID)
        request.earliestBeginDate = now.addingTimeInterval(Self.backgroundInterval)
        do {
            // Xcode 27 (Swift 6.4) has iOS 27's submitTaskRequest; Xcode 26 builds keep submit.
            #if compiler(>=6.4)
            if #available(iOS 27.0, *) {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } else {
                try BGTaskScheduler.shared.submit(request)
            }
            #else
            try BGTaskScheduler.shared.submit(request)
            #endif
        } catch {
            logger.error("background refresh not scheduled: \(String(describing: error), privacy: .public)")
        }
    }

    /// Subscribes to source changes (silent) and the alert kinds turned on (visible
    /// notifications); called again whenever the alert choices change.
    func prepareNotifications() async {
        guard let relay else { return }
        do {
            let keys = alertPreferences.subscribedKeys
            let filtered = try await Self.iCloud { try await relay.ensureSubscriptions(alertKeys: keys) }
            defaults.set(filtered, forKey: Keys.alertsFiltered)
            subscriptionsCurrent = true
        } catch {
            subscriptionsCurrent = false
            logger.error("subscriptions failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Keys and budgets

    func metadata(for provider: Provider) async -> APIKeyStore.Metadata? {
        let keys = self.keys
        return await BlockingIO.run { keys.metadata(for: provider) }
    }

    func saveKey(_ key: String, for provider: Provider, region: String?, warning: String? = nil) async throws {
        let keys = self.keys
        try await BlockingIO.run { try keys.save(key, for: provider, region: region, warning: warning) }
        keyedProviders = Provider.allCases.filter { $0 == provider || keyedProviders.contains($0) }
        defaults.set(keyedProviders.map(\.rawValue), forKey: Keys.keyedProviders)
        // Checked now: the old key's spacing and any 429 wait don't apply to a new one.
        keyGate.reset(provider)
        rateLimitedUntil[provider] = nil
        publishPolicy.reset()
        hasOnboarded = true
        if sampleMode {
            sampleMode = false
        }
        await refresh(force: true)
    }

    func removeKey(for provider: Provider) async throws {
        let keys = self.keys
        try await BlockingIO.run { try keys.remove(for: provider) }
        localStatuses[provider] = nil
        localCheckedAt[provider] = nil
        localFailedAt[provider] = nil
        keyGate.reset(provider)
        rateLimitedUntil[provider] = nil
        // Gone from iCloud on this refresh, not a minute later, so no launch brings it back.
        keyedProviders.removeAll { $0 == provider }
        defaults.set(keyedProviders.map(\.rawValue), forKey: Keys.keyedProviders)
        publishPolicy.reset()
        await refresh(force: true)
    }

    /// The currency a provider's reference or budget is entered in: its balance's currency, from
    /// this launch's reading or, before one, the reading shown.
    func budgetCurrency(for provider: Provider) -> String {
        if let snapshot = localStatuses[provider]?.snapshot {
            return snapshot.budgetCurrencyCode
        }
        let shown = (readings + disconnected).first { $0.id == provider.rawValue }?.provider
        return shown?.windows.first { $0.amount != nil }?.amount?.unit == "cny" ? "CNY" : "USD"
    }

    func budget(for provider: Provider) -> Double? {
        (defaults.dictionary(forKey: Keys.budgets) as? [String: Double])?[provider.rawValue]
    }

    func setBudget(_ value: Double?, for provider: Provider) {
        var budgets = (defaults.dictionary(forKey: Keys.budgets) as? [String: Double]) ?? [:]
        budgets[provider.rawValue] = value.flatMap { $0 > 0 ? $0 : nil }
        defaults.set(budgets, forKey: Keys.budgets)
        // Applied to the reading there is, at once: Anthropic's report may not be due for a
        // quarter of an hour.
        rebuild()
        Task { await publish(now: .now) }
    }

    var relayStatusText: String {
        switch relayPhase {
        case .idle, .loading: "Checking…"
        case .ready: relaySources.isEmpty ? "No Mac yet" : "Connected"
        case .unavailable: "Not available in this build"
        case .noAccount: "Sign in to iCloud in Settings"
        case .failed(let message): message
        }
    }
}
