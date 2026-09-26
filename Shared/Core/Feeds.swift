import Foundation

// MARK: Model releases

/// A model as OpenRouter lists it: a public, key-free catalog of models from every lab.
struct ModelRelease: Codable, Equatable, Sendable, Identifiable {
    /// OpenRouter's canonical slug, e.g. `anthropic/claude-opus-5.5`.
    var id: String
    var name: String
    /// The lab, from the slug prefix, e.g. `anthropic`.
    var vendor: String
    var created: Date
    var contextLength: Int?
    /// Dollars per million tokens.
    var promptPrice: Double?
    var completionPrice: Double?
    /// When OpenRouter will retire it, if announced.
    var expires: Date?
}

enum ModelFeed {
    /// Newest first, 50 at a time. No key and no Anthropic-style headers: an
    /// `anthropic-version` header changes the response shape. About 75 KB, read with the usual
    /// `FeedParser.sizeLimit`.
    static let url = URL(string: "https://openrouter.ai/api/v1/models?sort=newest&limit=50")!

    /// The model list's entry in `NewsCache.unreadable`.
    static let id = "openrouter-models"

    /// Labs followed by default: the ones behind Tokenroom's providers.
    static let defaultVendors: Set<String> = ["anthropic", "openai", "x-ai", "google", "z-ai", "moonshotai", "minimax", "deepseek"]

    /// Names for OpenRouter's lab IDs, for labs not in the latest list.
    static let vendorNames: [String: String] = [
        "anthropic": "Anthropic", "openai": "OpenAI", "x-ai": "xAI", "google": "Google", "z-ai": "Z.ai",
        "moonshotai": "Moonshot AI", "minimax": "MiniMax", "deepseek": "DeepSeek",
    ]

    /// Releases newest first. Skips aliases (`~vendor/…`, `…-latest`), routers (`openrouter/…`),
    /// and stealth models; folds variants (`:free`, `:batch`, …) into their base model.
    static func releases(from data: Data) throws -> [ModelRelease] {
        let root = try JSONFlex.object(from: data)
        guard let items = JSONFlex.array(root["data"]) else { throw ProviderError.parse }
        var byID: [String: (release: ModelRelease, isBase: Bool)] = [:]
        for item in items {
            guard let model = JSONFlex.dictionary(item),
                  let rawID = JSONFlex.string(model["id"]),
                  let created = JSONFlex.date(model["created"])
            else { continue }
            let parts = rawID.split(separator: ":", maxSplits: 1).map(String.init)
            let id = parts[0]
            let variant = parts.count > 1 ? parts[1] : nil
            let slug = id.split(separator: "/", maxSplits: 1)
            guard slug.count == 2, !id.hasPrefix("~"), !id.hasSuffix("-latest"),
                  !["openrouter", "stealth"].contains(String(slug[0]))
            else { continue }
            var name = JSONFlex.string(model["name"]) ?? id
            if let variant, name.lowercased().hasSuffix(" (\(variant.lowercased()))") {
                name = String(name.dropLast(variant.count + 3))
            }
            let pricing = JSONFlex.dictionary(model["pricing"])
            let release = ModelRelease(
                id: id,
                name: name,
                vendor: String(slug[0]),
                created: created,
                contextLength: JSONFlex.number(model["context_length"]).map { Int($0) },
                promptPrice: JSONFlex.number(pricing?["prompt"]).map { $0 * 1_000_000 },
                completionPrice: JSONFlex.number(pricing?["completion"]).map { $0 * 1_000_000 },
                expires: JSONFlex.date(model["expiration_date"])
            )
            // The base model's prices win over a variant's.
            if byID[id] == nil || (variant == nil && byID[id]?.isBase == false) {
                byID[id] = (release, variant == nil)
            }
        }
        return byID.values.map(\.release).sorted { $0.created > $1.created }
    }
}

/// What the device has already seen, so only new releases are announced.
struct ModelFeedState: Codable, Equatable, Sendable {
    var newestSeen: Date?
    var seenIDs: [String] = []

    static let memory = 500

