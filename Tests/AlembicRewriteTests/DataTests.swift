import XCTest
@testable import AlembicRewrite

/// Data-layer tests: StyleStore CRUD + seeding, HistoryStore cap, CostMeter
/// arithmetic, PriceTable lookup, and {{selection}} template substitution.
final class DataTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlembicRewriteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Scaffold sanity (folded in from PlaceholderTests)

    func testScaffoldCompiles() {
        let style = Style(
            name: "Effective prompt rewrite",
            promptTemplate: "Rewrite this prompt: {{selection}}",
            provider: .anthropic,
            model: "claude-sonnet-4-6",
            temperature: 0.7,
            sortOrder: 0
        )
        XCTAssertEqual(style.provider, .anthropic)
        XCTAssertTrue(style.promptTemplate.contains("{{selection}}"))
    }

    // MARK: - StyleStore CRUD

    func testStyleStoreStartsEmpty() throws {
        let store = StyleStore(directory: tmpDir)
        XCTAssertTrue(try store.all().isEmpty)
    }

    func testSaveInsertAndUpdate() throws {
        let store = StyleStore(directory: tmpDir)
        var style = Style(
            name: "Terse",
            promptTemplate: "Shorten: {{selection}}",
            provider: .openai,
            model: "gpt-4o-mini",
            temperature: 0.2,
            sortOrder: 0
        )
        try store.save(style)
        XCTAssertEqual(try store.all().count, 1)

        // Update in place (same id) does not duplicate.
        style.name = "Very Terse"
        try store.save(style)
        let all = try store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "Very Terse")
    }

    func testDelete() throws {
        let store = StyleStore(directory: tmpDir)
        let a = Style(name: "A", promptTemplate: "{{selection}}", provider: .anthropic, model: "claude-haiku-4-5", temperature: 0, sortOrder: 0)
        let b = Style(name: "B", promptTemplate: "{{selection}}", provider: .anthropic, model: "claude-haiku-4-5", temperature: 0, sortOrder: 1)
        try store.save(a)
        try store.save(b)
        try store.delete(id: a.id)
        let all = try store.all()
        XCTAssertEqual(all.map(\.name), ["B"])
    }

    func testAllReturnsSortedBySortOrder() throws {
        let store = StyleStore(directory: tmpDir)
        let a = Style(name: "A", promptTemplate: "{{selection}}", provider: .anthropic, model: "claude-haiku-4-5", temperature: 0, sortOrder: 5)
        let b = Style(name: "B", promptTemplate: "{{selection}}", provider: .anthropic, model: "claude-haiku-4-5", temperature: 0, sortOrder: 1)
        try store.save(a)
        try store.save(b)
        XCTAssertEqual(try store.all().map(\.name), ["B", "A"])
    }

    func testReorderRenumbersSortOrder() throws {
        let store = StyleStore(directory: tmpDir)
        let a = Style(name: "A", promptTemplate: "{{selection}}", provider: .anthropic, model: "claude-haiku-4-5", temperature: 0, sortOrder: 0)
        let b = Style(name: "B", promptTemplate: "{{selection}}", provider: .anthropic, model: "claude-haiku-4-5", temperature: 0, sortOrder: 1)
        try store.save(a)
        try store.save(b)
        try store.reorder([b, a]) // reverse
        let all = try store.all()
        XCTAssertEqual(all.map(\.name), ["B", "A"])
        XCTAssertEqual(all.map(\.sortOrder), [0, 1])
    }

    func testSeedDefaultsIfEmpty() throws {
        let store = StyleStore(directory: tmpDir)
        try store.seedDefaultsIfEmpty()
        let all = try store.all()
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.first?.name, "Effective prompt rewrite")
        XCTAssertEqual(all.first?.sortOrder, 0)
        // Every default carries the substitution placeholder.
        XCTAssertTrue(all.allSatisfy { $0.promptTemplate.contains("{{selection}}") })
    }

    func testSeedDefaultsIsNoOpWhenPopulated() throws {
        let store = StyleStore(directory: tmpDir)
        let only = Style(name: "Only", promptTemplate: "{{selection}}", provider: .openai, model: "gpt-4o", temperature: 0, sortOrder: 0)
        try store.save(only)
        try store.seedDefaultsIfEmpty()
        XCTAssertEqual(try store.all().map(\.name), ["Only"])
    }

    func testStylePersistsAcrossInstances() throws {
        let s1 = StyleStore(directory: tmpDir)
        try s1.seedDefaultsIfEmpty()
        let s2 = StyleStore(directory: tmpDir)
        XCTAssertEqual(try s2.all().count, 3)
    }

    // MARK: - Template substitution

    func testTemplateSubstitution() throws {
        let store = StyleStore(directory: tmpDir)
        try store.seedDefaultsIfEmpty()
        let template = try XCTUnwrap(try store.all().first).promptTemplate
        let selection = "make me a haiku about frogs"
        let rendered = template.replacingOccurrences(of: "{{selection}}", with: selection)
        XCTAssertFalse(rendered.contains("{{selection}}"))
        XCTAssertTrue(rendered.contains(selection))
    }

    func testCoordinatorComposeSubstitutesSelection() {
        let rendered = RewriteCoordinator.compose(
            template: "Rewrite this: {{selection}}",
            selection: "hello world"
        )
        XCTAssertEqual(rendered, "Rewrite this: hello world")
        XCTAssertFalse(rendered.contains("{{selection}}"))
    }

    func testCoordinatorComposeReplacesEveryPlaceholder() {
        let rendered = RewriteCoordinator.compose(
            template: "{{selection}} / {{selection}}",
            selection: "X"
        )
        XCTAssertEqual(rendered, "X / X")
    }

    func testCoordinatorComposeNoPlaceholderIsUnchanged() {
        let rendered = RewriteCoordinator.compose(
            template: "no placeholder here",
            selection: "ignored"
        )
        XCTAssertEqual(rendered, "no placeholder here")
    }

    // MARK: - HistoryStore

    func testHistoryAddAndOrder() throws {
        let store = HistoryStore(directory: tmpDir)
        let older = makeEntry(result: "old", at: Date(timeIntervalSince1970: 1000))
        let newer = makeEntry(result: "new", at: Date(timeIntervalSince1970: 2000))
        try store.add(older)
        try store.add(newer)
        let recent = try store.recent()
        XCTAssertEqual(recent.map(\.result), ["new", "old"]) // most-recent-first
    }

    func testHistoryClear() throws {
        let store = HistoryStore(directory: tmpDir)
        try store.add(makeEntry(result: "x", at: Date()))
        try store.clear()
        XCTAssertTrue(try store.recent().isEmpty)
    }

    func testHistoryCapsAt200() throws {
        let store = HistoryStore(directory: tmpDir)
        for i in 0..<250 {
            try store.add(makeEntry(result: "\(i)", at: Date(timeIntervalSince1970: Double(i))))
        }
        let recent = try store.recent()
        XCTAssertEqual(recent.count, 200)
        // Newest kept, oldest trimmed.
        XCTAssertEqual(recent.first?.result, "249")
        XCTAssertEqual(recent.last?.result, "50")
    }

    // MARK: - PriceTable

    func testPriceLookupKnownModels() {
        XCTAssertEqual(PriceTable.price(for: "claude-haiku-4-5"), ModelPrice(inputPerMTok: 1.0, outputPerMTok: 5.0))
        XCTAssertEqual(PriceTable.price(for: "claude-sonnet-4-6"), ModelPrice(inputPerMTok: 3.0, outputPerMTok: 15.0))
        XCTAssertEqual(PriceTable.price(for: "claude-opus-4-8"), ModelPrice(inputPerMTok: 5.0, outputPerMTok: 25.0))
        XCTAssertEqual(PriceTable.price(for: "gpt-4o"), ModelPrice(inputPerMTok: 2.5, outputPerMTok: 10.0))
        XCTAssertEqual(PriceTable.price(for: "gpt-4o-mini"), ModelPrice(inputPerMTok: 0.15, outputPerMTok: 0.6))
    }

    func testPriceLookupUnknownModelIsNil() {
        XCTAssertNil(PriceTable.price(for: "not-a-real-model"))
    }

    func testPriceTableCostArithmetic() {
        // 1M input @ $3 + 1M output @ $15 = $18 for sonnet.
        let cost = PriceTable.cost(model: "claude-sonnet-4-6", inputTokens: 1_000_000, outputTokens: 1_000_000)
        XCTAssertEqual(cost, 18.0, accuracy: 1e-9)
        // Unknown model is zero-cost.
        XCTAssertEqual(PriceTable.cost(model: "unknown", inputTokens: 1_000_000, outputTokens: 1_000_000), 0.0)
    }

    // MARK: - CostMeter

    func testCostMeterAccumulatesTokensAndCost() throws {
        let meter = CostMeter(directory: tmpDir)
        // 500k in / 250k out on haiku: 0.5*$1 + 0.25*$5 = $1.75
        try meter.record(UsageRecord(provider: .anthropic, model: "claude-haiku-4-5", inputTokens: 500_000, outputTokens: 250_000))
        // 200k in / 100k out on gpt-4o: 0.2*$2.5 + 0.1*$10 = $1.5
        try meter.record(UsageRecord(provider: .openai, model: "gpt-4o", inputTokens: 200_000, outputTokens: 100_000))

        XCTAssertEqual(meter.totalTokens(), 500_000 + 250_000 + 200_000 + 100_000)
        XCTAssertEqual(meter.totalCostUSD(), 1.75 + 1.5, accuracy: 1e-9)
    }

    func testCostMeterAggregatesSameModel() throws {
        let meter = CostMeter(directory: tmpDir)
        try meter.record(UsageRecord(provider: .anthropic, model: "claude-opus-4-8", inputTokens: 100_000, outputTokens: 0))
        try meter.record(UsageRecord(provider: .anthropic, model: "claude-opus-4-8", inputTokens: 0, outputTokens: 100_000))
        // 0.1*$5 + 0.1*$25 = 0.5 + 2.5 = $3.00
        XCTAssertEqual(meter.totalCostUSD(), 3.0, accuracy: 1e-9)
        XCTAssertEqual(meter.totalTokens(), 200_000)
    }

    func testCostMeterReset() throws {
        let meter = CostMeter(directory: tmpDir)
        try meter.record(UsageRecord(provider: .openai, model: "gpt-4o-mini", inputTokens: 1_000_000, outputTokens: 1_000_000))
        XCTAssertGreaterThan(meter.totalTokens(), 0)
        try meter.reset()
        XCTAssertEqual(meter.totalTokens(), 0)
        XCTAssertEqual(meter.totalCostUSD(), 0.0)
    }

    func testCostMeterPersistsAcrossInstances() throws {
        let m1 = CostMeter(directory: tmpDir)
        try m1.record(UsageRecord(provider: .openai, model: "gpt-4o", inputTokens: 1_000_000, outputTokens: 0))
        let m2 = CostMeter(directory: tmpDir)
        XCTAssertEqual(m2.totalTokens(), 1_000_000)
        XCTAssertEqual(m2.totalCostUSD(), 2.5, accuracy: 1e-9)
    }

    // MARK: - Helpers

    private func makeEntry(result: String, at date: Date) -> HistoryEntry {
        HistoryEntry(
            original: "orig",
            result: result,
            styleName: "Test",
            provider: .anthropic,
            model: "claude-haiku-4-5",
            timestamp: date,
            inputTokens: 10,
            outputTokens: 20
        )
    }
}
