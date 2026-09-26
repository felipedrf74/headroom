import Foundation
import Observation
import UserNotifications

/// News: new models from OpenRouter's public list, and announcements from official feeds. The
/// iPhone's News tab and the Mac's News window both read it.
@Observable
@MainActor
final class NewsStore {
    enum Keys {
        static let vendors = "newsVendors"
        static let sources = "newsSources"
        /// The catalog when `sources` was saved, so feeds added since start on.
        static let knownSources = "newsKnownSources"
        /// The default labs when `vendors` was saved, so labs added to the defaults since start on.
        static let knownVendors = "newsKnownVendors"
        static let seenAt = "newsSeenAt"
    }

    /// Tokenroom 2.0's feeds: what a list saved before `Keys.knownSources` existed had offered.
    static let firstCatalog: Set<String> = [
        "claude-code", "claude-code-releases", "openai-news", "codex-releases", "gemini", "copilot", "cursor", "devin",
        "zai", "kimi-code", "openrouter", "codex-changelog", "antigravity-blog", "antigravity-cli", "minimax-code",
    ]

    /// Tokenroom 2.0's default labs: what a list saved before `Keys.knownVendors` existed had.
    static let firstDefaultVendors: Set<String> = ["anthropic", "openai", "x-ai", "google", "z-ai", "moonshotai", "minimax", "deepseek"]

    private(set) var cache: NewsCache
    private(set) var isRefreshing = false

    /// Labs whose new models are announced, e.g. `anthropic`.
    var followedVendors: Set<String> {
        didSet {
            defaults.set(followedVendors.sorted(), forKey: Keys.vendors)
            defaults.set(ModelFeed.defaultVendors.sorted(), forKey: Keys.knownVendors)
        }
    }

    /// Feed IDs from `FeedSource.catalog`.
    var followedSources: Set<String> {
        didSet {
            defaults.set(followedSources.sorted(), forKey: Keys.sources)
            defaults.set(FeedSource.catalog.map(\.id).sorted(), forKey: Keys.knownSources)
        }
    }

    /// When News was last opened. Items published after it count as new.
    private(set) var seenAt: Date {
        didSet { defaults.set(seenAt.timeIntervalSince1970, forKey: Keys.seenAt) }
    }

    /// `seenAt` as it was when News opened, so what was new stays marked while it's open.
    private(set) var visitBaseline: Date

    private let defaults: UserDefaults
    private let directory: URL?

    init(
        defaults: UserDefaults = AppGroup.defaults,
        directory: URL? = AppGroup.containerURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
        now: Date = .now
    ) {
        self.defaults = defaults
        self.directory = directory
        cache = NewsCache.load(from: directory)
        // A saved choice, plus labs added to the defaults since it was saved, as with feeds below.
        let knownVendors = (defaults.array(forKey: Keys.knownVendors) as? [String]).map(Set.init) ?? Self.firstDefaultVendors
        followedVendors = (defaults.array(forKey: Keys.vendors) as? [String]).map { Set($0).union(ModelFeed.defaultVendors.subtracting(knownVendors)) } ?? ModelFeed.defaultVendors
        // A saved choice, plus feeds added to the catalog since it was saved: those start on,
        // as every feed does before anything is saved.
        let catalog = Set(FeedSource.catalog.map(\.id))
        let known = (defaults.array(forKey: Keys.knownSources) as? [String]).map(Set.init) ?? Self.firstCatalog
        followedSources = (defaults.array(forKey: Keys.sources) as? [String]).map { Set($0).union(catalog.subtracting(known)) } ?? catalog
        // A first launch starts from now, so the whole list isn't "new".
        let saved = defaults.object(forKey: Keys.seenAt) as? Double
        let seen = saved.map(Date.init(timeIntervalSince1970:)) ?? now
        seenAt = seen
        visitBaseline = seen
        if saved == nil {
            defaults.set(seen.timeIntervalSince1970, forKey: Keys.seenAt)
        }
    }

    var sources: [FeedSource] {
        FeedSource.catalog.filter { followedSources.contains($0.partOf ?? $0.id) }
    }