    /// New releases from followed labs since the last check, newest first. The first check
    /// only remembers what's there, so installing Tokenroom doesn't announce the whole catalog.
    mutating func takeNew(from releases: [ModelRelease], following vendors: Set<String>) -> [ModelRelease] {
        // An empty answer says nothing about the catalog, so it doesn't count as the first check.
        guard !releases.isEmpty else { return [] }
        let seen = Set(seenIDs)
        defer {
            seenIDs = Array((releases.map(\.id) + seenIDs).uniqued().prefix(Self.memory))
            newestSeen = max(newestSeen ?? .distantPast, releases.map(\.created).max() ?? .distantPast)
        }
        guard let newestSeen else { return [] }
        return releases.filter { release in
            vendors.contains(release.vendor) && !seen.contains(release.id) && release.created > newestSeen.addingTimeInterval(-86_400)
        }
    }
}

// MARK: Announcements

struct FeedItem: Codable, Equatable, Sendable, Identifiable {
    /// The item's guid or id, else its link.
    var id: String
    var title: String
    var link: URL?
    var published: Date?
    /// Which feed it came from, e.g. "Claude Code".
    var source: String

    /// Release feeds title entries with a bare version; "Codex 0.157.0" reads better in a list.
    var displayTitle: String {
        title.range(of: #"^v?\d+(\.\d+)+([-+.][0-9A-Za-z.]+)?$"#, options: .regularExpression) != nil
            ? "\(source) \(title)"
            : title
    }

    /// The same post or release in two of a product's feeds: the same title, or the same version
    /// under the same name ("Claude Code 2.1.282" from the changelog, "Claude Code v2.1.282" from
    /// GitHub). `NewsCache.announcements` compares it within a product only.
    var duplicateKey: String {
        displayTitle.lowercased().replacingOccurrences(of: #"\sv(?=\d)"#, with: " ", options: .regularExpression)
    }
}

/// An official news or changelog feed. Only RSS and Atom, never scraped pages.
struct FeedSource: Sendable, Identifiable, Equatable {
    var id: String
    var name: String
    var url: URL
    /// The provider it belongs to, for following.
    var provider: Provider?
    /// Drops pre-release entries (alpha, beta, rc) from release feeds.
    var skipsPrereleases = false
    /// Keeps only entries whose link contains this, e.g. a blog's announcements.
    var linkContains: String? = nil
    /// The most read from the feed, in bytes: a longer one stops there, and shows what it got.
    var sizeLimit = FeedParser.sizeLimit
    /// The feed it belongs to: a second source for the same product, shown under that feed's
    /// name and turned on and off with it.
    var partOf: String? = nil

    /// The name its items show, and fold duplicates under.
    var itemSource: String {
        partOf.flatMap { id in Self.catalog.first { $0.id == id }?.name } ?? name
    }

    /// Feeds people turn on and off; the ones `partOf` another follow it.
    static var toggles: [FeedSource] {
        catalog.filter { $0.partOf == nil }
    }

    static let catalog: [FeedSource] = [
        FeedSource(id: "claude-code", name: "Claude Code", url: URL(string: "https://code.claude.com/docs/en/changelog/rss.xml")!, provider: .claude),
        // The same versions as the changelog, often sooner; one shows when both have it.
        FeedSource(id: "claude-code-releases", name: "Claude Code releases", url: URL(string: "https://github.com/anthropics/claude-code/releases.atom")!, provider: .claude, skipsPrereleases: true, partOf: "claude-code"),
        FeedSource(id: "openai-news", name: "OpenAI", url: URL(string: "https://openai.com/news/rss.xml")!, provider: .openai),
        FeedSource(id: "codex-releases", name: "Codex", url: URL(string: "https://github.com/openai/codex/releases.atom")!, provider: .openai, skipsPrereleases: true),
        FeedSource(id: "gemini", name: "Google Gemini", url: URL(string: "https://blog.google/products-and-platforms/products/gemini/rss/")!, provider: .antigravity),
        FeedSource(id: "copilot", name: "GitHub Copilot", url: URL(string: "https://github.blog/changelog/label/copilot/feed/")!, provider: .copilot),
        FeedSource(id: "cursor", name: "Cursor", url: URL(string: "https://cursor.com/changelog/rss.xml")!, provider: .cursor),
        FeedSource(id: "devin", name: "Devin", url: URL(string: "https://docs.devin.ai/desktop/changelog/rss.xml")!, provider: .devin),
        FeedSource(id: "zai", name: "Z.ai", url: URL(string: "https://docs.z.ai/release-notes/new-released/rss.xml")!, provider: .zai),
        FeedSource(id: "kimi-code", name: "Kimi Code", url: URL(string: "https://github.com/MoonshotAI/kimi-code/releases.atom")!, provider: .kimiCode, skipsPrereleases: true),
        FeedSource(id: "openrouter", name: "OpenRouter", url: URL(string: "https://openrouter.ai/blog/feed.xml")!, provider: .openrouter, linkContains: "/blog/announcements/"),
        // ChatGPT and Codex product notes: each links to a `#codex-…` anchor, ChatGPT's included.
        // Its `#github-release-…` entries are CLI releases, which `codex-releases` already has.
        // Those embed each release's full notes (up to 360 KB apiece), so the feed's size follows
        // them: 1.2 MB in September 2026, 850 KB of it the last 13 releases. 4 MB, twice the
        // usual limit, leaves room for a run of long ones.
        FeedSource(id: "codex-changelog", name: "ChatGPT & Codex", url: URL(string: "https://learn.chatgpt.com/docs/changelog/rss.xml")!, provider: .openai, linkContains: "#codex-", sizeLimit: 4 * 1024 * 1024),
        FeedSource(id: "antigravity-blog", name: "Antigravity", url: URL(string: "https://antigravity.google/blog/rss.xml")!, provider: .antigravity),
        FeedSource(id: "antigravity-cli", name: "Antigravity CLI", url: URL(string: "https://github.com/google-antigravity/antigravity-cli/releases.atom")!, provider: .antigravity, skipsPrereleases: true),
        FeedSource(id: "minimax-code", name: "MiniMax Code", url: URL(string: "https://github.com/MiniMax-AI/minimax-code/releases.atom")!, provider: .minimax, skipsPrereleases: true),
    ]
}

/// Reads RSS 2.0 and Atom leniently: titles as plain text, the first 30 items.
enum FeedParser {
    static let itemLimit = 30
    /// The most read from a feed that doesn't set its own. In September 2026 the feeds ran from
    /// 5 KB (Devin) to 750 KB (OpenAI News, which keeps every post): 2 MB leaves room to grow, and
    /// bounds what a broken server can make a phone download.
    static let sizeLimit = 2 * 1024 * 1024

    static func items(from data: Data, source: FeedSource) -> [FeedItem] {
        read(data, source: source).items
    }

    /// The feed's items, and whether the whole document parsed. One cut short at the size limit,
    /// or broken, still gives the items that ended before the break.
    static func read(_ data: Data, source: FeedSource) -> (items: [FeedItem], isComplete: Bool) {
        let delegate = FeedXMLDelegate(source: source)
        let parser = XMLParser(data: data.prefix(source.sizeLimit))
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        let parsed = parser.parse()
        // Some feeds repeat a title for every small update ("ChatGPT for iOS"); keep the first.
        var titles = Set<String>()
        let items = delegate.items
            .filter { !source.skipsPrereleases || !isPrerelease($0.title) }
            .filter { item in source.linkContains.map { item.link?.absoluteString.contains($0) == true } ?? true }
            .filter { titles.insert($0.title.lowercased()).inserted }
            .prefix(itemLimit)
        return (Array(items), parsed && data.count <= source.sizeLimit)
    }

    /// An entry's link if it's a web page, resolved against the feed. Other schemes
    /// (`javascript:`, `file:`, an app's own) are dropped, so an item only ever opens the browser.
    static func webLink(_ text: String, feed: URL) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let url = URL(string: text, relativeTo: feed)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    /// Release titles like `@scope/package@2.1.1` read as the version alone.
    static func cleanTitle(_ title: String) -> String {
        title.replacingOccurrences(of: #"^@[^/\s]+/[^@\s]+@"#, with: "", options: .regularExpression)
    }

    static func isPrerelease(_ title: String) -> Bool {
        title.range(of: #"(?i)(-|\s)(alpha|beta|rc)(\b|\.|\d)"#, options: .regularExpression) != nil
    }

    /// HTML elements a title may carry. Other text in angle brackets is kept: "<thinking> blocks",
    /// a `</s>` token, `Either<A, B>`.
    private static let htmlTag = #"</?(?:a|abbr|b|big|br|cite|code|del|div|em|font|h[1-6]|hr|i|img|ins|kbd|li|mark|ol|p|pre|q|small|span|strong|sub|sup|time|tt|u|ul|wbr)(?:\s[^<>]*)?/?>"#

    /// Strips HTML tags, decodes entities left over from HTML titles, and collapses whitespace.
    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: htmlTag, with: " ", options: .regularExpression)
        for (entity, character) in ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        text = decodeNumericEntities(text).replacingOccurrences(of: "&amp;", with: "&")
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `&#8217;` and `&#x2019;`.
    static func decodeNumericEntities(_ text: String) -> String {
        guard text.contains("&#") else { return text }
        var result = ""
        var rest = Substring(text)
        while let range = rest.range(of: #"&#[xX]?[0-9a-fA-F]+;"#, options: .regularExpression) {
            result += rest[..<range.lowerBound]
            let body = rest[range].dropFirst(2).dropLast()
            let value = body.first == "x" || body.first == "X" ? UInt32(body.dropFirst(), radix: 16) : UInt32(body, radix: 10)
            if let value, let scalar = Unicode.Scalar(value) {
                result.unicodeScalars.append(scalar)
            } else {
                result += rest[range]
            }
            rest = rest[range.upperBound...]
        }
        return result + rest
    }

    static func date(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let iso = JSONFlex.parseISO(trimmed) {
            return iso
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }
}

private final class FeedXMLDelegate: NSObject, XMLParserDelegate {
    let source: FeedSource
    var items: [FeedItem] = []
    /// Depth inside the current item: 0 is the item, 1 its direct children. Nil between items.
    /// Only direct children count; feeds nest other titles (authors, cards) deeper.
    private var depth: Int?
    private var element = ""
    private var title = ""
    private var link: String?
    private var identifier = ""
    private var published = ""
    private var updated = ""

    init(source: FeedSource) {
        self.source = source
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        guard let current = depth else {
            if name == "item" || name == "entry" {
                depth = 0
                title = ""
                link = nil
                identifier = ""
                published = ""
                updated = ""
            }
            return
        }
        depth = current + 1
        element = current == 0 ? name : ""
        // Atom links live in attributes; prefer rel="alternate".
        if current == 0, name == "link", let href = attributes["href"], (attributes["rel"] ?? "alternate") == "alternate" {
            link = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        append(String(decoding: block, as: UTF8.self))
    }

    private func append(_ string: String) {
        guard depth == 1 else { return }
        switch element {
        case "title": title += string
        case "link": link = (link ?? "") + string.trimmingCharacters(in: .whitespacesAndNewlines)
        case "guid", "id": identifier += string
        case "pubDate", "published", "dc:date": published += string
        case "updated": updated += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard let current = depth else { return }
        element = ""
        guard current == 0 else {
            depth = current - 1
            return
        }
        depth = nil
        let cleanTitle = FeedParser.cleanTitle(FeedParser.plainText(title))
        guard !cleanTitle.isEmpty else { return }
        let url = link.flatMap { FeedParser.webLink($0, feed: source.url) }
        let id = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        items.append(FeedItem(
            id: id.isEmpty ? (url?.absoluteString ?? cleanTitle) : id,
            title: cleanTitle,
            link: url,
            published: FeedParser.date(published) ?? FeedParser.date(updated),
            source: source.itemSource
        ))
    }
}

extension Sequence where Element: Hashable {
    /// Keeps the first occurrence of each element, in order.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
