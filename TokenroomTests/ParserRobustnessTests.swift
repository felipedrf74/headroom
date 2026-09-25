import XCTest
@testable import Tokenroom

/// Providers add fields without notice. Every parser that reads JSON must read the same thing
/// when unknown keys appear anywhere in a response.
final class ParserRobustnessTests: XCTestCase {
    private let now = Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 12))!

    private func fixture(_ name: String) -> Data {
        try! Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json"))
    }

    /// Parses `name` as is and with extra keys in every object, for several seeds, and expects
    /// the same result, or the same error, each time.
    private func assertIgnoresExtraKeys<Value: Equatable>(
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ parse: (Data) throws -> Value
    ) throws {
        let original = fixture(name)
        let expected = outcome(of: parse, original)
        for seed in UInt64(1)...5 {
            let grown = try ExtraKeys.added(to: original, seed: seed)
            XCTAssertTrue(String(decoding: grown, as: UTF8.self).contains(ExtraKeys.prefix), "\(name): nothing was added", file: file, line: line)
            XCTAssertEqual(outcome(of: parse, grown), expected, "\(name), seed \(seed)", file: file, line: line)
        }
    }

    private func outcome<Value>(of parse: (Data) throws -> Value, _ data: Data) -> Result<Value, ProviderError> {
        do {
            return .success(try parse(data))
        } catch let error as ProviderError {
            return .failure(error)
        } catch {
            return .failure(.parse)
        }
    }

    // MARK: Signed-in apps and CLIs

    func testClaude() throws {
        try assertIgnoresExtraKeys("claude-usage-full") { try ClaudeParser.snapshot(from: $0, fetchedAt: now) }
        try assertIgnoresExtraKeys("claude-usage") { try ClaudeParser.snapshot(from: $0, fetchedAt: now) }
    }

    func testOpenAICodex() throws {
        for name in ["openai-credits-banked", "openai-spend-control", "openai-secondary-weekly", "openai-weekly-primary"] {
            try assertIgnoresExtraKeys(name) { try OpenAIParser.snapshot(from: $0, fetchedAt: now) }
        }
        try assertIgnoresExtraKeys("openai-reset-credits") { try OpenAIParser.availableResetExpiries(from: $0, now: now) }
    }

    func testCursor() throws {
        try assertIgnoresExtraKeys("cursor-usage") { try CursorParser.snapshot(from: $0, fetchedAt: now) }
    }

    func testGrok() throws {
        try assertIgnoresExtraKeys("grok-credits") { try GrokParser.snapshot(from: $0, fetchedAt: now) }
        try assertIgnoresExtraKeys("grok-credits-zero") { try GrokParser.snapshot(from: $0, fetchedAt: now) }
        try assertIgnoresExtraKeys("grok-settings") { GrokParser.planLabel(fromSettings: $0) }
    }

    func testGrokBot() throws {
        try assertIgnoresExtraKeys("grok-bot-usage") { try GrokBotParser.snapshot(from: $0, fetchedAt: now) }
    }

    func testCopilot() throws {
        for name in ["copilot-user-pro", "copilot-user-free", "copilot-user-legacy"] {
            try assertIgnoresExtraKeys(name) { try CopilotParser.snapshot(from: $0, fetchedAt: now) }
        }
        try assertIgnoresExtraKeys("copilot-ai-credit-usage") { try CopilotBilling.used(from: $0) }
    }

    func testDevin() throws {
        try assertIgnoresExtraKeys("devin-user-status") { try DevinParser.snapshot(from: $0, fetchedAt: now) }
        try assertIgnoresExtraKeys("devin-user-status-exhausted") { try DevinParser.snapshot(from: $0, fetchedAt: now) }
    }

    func testAntigravity() throws {
        try assertIgnoresExtraKeys("agy-usage") { try AntigravityParser.snapshot(from: $0, fetchedAt: now) }
        try assertIgnoresExtraKeys("antigravity-remote") { try AntigravityParser.snapshot(from: $0, fetchedAt: now) }
    }

    // MARK: Coding plans

    func testZai() throws {
        for name in ["zai-quota", "zai-idle-session", "zai-no-plan"] {
            try assertIgnoresExtraKeys(name) { try ZaiParser.snapshot(from: $0, fetchedAt: now) }
        }
    }

    func testKimi() throws {
        try assertIgnoresExtraKeys("kimi-usages") { try KimiCodeParser.snapshot(from: $0, fetchedAt: now) }
        try assertIgnoresExtraKeys("kimi-usages-legacy") { try KimiCodeParser.snapshot(from: $0, fetchedAt: now) }
    }

    func testMiniMax() throws {
        try assertIgnoresExtraKeys("minimax-token-plan") { try MiniMaxParser.snapshot(from: $0, fetchedAt: now) }
        try assertIgnoresExtraKeys("minimax-coding-plan") { try MiniMaxParser.snapshot(from: $0, legacy: true, fetchedAt: now) }
        try assertIgnoresExtraKeys("minimax-invalid-key") { try MiniMaxParser.snapshot(from: $0, fetchedAt: now) }
    }

    func testOpenCodeGo() throws {
        try assertIgnoresExtraKeys("opencode-go-usage") { try OpenCodeGoParser.snapshot(from: $0, fetchedAt: now) }
    }

    // MARK: API keys

    func testOpenRouter() throws {
        try assertIgnoresExtraKeys("openrouter-limited") { try OpenRouterParser.snapshot(from: $0, fetchedAt: now) }
        try assertIgnoresExtraKeys("openrouter-unlimited") { try OpenRouterParser.snapshot(from: $0, fetchedAt: now) }
    }

    func testDeepSeek() throws {
        try assertIgnoresExtraKeys("deepseek-balance") { try DeepSeekParser.snapshot(from: $0, fetchedAt: now) }
    }

    func testMoonshot() throws {
        try assertIgnoresExtraKeys("moonshot-balance") { try MoonshotParser.snapshot(from: $0, region: "Global", fetchedAt: now) }
        try assertIgnoresExtraKeys("moonshot-balance") { try MoonshotParser.snapshot(from: $0, region: "China", fetchedAt: now) }
    }

    func testVercel() throws {
        try assertIgnoresExtraKeys("vercel-credits") { try VercelGatewayParser.snapshot(from: $0, fetchedAt: now) }
    }

    // MARK: Organization spend

    func testOpenAICosts() throws {
        for name in ["openai-costs-page1", "openai-costs-page2"] {
            try assertIgnoresExtraKeys(name) { data in
                let page = try OpenAICostsParser.page(from: data)
                return Pair(page.total, page.nextPage)
            }
        }
    }

    func testAnthropicCosts() throws {
        try assertIgnoresExtraKeys("anthropic-cost-report") { data in
            let page = try AnthropicCostParser.page(from: data)
            return Pair(page.total, page.nextPage)
        }
    }

    func testXAI() throws {
        try assertIgnoresExtraKeys("xai-validation") { data in
            Pair(try XAIBillingParser.teamID(fromValidation: data), XAIBillingParser.canWrite(fromValidation: data))
        }
        try assertIgnoresExtraKeys("xai-invoice-preview") { data in
            let invoice = try XAIBillingParser.invoice(from: data)
            return Pair(invoice.spend, invoice.limit)
        }
        try assertIgnoresExtraKeys("xai-prepaid-balance") { try XAIBillingParser.prepaidCredits(from: $0) }
    }

    // MARK: The injector itself

    func testExtraKeysAreDeterministicAndReachNestedObjects() throws {
        let original = fixture("claude-usage")
        XCTAssertEqual(try ExtraKeys.added(to: original, seed: 7), try ExtraKeys.added(to: original, seed: 7))
        XCTAssertNotEqual(try ExtraKeys.added(to: original, seed: 7), try ExtraKeys.added(to: original, seed: 8))
        let grown = try XCTUnwrap(JSONSerialization.jsonObject(with: ExtraKeys.added(to: original, seed: 7)) as? [String: Any])
        XCTAssertTrue(grown.keys.contains { $0.hasPrefix(ExtraKeys.prefix) }, "At the top level")
        let weekly = try XCTUnwrap(grown["seven_day"] as? [String: Any])
        XCTAssertTrue(weekly.keys.contains { $0.hasPrefix(ExtraKeys.prefix) }, "Inside nested objects")
    }
}

