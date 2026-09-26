import XCTest
@testable import Tokenroom

final class FeedTests: XCTestCase {
    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        Calendar.gregorianUTC.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    // MARK: Model releases

    private let models = Data("""
    {"data":[
      {"id":"anthropic/claude-opus-5.5:batch","name":"Anthropic: Claude Opus 5.5 (batch)","created":1790094732,"pricing":{"prompt":"0.000002","completion":"0.00001"}},
      {"id":"anthropic/claude-opus-5.5","canonical_slug":"anthropic/claude-opus-5.5-20260921","name":"Anthropic: Claude Opus 5.5","created":1790094732,"context_length":1000000,"pricing":{"prompt":"0.000004","completion":"0.00002"}},
      {"id":"z-ai/glm-5.3-prime","name":"Z.ai: GLM 5.3 Prime","created":1790199651,"pricing":{"prompt":"0.0000028","completion":"0.000011"}},
      {"id":"nex-agi/nex-n2.5-mini:free","name":"Nex AGI: Nex-N2.5-Mini (free)","created":1788890061,"pricing":{"prompt":"0","completion":"0"},"expiration_date":"2026-09-25"},
      {"id":"~openai/gpt-luna-latest","name":"OpenAI: GPT Luna Latest","created":1789130922},
      {"id":"openai/gpt-sol-latest","name":"OpenAI: GPT Sol Latest","created":1789130921},
      {"id":"openrouter/auto","name":"Auto Router","created":1789130920},
      {"id":"stealth/space-bunny-alpha","name":"Space Bunny Alpha","created":1790174884}
    ]}
    """.utf8)

    func testModelReleasesFoldVariantsAndSkipAliases() throws {
        let releases = try ModelFeed.releases(from: models)
        XCTAssertEqual(releases.map(\.id), ["z-ai/glm-5.3-prime", "anthropic/claude-opus-5.5", "nex-agi/nex-n2.5-mini"])
        let opus = releases[1]
        XCTAssertEqual(opus.name, "Anthropic: Claude Opus 5.5")
        XCTAssertEqual(opus.vendor, "anthropic")
        XCTAssertEqual(opus.promptPrice ?? 0, 4, accuracy: 0.0001, "The base model's price per million tokens, not the batch one's")
        XCTAssertEqual(opus.contextLength, 1_000_000)
        let free = releases[2]
        XCTAssertEqual(free.name, "Nex AGI: Nex-N2.5-Mini", "A variant alone keeps its model, without the suffix")
        XCTAssertEqual(free.expires, utc(2026, 9, 25))
    }

    func testFirstCheckSeedsQuietlyThenOnlyNewFollowedReleasesAnnounce() throws {
        var state = ModelFeedState()
        let first = try ModelFeed.releases(from: models)
        XCTAssertEqual(state.takeNew(from: first, following: ModelFeed.defaultVendors), [], "Installing Tokenroom doesn't announce the whole catalog")

        let newer = ModelRelease(id: "openai/gpt-6-luna", name: "OpenAI: GPT-6 Luna", vendor: "openai", created: utc(2026, 9, 26), contextLength: nil, promptPrice: nil, completionPrice: nil, expires: nil)
        let unfollowed = ModelRelease(id: "qwen/qwen3.8-max", name: "Qwen: Qwen3.8 Max", vendor: "qwen", created: utc(2026, 9, 26), contextLength: nil, promptPrice: nil, completionPrice: nil, expires: nil)
        let second = [newer, unfollowed] + first
        XCTAssertEqual(state.takeNew(from: second, following: ModelFeed.defaultVendors).map(\.id), ["openai/gpt-6-luna"])
        XCTAssertEqual(state.takeNew(from: second, following: ModelFeed.defaultVendors), [], "Each release is announced once")
    }

    func testAnEmptyFirstAnswerDoesntEndTheQuietSeed() throws {
        var state = ModelFeedState()
        XCTAssertEqual(state.takeNew(from: [], following: ModelFeed.defaultVendors), [])
        XCTAssertNil(state.newestSeen, "An empty answer isn't a first check")
        XCTAssertEqual(state.takeNew(from: try ModelFeed.releases(from: models), following: ModelFeed.defaultVendors), [], "The first real answer still only remembers what's there")
    }

    // MARK: Announcements

    private let claudeCode = FeedSource(id: "claude-code", name: "Claude Code", url: URL(string: "https://example.com/rss.xml")!)