    var announcements: [FeedItem] {
        cache.announcements(from: sources)
    }

    /// Newest first; followed labs only unless `all`.
    func models(all: Bool = false) -> [ModelRelease] {
        all ? cache.models : cache.models.filter { followedVendors.contains($0.vendor) }
    }

    /// Models OpenRouter will retire, soonest first.
    var retiring: [ModelRelease] {
        cache.models.filter { ($0.expires ?? .distantPast) > .now }.sorted { ($0.expires ?? .distantFuture) < ($1.expires ?? .distantFuture) }
    }

    /// New models from followed labs since News was last opened.
    var unseenModelCount: Int {
        models().filter { $0.created > seenAt }.count
    }

    /// Announcements from followed feeds since News was last opened.
    var unseenAnnouncementCount: Int {
        announcements.filter { ($0.published ?? .distantPast) > seenAt }.count
    }

    var unseenCount: Int {
        unseenModelCount + unseenAnnouncementCount
    }

    /// "Couldn't read …" when the model list's last answer couldn't be read.
    var modelProblem: String? {
        cache.unreadable?.contains(ModelFeed.id) == true ? "Couldn't read OpenRouter's model list." : nil
    }

    /// "Couldn't read …" naming the followed feeds whose last answer couldn't be read in full.
    var announcementProblem: String? {
        let names = sources.filter { cache.unreadable?.contains($0.id) == true }.map(\.name)
        guard let last = names.last else { return nil }
        if names.count > 1, names.count == sources.count {
            return "Couldn't read the feeds."
        }
        return "Couldn't read \(names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last)."
    }

    /// Whether to mark an item as new while News is open.
    func isNew(_ date: Date?) -> Bool {
        guard let date else { return false }
        return date > visitBaseline
    }

    /// News is open: clear the badge, but keep this visit's items marked.
    func markSeen(now: Date = .now) {
        visitBaseline = seenAt
        seenAt = max(seenAt, now)
    }

    /// Labs to offer in settings: followed ones, then others in the list, by name.
    var vendorChoices: [(id: String, name: String)] {
        var names: [String: String] = [:]
        for release in cache.models where names[release.vendor] == nil {
            names[release.vendor] = release.vendorName
        }
        for vendor in ModelFeed.defaultVendors where names[vendor] == nil {
            names[vendor] = ModelFeed.vendorNames[vendor] ?? vendor
        }
        return names.map { ($0.key, $0.value) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Fetches what's due, or anything older than `maxAge`. New models from followed labs get one
    /// notification when `notifies` and the preferences allow it.
    func refresh(maxAge: TimeInterval? = nil, preferences: AlertPreferences, notifies: Bool = true, now: Date = .now) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if cache.modelsFetchedAt == nil, cache.announcementsFetchedAt == nil {
            // The first check (on the Mac, when News is turned on): what it finds isn't new.
            seenAt = max(seenAt, now)
            visitBaseline = seenAt
        }
        let result = await NewsFetcher.refresh(cache, sources: sources, following: followedVendors, maxAge: maxAge, now: now)
        cache = result.cache
        cache.save(to: directory)
        if notifies, preferences.newModels, !result.newModels.isEmpty {
            Self.notify(result.newModels, preferences: preferences, now: now)
        }
    }

    /// One notification for the batch, held until quiet hours end.
    private static func notify(_ releases: [ModelRelease], preferences: AlertPreferences, now: Date) {
        let content = UNMutableNotificationContent()
        if releases.count == 1, let release = releases.first {
            content.title = "New model: \(release.shortName)"
            content.body = "From \(release.vendorName)."
        } else {
            content.title = "\(releases.count) new models"
            content.body = releases.prefix(4).map(\.shortName).joined(separator: ", ") + (releases.count > 4 ? ", and more." : ".")
        }
        content.threadIdentifier = "models"
        let trigger = preferences.quietEnd(after: now).map { end in
            UNTimeIntervalNotificationTrigger(timeInterval: max(end.timeIntervalSince(now), 1), repeats: false)
        }
        let id = "models-" + releases.map(\.id).joined(separator: ",")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