/// Two values compared together, for parsers that return tuples or plain structs.
private struct Pair<First: Equatable, Second: Equatable>: Equatable {
    var first: First
    var second: Second

    init(_ first: First, _ second: Second) {
        self.first = first
        self.second = second
    }
}

/// Adds keys no provider sends to every JSON object, at every depth. Arrays keep their elements
/// (an extra element would be a different response), but objects inside them grow too.
enum ExtraKeys {
    static let prefix = "tokenroomExtra"

    static func added(to data: Data, seed: UInt64) throws -> Data {
        var generator = SeededGenerator(seed: seed)
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let grown = grow(object, using: &generator)
        return try JSONSerialization.data(withJSONObject: grown, options: [.sortedKeys, .fragmentsAllowed])
    }

    private static func grow(_ value: Any, using generator: inout SeededGenerator) -> Any {
        if let object = value as? [String: Any] {
            var grown: [String: Any] = [:]
            for key in object.keys.sorted() {
                grown[key] = grow(object[key]!, using: &generator)
            }
            for _ in 0..<Int.random(in: 1...3, using: &generator) {
                grown["\(prefix)\(Int.random(in: 0..<1_000_000, using: &generator))"] = randomValue(depth: 0, using: &generator)
            }
            return grown
        }
        if let array = value as? [Any] {
            var grown: [Any] = []
            for element in array {
                grown.append(grow(element, using: &generator))
            }
            return grown
        }
        return value
    }

    private static func randomValue(depth: Int, using generator: inout SeededGenerator) -> Any {
        switch Int.random(in: 0..<7, using: &generator) {
        case 0:
            return Int.random(in: -1_000...2_000_000_000, using: &generator)
        case 1:
            return Double.random(in: -1...1, using: &generator)
        case 2:
            return "extra-\(Int.random(in: 0..<10_000, using: &generator))"
        case 3:
            return Bool.random(using: &generator)
        case 4:
            return NSNull()
        case 5 where depth < 2:
            return ["value": randomValue(depth: depth + 1, using: &generator), "list": [1, "two", NSNull()]] as [String: Any]
        default:
            return [Int.random(in: 0...9, using: &generator), "x"] as [Any]
        }
    }
}

/// SplitMix64: the same numbers for the same seed, on every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
