import Foundation

/// What the News tab shows, kept on the device: new models and official announcements.
/// Titles, dates, and links only.
struct NewsCache: Codable, Equatable, Sendable {
    static let fileName = "news.json"

    struct Validator: Codable, Equatable, Sendable {
        var etag: String?
        var lastModified: String?
    }

    var models: [ModelRelease] = []
    var modelsFetchedAt: Date?
    var modelState = ModelFeedState()
    /// Items per feed ID, newest first.
    var items: [String: [FeedItem]] = [:]
    var announcementsFetchedAt: Date?
    /// Conditional GET validators per URL, so unchanged feeds cost a 304.
    var validators: [String: Validator] = [:]

    /// Announcements from the given feeds, newest first. An entry two feeds share (the same
    /// link, title, or version) shows once: the newer copy, dated when the first one appeared, so
    /// it isn't new again when the second feed catches up.
    func announcements(from sources: [FeedSource], limit: Int = 80) -> [FeedItem] {
        let ids = Set(sources.map(\.id))
        let newestFirst: (FeedItem, FeedItem) -> Bool = { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
        var kept: [FeedItem] = []
        var positions: [String: Int] = [:]
        for item in items.filter({ ids.contains($0.key) }).values.flatMap({ $0 }).sorted(by: newestFirst) {
            let keys = [item.link?.absoluteString, item.duplicateKey].compactMap { $0 }
            if let position = keys.lazy.compactMap({ positions[$0] }).first {
                if let published = item.published, published < (kept[position].published ?? .distantFuture) {
                    kept[position].published = published
                }
                keys.forEach { positions[$0] = position }
                continue
            }
            keys.forEach { positions[$0] = kept.count }
            kept.append(item)
        }
        return Array(kept.sorted(by: newestFirst).prefix(limit))
    }

    static func load(from directory: URL?) -> NewsCache {
        guard let url = directory?.appendingPathComponent(fileName),
              let data = try? Data(contentsOf: url),
              let cache = try? RelayEnvelope.decoder.decode(NewsCache.self, from: data)
        else { return NewsCache() }
        return cache
    }

    func save(to directory: URL?) {
        guard let url = directory?.appendingPathComponent(Self.fileName),
              let data = try? RelayEnvelope.encoder.encode(self)
        else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

enum NewsFetcher {
    static let modelInterval: TimeInterval = 6 * 3600
    static let announcementInterval: TimeInterval = 12 * 3600
    /// Opening the News tab refreshes anything older than this.
    static let openInterval: TimeInterval = 3600

    struct Result: Sendable {
        var cache: NewsCache
        /// New releases from followed labs since the last check, for a notification.
        var newModels: [ModelRelease]
    }

    /// Fetches what's due: models every 6 hours, announcements every 12, or anything older than
    /// `maxAge` when given (opening the tab, pulling to refresh).
    static func refresh(_ cache: NewsCache, sources: [FeedSource], following vendors: Set<String>, maxAge: TimeInterval? = nil, now: Date = .now) async -> Result {
        var cache = cache
        var newModels: [ModelRelease] = []

        if isDue(cache.modelsFetchedAt, interval: maxAge ?? modelInterval, now: now) {
            let (data, validator, notModified) = await get(ModelFeed.url, validator: cache.validators[ModelFeed.url.absoluteString])
            if let data, let releases = try? ModelFeed.releases(from: data) {
                cache.models = releases
                newModels = cache.modelState.takeNew(from: releases, following: vendors)
            }
            if data != nil || notModified {
                cache.modelsFetchedAt = now
                cache.validators[ModelFeed.url.absoluteString] = validator ?? cache.validators[ModelFeed.url.absoluteString]
            }
        }

        if isDue(cache.announcementsFetchedAt, interval: maxAge ?? announcementInterval, now: now) {
            let previous = cache.validators
            let results = await withTaskGroup(of: (FeedSource, Data?, NewsCache.Validator?, Bool).self) { group in
                for source in sources {
                    group.addTask {
                        let (data, validator, notModified) = await get(source.url, validator: previous[source.url.absoluteString], sizeLimit: source.sizeLimit)
                        return (source, data, validator, notModified)
                    }
                }
                var results: [(FeedSource, Data?, NewsCache.Validator?, Bool)] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }
            var anyAnswered = false
            for (source, data, validator, notModified) in results {
                if let data {
                    cache.items[source.id] = FeedParser.items(from: data, source: source)
                }
                if data != nil || notModified {
                    anyAnswered = true
                    cache.validators[source.url.absoluteString] = validator ?? cache.validators[source.url.absoluteString]
                }
            }
            if anyAnswered {
                cache.announcementsFetchedAt = now
            }
        }
        return Result(cache: cache, newModels: newModels)
    }

    static func isDue(_ fetchedAt: Date?, interval: TimeInterval, now: Date) -> Bool {
        fetchedAt.map { now.timeIntervalSince($0) >= interval } ?? true
    }

    /// A conditional GET. Nil data with `notModified` means the cached copy is current.
    static func get(_ url: URL, validator: NewsCache.Validator?, sizeLimit: Int = FeedParser.sizeLimit) async -> (Data?, NewsCache.Validator?, Bool) {
        var request = URLRequest(url: url)
        request.setValue("application/rss+xml, application/atom+xml, application/json, */*;q=0.5", forHTTPHeaderField: "Accept")
        if let etag = validator?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = validator?.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        guard let (data, response) = try? await TokenroomHTTP.data(for: request) else { return (nil, nil, false) }
        if response.statusCode == 304 {
            return (nil, validator, true)
        }
        guard (200..<300).contains(response.statusCode), data.count <= sizeLimit else { return (nil, nil, false) }
        let fresh = NewsCache.Validator(
            etag: response.value(forHTTPHeaderField: "ETag"),
            lastModified: response.value(forHTTPHeaderField: "Last-Modified")
        )
        return (data, fresh, false)
    }
}

extension ModelRelease {
    /// "Anthropic: Claude Opus 5.5" reads as "Claude Opus 5.5" under its lab's name.
    var shortName: String {
        guard let colon = name.range(of: ": ") else { return name }
        return String(name[colon.upperBound...])
    }

    /// The lab as OpenRouter names it, e.g. "Anthropic".
    var vendorName: String {
        name.range(of: ": ").map { String(name[..<$0.lowerBound]) } ?? vendor
    }

    var link: URL? {
        URL(string: "https://openrouter.ai/\(id)")
    }
}
