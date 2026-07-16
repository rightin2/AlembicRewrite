import XCTest
@testable import AlembicRewrite

/// Tests for the app-preferences store (the ten consensus settings, doc
/// section 3): default values, disk round-trip, tolerant decoding, and the pure
/// enforcement helpers (dash strip, spend cap, large-selection guard, history
/// retention) the integrator wires into the coordinator next phase.
@MainActor
final class AppSettingsTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlembicSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Defaults

    func testDefaultsMatchSpec() {
        let d = AppPrefs.default
        XCTAssertEqual(d.globalHotkey, HotkeyManager.defaultGlobalHotkey) // Cmd+Shift+E
        XCTAssertTrue(d.enforceHouseStyle)
        XCTAssertTrue(d.stripDashes)
        XCTAssertFalse(d.spendCapEnabled)
        XCTAssertEqual(d.monthlyCapUSD, 25.0, accuracy: 1e-9)
        XCTAssertEqual(d.spendWarnFraction, 0.8, accuracy: 1e-9)
        XCTAssertEqual(d.historyMode, .capped)
        XCTAssertEqual(d.historyRetentionDays, 30)
        XCTAssertFalse(d.clearHistoryOnQuit)
        XCTAssertTrue(d.largeSelectionGuardEnabled)
        XCTAssertEqual(d.largeSelectionThreshold, 2000)
        XCTAssertTrue(d.undoEnabled)
        XCTAssertEqual(d.undoWindowSeconds, 30)
        XCTAssertEqual(d.defaultProvider, .anthropic)
        XCTAssertEqual(d.defaultModel, "claude-haiku-4-5")
        XCTAssertEqual(d.defaultTemperature, 0.7, accuracy: 1e-9)
        XCTAssertFalse(d.defaultAlwaysReview)
    }

    func testFreshStoreStartsFromDefaults() {
        let s = AppSettings(directory: tmpDir)
        XCTAssertEqual(s.prefs, AppPrefs.default)
    }

    // MARK: - Round-trip

    func testMutationPersistsAcrossInstances() {
        let s1 = AppSettings(directory: tmpDir)
        s1.prefs.monthlyCapUSD = 60
        s1.prefs.spendCapEnabled = true
        s1.prefs.historyMode = .days
        s1.prefs.historyRetentionDays = 14
        s1.prefs.defaultModel = "gpt-4o"
        s1.prefs.defaultProvider = .openai
        s1.prefs.houseStyleInstruction = "Keep it terse."

        let s2 = AppSettings(directory: tmpDir)
        XCTAssertTrue(s2.prefs.spendCapEnabled)
        XCTAssertEqual(s2.prefs.monthlyCapUSD, 60, accuracy: 1e-9)
        XCTAssertEqual(s2.prefs.historyMode, .days)
        XCTAssertEqual(s2.prefs.historyRetentionDays, 14)
        XCTAssertEqual(s2.prefs.defaultModel, "gpt-4o")
        XCTAssertEqual(s2.prefs.defaultProvider, .openai)
        XCTAssertEqual(s2.prefs.houseStyleInstruction, "Keep it terse.")
    }

    func testGlobalHotkeyRoundTrips() {
        let s1 = AppSettings(directory: tmpDir)
        let custom = Hotkey(keyCode: 0x11, modifiers: HotkeyCarbon.command | HotkeyCarbon.option) // Cmd+Opt+T
        s1.prefs.globalHotkey = custom
        let s2 = AppSettings(directory: tmpDir)
        XCTAssertEqual(s2.prefs.globalHotkey, custom)
    }

    func testResetToDefaults() {
        let s = AppSettings(directory: tmpDir)
        s.prefs.spendCapEnabled = true
        s.prefs.monthlyCapUSD = 500
        s.resetToDefaults()
        XCTAssertEqual(s.prefs, AppPrefs.default)
        // Persisted too.
        XCTAssertEqual(AppSettings(directory: tmpDir).prefs, AppPrefs.default)
    }

    // MARK: - Tolerant decoding

    func testPartialJSONDecodesWithDefaults() throws {
        // A settings.json written by an older build that only knew two keys.
        let json = """
        { "monthlyCapUSD": 99, "spendCapEnabled": true }
        """
        let prefs = try JSONFile.makeDecoder().decode(AppPrefs.self, from: Data(json.utf8))
        XCTAssertTrue(prefs.spendCapEnabled)
        XCTAssertEqual(prefs.monthlyCapUSD, 99, accuracy: 1e-9)
        // Everything absent falls back to defaults.
        XCTAssertEqual(prefs.historyMode, AppPrefs.default.historyMode)
        XCTAssertEqual(prefs.globalHotkey, AppPrefs.default.globalHotkey)
        XCTAssertEqual(prefs.defaultModel, AppPrefs.default.defaultModel)
    }

    // MARK: - Dash strip (3.2)

    func testDashStripReplacesEmAndEnDashes() {
        XCTAssertEqual(AppSettings.stripDisallowedDashes("a \u{2014} b"), "a, b")   // em, spaced
        XCTAssertEqual(AppSettings.stripDisallowedDashes("a \u{2013} b"), "a, b")   // en, spaced
        XCTAssertEqual(AppSettings.stripDisallowedDashes("word\u{2014}word"), "word-word") // bare em
        XCTAssertEqual(AppSettings.stripDisallowedDashes("co\u{2011}op"), "co-op")  // non-breaking hyphen
        // Plain hyphens are left untouched.
        XCTAssertEqual(AppSettings.stripDisallowedDashes("co-op"), "co-op")
    }

    func testApplyDashStripHonoursToggle() {
        let s = AppSettings(directory: tmpDir)
        s.prefs.stripDashes = false
        XCTAssertEqual(s.applyDashStrip("a \u{2014} b"), "a \u{2014} b")
        s.prefs.stripDashes = true
        XCTAssertEqual(s.applyDashStrip("a \u{2014} b"), "a, b")
    }

    func testHouseStyleFragmentGating() {
        let s = AppSettings(directory: tmpDir)
        s.prefs.enforceHouseStyle = true
        XCTAssertNotNil(s.houseStylePromptFragment())
        s.prefs.enforceHouseStyle = false
        XCTAssertNil(s.houseStylePromptFragment())
    }

    // MARK: - Spend cap (3.3)

    func testSpendCapDisabledIsAlwaysOk() {
        let s = AppSettings(directory: tmpDir)
        s.prefs.spendCapEnabled = false
        XCTAssertEqual(s.evaluateSpendCap(monthToDateUSD: 999), .ok)
    }

    func testSpendCapWarnAndBlock() {
        let s = AppSettings(directory: tmpDir)
        s.prefs.spendCapEnabled = true
        s.prefs.monthlyCapUSD = 100
        s.prefs.spendWarnFraction = 0.8
        XCTAssertEqual(s.evaluateSpendCap(monthToDateUSD: 50), .ok)
        if case .warn(let f) = s.evaluateSpendCap(monthToDateUSD: 85) {
            XCTAssertEqual(f, 0.85, accuracy: 1e-9)
        } else {
            XCTFail("expected warn")
        }
        if case .blocked(let cap) = s.evaluateSpendCap(monthToDateUSD: 120) {
            XCTAssertEqual(cap, 100, accuracy: 1e-9)
        } else {
            XCTFail("expected blocked")
        }
    }

    // MARK: - Large-selection guard (3.5)

    func testLargeSelectionGuard() {
        let s = AppSettings(directory: tmpDir)
        s.prefs.largeSelectionGuardEnabled = true
        s.prefs.largeSelectionThreshold = 1000
        XCTAssertFalse(s.exceedsLargeSelection(999))
        XCTAssertFalse(s.exceedsLargeSelection(1000))
        XCTAssertTrue(s.exceedsLargeSelection(1001))
        s.prefs.largeSelectionGuardEnabled = false
        XCTAssertFalse(s.exceedsLargeSelection(100_000))
    }

    // MARK: - History retention (3.4)

    func testHistoryShouldLog() {
        let s = AppSettings(directory: tmpDir)
        s.prefs.historyMode = .off
        XCTAssertFalse(s.historyShouldLog())
        s.prefs.historyMode = .capped
        XCTAssertTrue(s.historyShouldLog())
    }

    func testHistoryTrimCutoff() throws {
        let s = AppSettings(directory: tmpDir)
        s.prefs.historyMode = .capped
        XCTAssertNil(s.historyTrimCutoff())
        s.prefs.historyMode = .off
        XCTAssertNil(s.historyTrimCutoff())
        s.prefs.historyMode = .days
        s.prefs.historyRetentionDays = 7
        let cutoff = try XCTUnwrap(s.historyTrimCutoff())
        // Roughly 7 days ago.
        let expected = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        XCTAssertEqual(cutoff.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 5)
    }

    // MARK: - Known models registry (3.6)

    func testKnownModelsAreAllPriced() {
        for m in KnownModels.all {
            XCTAssertTrue(KnownModels.isPriced(m.id), "\(m.id) should be priced")
        }
        XCTAssertFalse(KnownModels.isPriced("claude-sonnet-4.6-typo"))
    }

    func testKnownModelsFilterByProvider() {
        XCTAssertTrue(KnownModels.forProvider(.anthropic).allSatisfy { $0.provider == .anthropic })
        XCTAssertTrue(KnownModels.forProvider(.openai).allSatisfy { $0.provider == .openai })
    }

    // MARK: - Per-style max tokens (3.8)

    func testStyleMaxTokensDefaultAndRoundTrip() throws {
        let style = Style(name: "T", promptTemplate: "{{selection}}", provider: .anthropic,
                          model: "claude-haiku-4-5", temperature: 0.3, sortOrder: 0)
        XCTAssertEqual(style.maxTokens, Style.defaultMaxTokens)
        var s2 = style
        s2.maxTokens = 256
        let data = try JSONFile.makeEncoder().encode(s2)
        let back = try JSONFile.makeDecoder().decode(Style.self, from: data)
        XCTAssertEqual(back.maxTokens, 256)
    }

    func testStyleDecodesMissingMaxTokensAsDefault() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "name": "Legacy",
          "promptTemplate": "{{selection}}",
          "provider": "anthropic",
          "model": "claude-haiku-4-5",
          "temperature": 0.3,
          "sortOrder": 0,
          "createdAt": "2026-07-16T00:00:00Z"
        }
        """
        let style = try JSONFile.makeDecoder().decode(Style.self, from: Data(json.utf8))
        XCTAssertEqual(style.maxTokens, Style.defaultMaxTokens)
    }
}