    func testRSSWithCDATAEntitiesAndTags() {
        let rss = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/"><channel><title>Changelog</title>
          <item><title><![CDATA[2.1.282]]></title><link>https://example.com/changelog#2-1-282</link>
            <guid isPermaLink="false">d2514dd17c2aa91e</guid><pubDate>Thu, 24 Sep 2026 18:46:38 GMT</pubDate>
            <description><![CDATA[<p>Fixes</p>]]></description></item>
          <item><title>Sam Altman&amp;#8217;s remarks &lt;b&gt;today&lt;/b&gt;</title><link>https://example.com/remarks</link>
            <dc:date>2026-09-23T12:00:00Z</dc:date></item>
          <item><title>   </title><link>https://example.com/empty</link></item>
        </channel></rss>
        """.utf8)
        let items = FeedParser.items(from: rss, source: claudeCode)
        XCTAssertEqual(items.map(\.title), ["2.1.282", "Sam Altman\u{2019}s remarks today"])
        XCTAssertEqual(items[0].id, "d2514dd17c2aa91e")
        XCTAssertEqual(items[0].published, utc(2026, 9, 24, 18, 46, 38))
        XCTAssertEqual(items[0].source, "Claude Code")
        XCTAssertEqual(items[1].id, "https://example.com/remarks", "No guid: the link identifies the item")
        XCTAssertEqual(items[1].published, utc(2026, 9, 23, 12))
    }

    func testAtomReleasesDropPrereleasesAndPackagePrefixes() {
        let atom = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom"><id>tag:example,2008:releases</id><title>Releases</title><updated>2026-09-25T13:02:46Z</updated>
          <entry><id>tag:example,2008:Repository/1/v0.158.0-alpha.14</id><updated>2026-09-25T13:02:46Z</updated>
            <link rel="alternate" type="text/html" href="https://example.com/releases/tag/v0.158.0-alpha.14"/><title>0.158.0-alpha.14</title></entry>
          <entry><id>tag:example,2008:Repository/1/v0.157.0</id><updated>2026-09-25T02:32:43Z</updated>
            <link rel="alternate" type="text/html" href="https://example.com/releases/tag/v0.157.0"/><title>0.157.0</title></entry>
          <entry><id>tag:example,2008:Repository/2/kimi-code-2.1.1</id><published>2026-09-24T07:45:05Z</published><updated>2026-09-25T00:00:00Z</updated>
            <link rel="alternate" href="https://example.com/releases/tag/kimi-code-2.1.1"/><title>@moonshot-ai/kimi-code@2.1.1</title></entry>
          <entry><id>tag:example,2008:Repository/2/kimi-code-2.2.0-rc.1</id><updated>2026-09-25T00:00:00Z</updated><title>@moonshot-ai/kimi-code@2.2.0-rc.1</title></entry>
        </feed>
        """.utf8)
        let source = FeedSource(id: "releases", name: "Releases", url: URL(string: "https://example.com/releases.atom")!, skipsPrereleases: true)
        let items = FeedParser.items(from: atom, source: source)
        XCTAssertEqual(items.map(\.title), ["0.157.0", "2.1.1"])
        XCTAssertEqual(items[0].link?.absoluteString, "https://example.com/releases/tag/v0.157.0")
        XCTAssertEqual(items[0].published, utc(2026, 9, 25, 2, 32, 43), "Atom's updated when there's no published")
        XCTAssertEqual(items[1].published, utc(2026, 9, 24, 7, 45, 5), "published wins over updated")
    }

    func testOnlyAnItemsOwnTitleCounts() {
        let rss = Data("""
        <rss version="2.0"><channel><item>
          <title>Introducing Gemini Live</title>
          <og><title>Introducing Gemini Live</title><image>https://example.com/card.png</image></og>
          <link>https://example.com/gemini-live</link>
          <author><name>Placeholder Author</name><title>Research Scientist</title></author>
          <pubDate>Thu, 24 Sep 2026 15:30:00 +0000</pubDate>
        </item></channel></rss>
        """.utf8)
        let items = FeedParser.items(from: rss, source: claudeCode)
        XCTAssertEqual(items.map(\.title), ["Introducing Gemini Live"])
        XCTAssertEqual(items.first?.published, utc(2026, 9, 24, 15, 30))
    }

    func testLinkFilterKeepsOnlyAnnouncements() {
        let rss = Data("""
        <rss version="2.0"><channel>
          <item><title>Batch API</title><link>https://example.com/blog/announcements/batch-api/</link><pubDate>Tue, 22 Sep 2026 00:00:00 GMT</pubDate></item>
          <item><title>Is it open source?</title><link>https://example.com/blog/insights/open-source/</link><pubDate>Fri, 25 Sep 2026 00:00:00 GMT</pubDate></item>
        </channel></rss>
        """.utf8)
        let source = FeedSource(id: "blog", name: "Blog", url: URL(string: "https://example.com/feed.xml")!, linkContains: "/blog/announcements/")
        XCTAssertEqual(FeedParser.items(from: rss, source: source).map(\.title), ["Batch API"])
    }

    func testTitlesKeepAngleBracketsThatArentHTML() {
        XCTAssertEqual(FeedParser.plainText("Support for <thinking> blocks"), "Support for <thinking> blocks")
        XCTAssertEqual(FeedParser.plainText("Fix </s> handling in Either<A, B>"), "Fix </s> handling in Either<A, B>")
        XCTAssertEqual(FeedParser.plainText("Use <code>--resume</code> to <b>pick up</b><br/>a session"), "Use --resume to pick up a session")
        XCTAssertEqual(FeedParser.plainText(#"<a href="https://example.com">Read</a> <img src="card.png"> more"#), "Read more")
        let rss = Data("<rss version=\"2.0\"><channel><item><title>Support for &lt;thinking&gt; blocks</title><link>https://example.com/thinking</link></item></channel></rss>".utf8)
        XCTAssertEqual(FeedParser.items(from: rss, source: claudeCode).map(\.title), ["Support for <thinking> blocks"], "Escaped in the feed, still text")
    }

    func testLinksAreWebPagesOnly() {
        let rss = Data("""
        <rss version="2.0"><channel>
          <item><title>Script</title><link>javascript:alert(1)</link></item>
          <item><title>File</title><link>file:///tmp/feed</link></item>
          <item><title>App</title><link>shortcuts://run-shortcut?name=x</link></item>
          <item><title>Relative</title><link>/blog/relative</link></item>
          <item><title>Web</title><link>https://example.com/web</link></item>
        </channel></rss>
        """.utf8)
        let items = FeedParser.items(from: rss, source: claudeCode)
        XCTAssertEqual(items.map { $0.link?.absoluteString }, [nil, nil, nil, "https://example.com/blog/relative", "https://example.com/web"], "Web pages only; a relative link is on the feed's site")
        XCTAssertEqual(items.first?.id, "Script", "No guid and no usable link: the title identifies it")
    }

    func testLimitsItemsAndSize() {
        let items = (0..<40).map { "<item><title>Post \($0)</title><link>https://example.com/\($0)</link></item>" }.joined()
        let rss = Data("<rss version=\"2.0\"><channel>\(items)</channel></rss>".utf8)
        XCTAssertEqual(FeedParser.items(from: rss, source: claudeCode).count, FeedParser.itemLimit)
        XCTAssertTrue(FeedParser.items(from: Data(count: FeedParser.sizeLimit + 1), source: claudeCode).isEmpty)
    }

    // MARK: Fetching

    func testConditionalGetsKeepCachedItemsOn304() async throws {
        defer {
            TokenroomHTTP.overrideSession(nil)
            StubURLProtocol.reset()
        }
        let rss = Data("<rss version=\"2.0\"><channel><item><title>2.1.282</title><link>https://example.com/a</link><pubDate>Thu, 24 Sep 2026 18:46:38 GMT</pubDate></item></channel></rss>".utf8)
        StubURLProtocol.handler = { request in
            request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"" ? (304, Data()) : (200, rss)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubETagProtocol.self]
        TokenroomHTTP.overrideSession(URLSession(configuration: configuration))

        let source = FeedSource(id: "claude-code", name: "Claude Code", url: URL(string: "https://example.com/rss.xml")!)
        let now = utc(2026, 9, 25, 12)
        let first = await NewsFetcher.refresh(NewsCache(), sources: [source], following: [], now: now)
        XCTAssertEqual(first.cache.items["claude-code"]?.map(\.title), ["2.1.282"])
        XCTAssertEqual(first.cache.validators[source.url.absoluteString]?.etag, "\"v1\"")

        let second = await NewsFetcher.refresh(first.cache, sources: [source], following: [], maxAge: 0, now: now.addingTimeInterval(60))
        XCTAssertEqual(StubURLProtocol.requests.last?.value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
        XCTAssertEqual(second.cache.items["claude-code"]?.map(\.title), ["2.1.282"], "A 304 keeps what was cached")
        XCTAssertEqual(second.cache.announcementsFetchedAt, now.addingTimeInterval(60))
        XCTAssertFalse(NewsFetcher.isDue(second.cache.announcementsFetchedAt, interval: NewsFetcher.announcementInterval, now: now.addingTimeInterval(3600)))
    }

    func testTheModelsRequestSendsNoAnthropicVersion() async {
        defer {
            TokenroomHTTP.overrideSession(nil)
            StubURLProtocol.reset()
        }
        StubURLProtocol.handler = { _ in (200, Data(#"{"data":[]}"#.utf8)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        TokenroomHTTP.overrideSession(URLSession(configuration: configuration))
        _ = await NewsFetcher.refresh(NewsCache(), sources: [], following: ["anthropic"], now: utc(2026, 9, 25, 12))
        let request = StubURLProtocol.requests.first { $0.url == ModelFeed.url }
        XCTAssertNotNil(request, "The models list was asked for")
        XCTAssertNil(request?.value(forHTTPHeaderField: "anthropic-version"), "That header changes OpenRouter's answer")
    }

    /// Answers every request with `handler`, through `StubETagProtocol`. Pair with `unstubNetwork`.
    private func stubNetwork(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) {
        StubURLProtocol.reset()
        StubURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubETagProtocol.self]
        TokenroomHTTP.overrideSession(URLSession(configuration: configuration))
    }

    private func unstubNetwork() {
        TokenroomHTTP.overrideSession(nil)
        StubURLProtocol.reset()
    }

    private static let noModels = Data(#"{"data":[]}"#.utf8)

    func testTheSizeLimitStopsTheDownload() async {
        defer { unstubNetwork() }
        stubNetwork { _ in (200, Data(repeating: UInt8(ascii: "x"), count: 3000)) }
        let url = URL(string: "https://example.com/big.xml")!
        guard case let .body(data, _, isTruncated) = await NewsFetcher.get(url, validator: nil, sizeLimit: 1024) else {
            return XCTFail("A 200 has a body")
        }
        XCTAssertEqual(data.count, 1024, "Reading stops at the limit")
        XCTAssertTrue(isTruncated)
        guard case let .body(whole, _, cut) = await NewsFetcher.get(url, validator: nil, sizeLimit: 3000) else {
            return XCTFail("A 200 has a body")
        }
        XCTAssertEqual(whole.count, 3000)
        XCTAssertFalse(cut, "A body exactly at the limit is whole")
    }

    func testAFeedPastItsLimitShowsWhatArrivedAndSaysSo() async {
        defer { unstubNetwork() }
        let long = Data("""
        <rss version="2.0"><channel>
          <item><title>Short post</title><link>https://example.com/short</link><pubDate>Thu, 24 Sep 2026 12:00:00 GMT</pubDate></item>
          <item><title>Long post</title><link>https://example.com/long</link><pubDate>Wed, 23 Sep 2026 12:00:00 GMT</pubDate><description>\(String(repeating: "Notes. ", count: 400))</description></item>
        </channel></rss>
        """.utf8)
        stubNetwork { request in request.url == ModelFeed.url ? (200, Self.noModels) : (200, long) }
        let source = FeedSource(id: "long", name: "Long", url: URL(string: "https://example.com/long.xml")!, sizeLimit: 1024)
        let now = utc(2026, 9, 25, 12)
        let first = await NewsFetcher.refresh(NewsCache(), sources: [source], following: [], now: now)
        XCTAssertEqual(first.cache.items["long"]?.map(\.title), ["Short post"], "What arrived before the limit")
        XCTAssertNil(first.cache.validators[source.url.absoluteString], "Not taken for the whole feed: no 304 keeps it")
        XCTAssertEqual(first.cache.unreadable, ["long"])
        XCTAssertEqual(first.cache.announcementsFetchedAt, now, "It answered: it waits for the next check like the others")

        let short = Data("<rss version=\"2.0\"><channel><item><title>Short post</title><link>https://example.com/short</link></item></channel></rss>".utf8)
        StubURLProtocol.handler = { request in request.url == ModelFeed.url ? (200, Self.noModels) : (200, short) }
        let second = await NewsFetcher.refresh(first.cache, sources: [source], following: [], maxAge: 0, now: now.addingTimeInterval(60))
        XCTAssertNil(second.cache.unreadable, "Read in full again")
        XCTAssertEqual(second.cache.validators[source.url.absoluteString]?.etag, "\"v1\"")
    }

    func testABrokenFeedKeepsWhatItHad() async {
        defer { unstubNetwork() }
        let page = Data("<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>Down for maintenance</body></html>".utf8)
        stubNetwork { request in request.url == ModelFeed.url ? (200, Self.noModels) : (200, page) }
        var cache = NewsCache()
        cache.items["claude-code"] = [FeedItem(id: "old", title: "2.1.282", link: URL(string: "https://example.com/2-1-282"), published: utc(2026, 9, 24), source: "Claude Code")]
        cache.validators[claudeCode.url.absoluteString] = NewsCache.Validator(etag: "\"v0\"")
        let result = await NewsFetcher.refresh(cache, sources: [claudeCode], following: [], now: utc(2026, 9, 25, 12))
        XCTAssertEqual(result.cache.items["claude-code"]?.map(\.id), ["old"], "A page that isn't the feed leaves the last items")
        XCTAssertNil(result.cache.validators[claudeCode.url.absoluteString])
        XCTAssertEqual(result.cache.unreadable, ["claude-code"])
    }

    func testFailedChecksWaitBeforeAskingAgain() async {
        defer { unstubNetwork() }
        stubNetwork { _ in (503, Data()) }
        let now = utc(2026, 9, 25, 12)
        var cache = await NewsFetcher.refresh(NewsCache(), sources: [claudeCode], following: [], now: now).cache
        XCTAssertEqual(StubURLProtocol.requests.count, 2, "The model list and the feed")
        XCTAssertEqual(cache.modelsFailedAt, now)
        XCTAssertEqual(cache.announcementsFailedAt, now)
        XCTAssertEqual(cache.unreadable, [ModelFeed.id, "claude-code"])

        cache = await NewsFetcher.refresh(cache, sources: [claudeCode], following: [], now: now.addingTimeInterval(600)).cache
        XCTAssertEqual(StubURLProtocol.requests.count, 2, "The next refresh doesn't ask again")

        cache = await NewsFetcher.refresh(cache, sources: [claudeCode], following: [], maxAge: 0, now: now.addingTimeInterval(660)).cache
        XCTAssertEqual(StubURLProtocol.requests.count, 4, "Asking now (pulling to refresh, Check now) still goes out")

        _ = await NewsFetcher.refresh(cache, sources: [claudeCode], following: [], now: now.addingTimeInterval(660 + NewsFetcher.retryInterval))
        XCTAssertEqual(StubURLProtocol.requests.count, 6, "An hour after the last try, it tries again")
    }

    func testCatalogIsHTTPSAndUnique() {
        XCTAssertEqual(Set(FeedSource.catalog.map(\.id)).count, FeedSource.catalog.count)
        XCTAssertTrue(FeedSource.catalog.allSatisfy { $0.url.scheme == "https" })
    }

    func testCodexChangelogKeepsOnlyCodexNotesAndMayBeLarger() throws {
        let changelog = try XCTUnwrap(FeedSource.catalog.first { $0.id == "codex-changelog" })
        XCTAssertEqual(changelog.linkContains, "#codex-", "Its CLI entries repeat codex-releases")
        XCTAssertEqual(changelog.sizeLimit, 4 * 1024 * 1024)
        XCTAssertTrue(FeedSource.catalog.filter { $0.url.host == "github.com" }.allSatisfy(\.skipsPrereleases), "Release feeds skip pre-releases")
        XCTAssertTrue(FeedSource.catalog.filter { $0.id != "codex-changelog" }.allSatisfy { $0.sizeLimit == FeedParser.sizeLimit })
    }

    // MARK: Titles and duplicates

    func testBareVersionTitlesNameTheirFeed() {
        func title(_ text: String) -> String {
            FeedItem(id: text, title: text, link: nil, published: nil, source: "Codex").displayTitle
        }
        XCTAssertEqual(title("0.157.0"), "Codex 0.157.0")
        XCTAssertEqual(title("v2.1.282"), "Codex v2.1.282")
        XCTAssertEqual(title("1.2.0-beta.1"), "Codex 1.2.0-beta.1")
        XCTAssertEqual(title("Introducing GPT-6"), "Introducing GPT-6")
        XCTAssertEqual(title("Codex 0.157.0"), "Codex 0.157.0", "Already named")
        XCTAssertEqual(title("2026"), "2026", "A year isn't a version")
    }

    func testARepeatedTitleInOneFeedShowsOnce() {
        let rss = Data("""
        <rss version="2.0"><channel>
          <item><title>ChatGPT for iOS</title><link>https://example.com/ios-3</link><pubDate>Thu, 24 Sep 2026 12:00:00 GMT</pubDate></item>
          <item><title>Projects in ChatGPT</title><link>https://example.com/projects</link><pubDate>Wed, 23 Sep 2026 12:00:00 GMT</pubDate></item>
          <item><title>chatgpt for iOS</title><link>https://example.com/ios-2</link><pubDate>Tue, 22 Sep 2026 12:00:00 GMT</pubDate></item>
        </channel></rss>
        """.utf8)
        let items = FeedParser.items(from: rss, source: claudeCode)
        XCTAssertEqual(items.map(\.title), ["ChatGPT for iOS", "Projects in ChatGPT"])
        XCTAssertEqual(items.first?.link?.absoluteString, "https://example.com/ios-3", "The first, newest one stays")
    }

    func testAnAnnouncementTwoFeedsShareShowsOnce() {
        let shared = URL(string: "https://example.com/blog/launch")!
        var cache = NewsCache()
        cache.items = [
            "blog": [
                FeedItem(id: "b1", title: "Launch", link: shared, published: utc(2026, 9, 24), source: "Blog"),
                FeedItem(id: "b2", title: "Without a link", link: nil, published: utc(2026, 9, 20), source: "Blog"),
            ],
            "news": [
                FeedItem(id: "n1", title: "Launch", link: shared, published: utc(2026, 9, 23), source: "News"),
                FeedItem(id: "n2", title: "Also without a link", link: nil, published: utc(2026, 9, 19), source: "News"),
            ],
        ]
        let sources = ["blog", "news"].map { FeedSource(id: $0, name: $0, url: URL(string: "https://example.com/\($0).xml")!) }
        XCTAssertEqual(cache.announcements(from: sources).map(\.id), ["b1", "b2", "n2"], "The newest copy of a shared link; items without links all stay")
        XCTAssertEqual(cache.announcements(from: [sources[1]]).map(\.id), ["n1", "n2"], "Alone, a feed keeps its copy")
    }

    func testTitlesOnlyFoldWithinAProduct() {
        var cache = NewsCache()
        cache.items = [
            "zai": [FeedItem(id: "z1", title: "Release notes", link: URL(string: "https://example.com/zai/notes"), published: utc(2026, 9, 24), source: "Z.ai")],
            "devin": [FeedItem(id: "d1", title: "Release notes", link: URL(string: "https://example.com/devin/notes"), published: utc(2026, 9, 20), source: "Devin")],
            "cursor": [FeedItem(id: "c1", title: "Faster agents", link: URL(string: "https://example.com/launch"), published: utc(2026, 9, 23), source: "Cursor")],
            "copilot": [FeedItem(id: "g1", title: "Agents everywhere", link: URL(string: "https://example.com/launch"), published: utc(2026, 9, 22), source: "GitHub Copilot")],
        ]
        let shown = cache.announcements(from: FeedSource.catalog)
        XCTAssertEqual(shown.map(\.id), ["z1", "c1", "d1"], "Two labs' \"Release notes\" are two posts; two products linking to one page are one")
        XCTAssertEqual(shown.last?.published, utc(2026, 9, 20), "Each dated by its own feed")
    }

    func testTheSameVersionFromTwoFeedsShowsOnce() throws {
        let releases = try XCTUnwrap(FeedSource.catalog.first { $0.id == "claude-code-releases" })
        XCTAssertEqual(releases.partOf, "claude-code")
        XCTAssertFalse(FeedSource.toggles.contains(releases), "It's turned on and off with the changelog")
        let atom = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Release notes from claude-code</title>
          <entry><id>tag:github.com,2008:Repository/1/v2.1.283</id><updated>2026-09-25T18:00:00Z</updated>
            <link rel="alternate" type="text/html" href="https://github.com/anthropics/claude-code/releases/tag/v2.1.283"/><title>v2.1.283</title></entry>
          <entry><id>tag:github.com,2008:Repository/1/v2.1.282</id><updated>2026-09-24T18:00:00Z</updated>
            <link rel="alternate" type="text/html" href="https://github.com/anthropics/claude-code/releases/tag/v2.1.282"/><title>v2.1.282</title></entry>
        </feed>
        """.utf8)
        var cache = NewsCache()
        cache.items = [
            "claude-code": [FeedItem(id: "c1", title: "2.1.282", link: URL(string: "https://code.claude.com/docs/en/changelog#2-1-282"), published: utc(2026, 9, 24, 20), source: "Claude Code")],
            "claude-code-releases": FeedParser.items(from: atom, source: releases),
        ]
        let shown = cache.announcements(from: FeedSource.catalog)
        XCTAssertEqual(shown.map(\.displayTitle), ["Claude Code v2.1.283", "Claude Code 2.1.282"], "2.1.282 is in both feeds and shows once; 2.1.283 isn't in the changelog yet")
        XCTAssertEqual(Set(shown.map(\.source)), ["Claude Code"], "Both read as Claude Code")
        XCTAssertEqual(shown.last?.published, utc(2026, 9, 24, 18), "Dated when the first copy appeared, so the second doesn't make it new again")
    }

    func testEachFeedHasItsOwnSizeLimit() {
        let notes = String(repeating: "Release notes. ", count: 180_000) // about 2.6 MB
        let rss = Data("<rss version=\"2.0\"><channel><item><title>Long notes</title><link>https://example.com/notes</link><description>\(notes)</description></item></channel></rss>".utf8)
        XCTAssertGreaterThan(rss.count, FeedParser.sizeLimit)
        XCTAssertTrue(FeedParser.items(from: rss, source: claudeCode).isEmpty)
        let larger = FeedSource(id: "long", name: "Long", url: URL(string: "https://example.com/long.xml")!, sizeLimit: 4 * 1024 * 1024)
        XCTAssertEqual(FeedParser.items(from: rss, source: larger).map(\.title), ["Long notes"])
    }

    // MARK: What's new since News was opened

    private var suites: [String] = []
    private var folders: [URL] = []

    override func tearDown() {
        suites.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        suites = []
        folders = []
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        // Named by the class and a count: macOS keeps an empty preferences file for every name.
        let name = "tokenroom.tests.\(Self.self).\(suites.count)"
        suites.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    /// A News folder holding two followed releases, one unfollowed, and two Claude Code notes.
    private func makeNewsFolder() throws -> URL {
        let folder = try makeFolder()
        func release(_ id: String, _ vendor: String, _ created: Date) -> ModelRelease {
            ModelRelease(id: id, name: id, vendor: vendor, created: created, contextLength: nil, promptPrice: nil, completionPrice: nil, expires: nil)
        }
        var cache = NewsCache()
        cache.models = [
            release("anthropic/claude-new", "anthropic", utc(2026, 9, 25, 9)),
            release("qwen/qwen-new", "qwen", utc(2026, 9, 25, 9)),
            release("openai/gpt-old", "openai", utc(2026, 9, 20)),
        ]
        cache.items = ["claude-code": [
            FeedItem(id: "new", title: "2.1.300", link: URL(string: "https://example.com/2-1-300"), published: utc(2026, 9, 25, 8), source: "Claude Code"),
            FeedItem(id: "old", title: "2.1.200", link: URL(string: "https://example.com/2-1-200"), published: utc(2026, 9, 1), source: "Claude Code"),
        ]]
        cache.save(to: folder)
        return folder
    }

    @MainActor
    func testUnseenCountsCoverFollowedNewsSinceTheLastVisit() throws {
        let defaults = makeDefaults()
        let folder = try makeNewsFolder()
        defaults.set(utc(2026, 9, 24).timeIntervalSince1970, forKey: NewsStore.Keys.seenAt)
        let news = NewsStore(defaults: defaults, directory: folder, now: utc(2026, 9, 25, 12))
        XCTAssertEqual(news.unseenModelCount, 1, "Only labs that are followed")
        XCTAssertEqual(news.unseenAnnouncementCount, 1)
        XCTAssertEqual(news.unseenCount, 2)

        news.markSeen(now: utc(2026, 9, 25, 12))
        XCTAssertEqual(news.unseenCount, 0, "Opening News clears the badge")
        XCTAssertTrue(news.isNew(utc(2026, 9, 25, 8)), "…and keeps this visit's new items marked")
        XCTAssertFalse(news.isNew(utc(2026, 9, 23)))
        XCTAssertFalse(news.isNew(nil))

        let nextVisit = NewsStore(defaults: defaults, directory: folder, now: utc(2026, 9, 26))
        XCTAssertEqual(nextVisit.unseenCount, 0)
        XCTAssertFalse(nextVisit.isNew(utc(2026, 9, 25, 8)), "Seen last time")
    }

    @MainActor
    func testAFirstLaunchDoesntCallEverythingNew() throws {
        let defaults = makeDefaults()
        let news = NewsStore(defaults: defaults, directory: try makeNewsFolder(), now: utc(2026, 9, 25, 12))
        XCTAssertEqual(news.unseenCount, 0)
        XCTAssertEqual(defaults.double(forKey: NewsStore.Keys.seenAt), utc(2026, 9, 25, 12).timeIntervalSince1970, "Remembered, so the next launch counts from here")
        news.markSeen(now: utc(2026, 9, 25, 11))
        XCTAssertEqual(defaults.double(forKey: NewsStore.Keys.seenAt), utc(2026, 9, 25, 12).timeIntervalSince1970, "Never moves back")
    }

    /// One item, linked to `https://example.com/<title>`.
    private static func rss(_ title: String, _ date: String) -> Data {
        Data("<rss version=\"2.0\"><channel><item><title>\(title)</title><link>https://example.com/\(title)</link><pubDate>\(date)</pubDate></item></channel></rss>".utf8)
    }

    /// One model from a followed lab.
    private static func modelList(_ id: String, created: Date) -> Data {
        Data(#"{"data":[{"id":"\#(id)","name":"Anthropic: Test","created":\#(Int(created.timeIntervalSince1970))}]}"#.utf8)
    }

    @MainActor
    func testTurningNewsOnCountsFromTheFirstCheck() async throws {
        defer { unstubNetwork() }
        let models = Self.modelList("anthropic/claude-test", created: utc(2026, 9, 24))
        let feed = Self.rss("2.1.300", "Thu, 24 Sep 2026 12:00:00 GMT")
        stubNetwork { request in request.url == ModelFeed.url ? (200, models) : (200, feed) }
        // The Mac makes its News store at first launch, weeks before News is turned on.
        let news = NewsStore(defaults: makeDefaults(), directory: try makeFolder(), now: utc(2026, 9, 1))
        news.followedSources = ["claude-code"]
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: utc(2026, 9, 25, 12))
        XCTAssertEqual(news.models().count, 1)
        XCTAssertEqual(news.announcements.count, 1)
        XCTAssertEqual(news.unseenCount, 0, "What News finds when it's turned on isn't new")
        XCTAssertFalse(news.isNew(utc(2026, 9, 24)))

        let newer = Self.rss("2.1.301", "Sat, 26 Sep 2026 12:00:00 GMT")
        StubURLProtocol.handler = { request in request.url == ModelFeed.url ? (304, Data()) : (200, newer) }
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: utc(2026, 9, 26, 13))
        XCTAssertEqual(news.unseenAnnouncementCount, 1, "What later checks find is")
    }

    @MainActor
    func testAnItemDatedAheadIsSeenOnceNewsOpens() async throws {
        defer { unstubNetwork() }
        // Two days ahead: a wrong time zone, or a post scheduled early.
        let models = Self.modelList("anthropic/claude-ahead", created: utc(2026, 9, 27, 12))
        let feed = Self.rss("Scheduled", "Sun, 27 Sep 2026 12:00:00 GMT")
        stubNetwork { request in request.url == ModelFeed.url ? (200, models) : (200, feed) }
        let folder = try makeFolder()
        var checked = NewsCache()
        checked.modelsFetchedAt = utc(2026, 9, 24)
        checked.announcementsFetchedAt = utc(2026, 9, 24)
        checked.save(to: folder)
        let defaults = makeDefaults()
        defaults.set(utc(2026, 9, 24).timeIntervalSince1970, forKey: NewsStore.Keys.seenAt)
        let news = NewsStore(defaults: defaults, directory: folder)
        news.followedSources = ["claude-code"]
        let now = utc(2026, 9, 25, 12)
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: now)
        XCTAssertEqual(news.announcements.first?.published, now, "Dated when it arrived")
        XCTAssertEqual(news.models().first?.created, now)
        XCTAssertEqual(news.unseenCount, 2)

        news.markSeen(now: now.addingTimeInterval(3600))
        XCTAssertEqual(news.unseenCount, 0, "Opening News clears it")

        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: utc(2026, 9, 28))
        XCTAssertEqual(news.announcements.first?.published, now, "Once its date has passed, it keeps the one it arrived with")
        XCTAssertEqual(news.models().first?.created, now)
        XCTAssertEqual(news.unseenCount, 0, "…so it isn't new again")
    }

    @MainActor
    func testProblemsNameTheFeedsThatCouldntBeRead() async throws {
        defer { unstubNetwork() }
        let cursor = try XCTUnwrap(FeedSource.catalog.first { $0.id == "cursor" }).url
        let devin = try XCTUnwrap(FeedSource.catalog.first { $0.id == "devin" }).url
        // Each feed has one post of its own, titled by its host.
        let post: @Sendable (URLRequest) -> Data = { Self.rss($0.url?.host ?? "post", "Thu, 24 Sep 2026 12:00:00 GMT") }
        stubNetwork { request in
            if request.url == ModelFeed.url { return (503, Data()) }
            return request.url == cursor ? (200, Data("<rss><channel><item><title>Cut".utf8)) : (200, post(request))
        }
        let news = NewsStore(defaults: makeDefaults(), directory: try makeFolder(), now: utc(2026, 9, 25))
        news.followedSources = ["cursor", "devin", "zai"]
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: utc(2026, 9, 25, 12))
        XCTAssertEqual(news.modelProblem, "Couldn't read OpenRouter's model list.")
        XCTAssertEqual(news.announcementProblem, "Couldn't read Cursor.")
        XCTAssertEqual(Set(news.announcements.map(\.source)), ["Devin", "Z.ai"], "The others still read")

        StubURLProtocol.handler = { _ in (500, Data()) }
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: utc(2026, 9, 25, 13))
        XCTAssertEqual(news.announcementProblem, "Couldn't read the feeds.")
        XCTAssertEqual(Set(news.announcements.map(\.source)), ["Devin", "Z.ai"], "What was read stays")

        StubURLProtocol.handler = { request in
            if request.url == ModelFeed.url { return (200, Self.noModels) }
            return request.url == cursor || request.url == devin ? (404, Data()) : (200, post(request))
        }
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: utc(2026, 9, 25, 14))
        XCTAssertEqual(news.announcementProblem, "Couldn't read Cursor and Devin.")
        XCTAssertNil(news.modelProblem, "A good answer clears it")
    }

    @MainActor
    func testFeedsAddedSinceTheListWasSavedStartOn() {
        let defaults = makeDefaults()
        // Saved before MiniMax Code was in the catalog, with Cursor turned off.
        let earlier = FeedSource.catalog.map(\.id).filter { $0 != "minimax-code" }
        defaults.set(earlier.filter { $0 != "cursor" }, forKey: NewsStore.Keys.sources)
        defaults.set(earlier, forKey: NewsStore.Keys.knownSources)
        let news = NewsStore(defaults: defaults, directory: nil)
        XCTAssertTrue(news.followedSources.contains("minimax-code"), "A feed added since starts on")
        XCTAssertFalse(news.followedSources.contains("cursor"), "One turned off stays off")

        news.followedSources.remove("minimax-code")
        XCTAssertFalse(NewsStore(defaults: defaults, directory: nil).followedSources.contains("minimax-code"), "Turned off once offered, it stays off")
    }

    @MainActor
    func testLabsAddedToTheDefaultsSinceTheListWasSavedStartOn() {
        let defaults = makeDefaults()
        // Saved when the defaults didn't have DeepSeek yet, with OpenAI turned off.
        let earlier = ModelFeed.defaultVendors.subtracting(["deepseek"])
        defaults.set(earlier.subtracting(["openai"]).sorted(), forKey: NewsStore.Keys.vendors)
        defaults.set(earlier.sorted(), forKey: NewsStore.Keys.knownVendors)
        let news = NewsStore(defaults: defaults, directory: nil)
        XCTAssertTrue(news.followedVendors.contains("deepseek"), "A lab added to the defaults since starts on")
        XCTAssertFalse(news.followedVendors.contains("openai"), "One turned off stays off")

        let saved = makeDefaults()
        saved.set(["anthropic"], forKey: NewsStore.Keys.vendors)
        XCTAssertEqual(NewsStore(defaults: saved, directory: nil).followedVendors, Set(["anthropic"]).union(ModelFeed.defaultVendors.subtracting(NewsStore.firstDefaultVendors)), "A list saved by 2.0 had 2.0's defaults to choose from")
    }

    @MainActor
    func testAListSavedBeforeTheCatalogWasRememberedKeepsItsChoices() {
        let defaults = makeDefaults()
        defaults.set(["claude-code", "cursor"], forKey: NewsStore.Keys.sources)
        let news = NewsStore(defaults: defaults, directory: nil)
        let addedSince = Set(FeedSource.catalog.map(\.id)).subtracting(NewsStore.firstCatalog)
        XCTAssertEqual(news.followedSources, Set(["claude-code", "cursor"]).union(addedSince), "2.0 had offered every feed it knew")
    }
}

/// Like StubURLProtocol, with an ETag on every 200.
final class StubETagProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StubURLProtocol.requests.append(request)
        let (status, data) = StubURLProtocol.handler?(request) ?? (404, Data())
        let headers = status == 200 ? ["ETag": "\"v1\""] : [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
