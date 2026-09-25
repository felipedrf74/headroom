import Foundation
import Observation
import UserNotifications

/// The News tab: new models from OpenRouter's public list, and announcements from official feeds.
@Observable
@MainActor
final class NewsStore {
    enum Keys {
        static let vendors = "newsVendors"
        static let sources = "newsSources"
    }

    private(set) var cache: NewsCache
    private(set) var isRefreshing = false

    /// Labs whose new models are announced, e.g. `anthropic`.
    var followedVendors: Set<String> {
        didSet { defaults.set(followedVendors.sorted(), forKey: Keys.vendors) }
    }

    /// Feed IDs from `FeedSource.catalog`.
    var followedSources: Set<String> {
        didSet { defaults.set(followedSources.sorted(), forKey: Keys.sources) }
    }

    private let defaults: UserDefaults
    private let directory: URL?

    init(
        defaults: UserDefaults = AppGroup.defaults,
        directory: URL? = AppGroup.containerURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ) {
        self.defaults = defaults
        self.directory = directory
        cache = NewsCache.load(from: directory)
        followedVendors = (defaults.array(forKey: Keys.vendors) as? [String]).map(Set.init) ?? ModelFeed.defaultVendors
        followedSources = (defaults.array(forKey: Keys.sources) as? [String]).map(Set.init) ?? Set(FeedSource.catalog.map(\.id))
    }

    var sources: [FeedSource] {
        FeedSource.catalog.filter { followedSources.contains($0.id) }
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

    /// Labs to offer in settings: followed ones, then others in the list, by name.
    var vendorChoices: [(id: String, name: String)] {
        var names: [String: String] = [:]
        for release in cache.models where names[release.vendor] == nil {
            names[release.vendor] = release.vendorName
        }
        for vendor in ModelFeed.defaultVendors where names[vendor] == nil {
            names[vendor] = vendor
        }
        return names.map { ($0.key, $0.value) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Fetches what's due, or anything older than `maxAge`.
    func refresh(maxAge: TimeInterval? = nil, preferences: AlertPreferences, now: Date = .now) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let result = await NewsFetcher.refresh(cache, sources: sources, following: followedVendors, maxAge: maxAge, now: now)
        cache = result.cache
        cache.save(to: directory)
        if preferences.newModels, !result.newModels.isEmpty {
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
