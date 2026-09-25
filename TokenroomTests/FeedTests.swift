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

    func testLimitsItemsAndSize() {
        let items = (0..<40).map { "<item><title>Post \($0)</title><link>https://example.com/\($0)</link></item>" }.joined()
        let rss = Data("<rss version=\"2.0\"><channel>\(items)</channel></rss>".utf8)
        XCTAssertEqual(FeedParser.items(from: rss, source: claudeCode).count, FeedParser.itemLimit)
        XCTAssertTrue(FeedParser.items(from: Data(count: FeedParser.sizeLimit + 1), source: claudeCode).isEmpty)
    }

    func testCatalogIsHTTPSAndUnique() {
        XCTAssertEqual(Set(FeedSource.catalog.map(\.id)).count, FeedSource.catalog.count)
        XCTAssertTrue(FeedSource.catalog.allSatisfy { $0.url.scheme == "https" })
    }
}
