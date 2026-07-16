//
//  AppSettings.swift
//  AlembicRewrite
//
//  The app-preferences store: the ten consensus settings from design doc
//  section 3, held as one observable, JSON-file-backed store (same "everything
//  is a file" pattern as StyleStore / HistoryStore / CostMeter). Persists to
//  ~/Library/Application Support/AlembicRewrite/settings.json.
//
//  Each setting that needs enforcement OUTSIDE this file (spend cap,
//  large-selection guard, undo window, history retention, Australian-English
//  strip, per-style max tokens) exposes a clean pure API here and marks the
//  call site the integrator must wire with an `// INTEGRATION(<setting>):`
//  comment. The data and the Settings UI live here; the coordinator/store
//  hookups are the integrator's next phase.
//
//  See docs/design/2026-07-16-ui-audit-redesign.md section 3.
//

import Foundation
import SwiftUI

// MARK: - History retention mode (setting 3.4)

/// How rewrites are logged to the History store.
///  - off:     never log (`add` becomes a no-op).
///  - session: keep only entries from the current app run (cleared on quit).
///  - days:    keep entries newer than `historyRetentionDays`.
///  - capped:  the existing 200-entry count cap, no date trim (default).
public enum HistoryRetentionMode: String, Codable, CaseIterable, Sendable {
    case off, session, days, capped

    public var label: String {
        switch self {
        case .off:     return "Do not log"
        case .session: return "This session only"
        case .days:    return "Keep for N days"
        case .capped:  return "Keep recent 200"
        }
    }
}

// MARK: - Spend-cap evaluation (setting 3.3)

/// The result of checking month-to-date spend against the configured cap.
///  - ok:      under the warn threshold, proceed.
///  - warn:    at or over the warn threshold but under the cap; flag in the
///             HUD/panel but proceed.
///  - blocked: at or over 100 percent; new rewrites are refused until the cap
///             is raised or the month rolls over.
public enum SpendCapState: Equatable, Sendable {
    case ok
    case warn(fractionUsed: Double)
    case blocked(capUSD: Double)
}

// MARK: - Known-models registry (setting 3.6)

/// One entry in the picker of price-known models that replaces the free-text
/// model field, closing the silent-$0 mispricing (B8). "Other..." in the editor
/// keeps a text escape hatch for ids not listed here.
public struct KnownModel: Identifiable, Hashable, Sendable {
    public var id: String          // model identifier string
    public var displayName: String
    public var provider: Provider
}

/// The price-known models, grouped by provider. Every id here resolves in
/// `PriceTable`, so selecting one can never meter at $0.
public enum KnownModels {
    public static let all: [KnownModel] = [
        KnownModel(id: "claude-haiku-4-5",  displayName: "Claude Haiku 4.5",  provider: .anthropic),
        KnownModel(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6", provider: .anthropic),
        KnownModel(id: "claude-opus-4-8",   displayName: "Claude Opus 4.8",   provider: .anthropic),
        KnownModel(id: "gpt-4o",            displayName: "GPT-4o",            provider: .openai),
        KnownModel(id: "gpt-4o-mini",       displayName: "GPT-4o mini",       provider: .openai),
    ]

    public static func forProvider(_ provider: Provider) -> [KnownModel] {
        all.filter { $0.provider == provider }
    }

    /// True when the model id has a price entry, i.e. it will not meter at $0.
    public static func isPriced(_ model: String) -> Bool {
        PriceTable.price(for: model) != nil
    }
}

// MARK: - Persisted snapshot

/// The full, Codable snapshot of every app preference. Decoding is tolerant:
/// any absent key (an older settings.json, or a field added in a later release)
/// falls back to its default, so the file survives version drift both ways.
public struct AppPrefs: Codable, Equatable, Sendable {

    // 3.1 Editable global palette hotkey.
    public var globalHotkey: Hotkey

    // 3.2 Australian English + no em/en dash enforcement.
    public var enforceHouseStyle: Bool
    public var houseStyleInstruction: String
    public var stripDashes: Bool

    // 3.3 Monthly spend cap.
    public var spendCapEnabled: Bool
    public var monthlyCapUSD: Double
    public var spendWarnFraction: Double

    // 3.4 History retention and purge.
    public var historyMode: HistoryRetentionMode
    public var historyRetentionDays: Int
    public var clearHistoryOnQuit: Bool

    // 3.5 Large-selection guard.
    public var largeSelectionGuardEnabled: Bool
    public var largeSelectionThreshold: Int

    // 3.7 Undo / restore original after paste.
    public var undoEnabled: Bool
    public var undoWindowSeconds: Int

    // 3.10 App-level defaults for new styles.
    public var defaultProvider: Provider
    public var defaultModel: String
    public var defaultTemperature: Double
    public var defaultAlwaysReview: Bool

    /// The standing house-style rule text (Australian English + no em/en dashes)
    /// appended to every prompt when enforcement is on. Editable in General.
    public static let defaultHouseStyleInstruction =
        "Write in Australian English spelling and idiom. Do not use em dashes or en dashes anywhere in the output; use commas, semicolons, or separate sentences instead. Hyphens in compound words are fine."

    public static let `default` = AppPrefs(
        globalHotkey: HotkeyManager.defaultGlobalHotkey,
        enforceHouseStyle: true,
        houseStyleInstruction: defaultHouseStyleInstruction,
        stripDashes: true,
        spendCapEnabled: false,
        monthlyCapUSD: 25.0,
        spendWarnFraction: 0.8,
        historyMode: .capped,
        historyRetentionDays: 30,
        clearHistoryOnQuit: false,
        largeSelectionGuardEnabled: true,
        largeSelectionThreshold: 2000,
        undoEnabled: true,
        undoWindowSeconds: 30,
        defaultProvider: .anthropic,
        defaultModel: "claude-haiku-4-5",
        defaultTemperature: 0.7,
        defaultAlwaysReview: false
    )

    private enum CodingKeys: String, CodingKey {
        case globalHotkey, enforceHouseStyle, houseStyleInstruction, stripDashes
        case spendCapEnabled, monthlyCapUSD, spendWarnFraction
        case historyMode, historyRetentionDays, clearHistoryOnQuit
        case largeSelectionGuardEnabled, largeSelectionThreshold
        case undoEnabled, undoWindowSeconds
        case defaultProvider, defaultModel, defaultTemperature, defaultAlwaysReview
    }

    public init(
        globalHotkey: Hotkey,
        enforceHouseStyle: Bool,
        houseStyleInstruction: String,
        stripDashes: Bool,
        spendCapEnabled: Bool,
        monthlyCapUSD: Double,
        spendWarnFraction: Double,
        historyMode: HistoryRetentionMode,
        historyRetentionDays: Int,
        clearHistoryOnQuit: Bool,
        largeSelectionGuardEnabled: Bool,
        largeSelectionThreshold: Int,
        undoEnabled: Bool,
        undoWindowSeconds: Int,
        defaultProvider: Provider,
        defaultModel: String,
        defaultTemperature: Double,
        defaultAlwaysReview: Bool
    ) {
        self.globalHotkey = globalHotkey
        self.enforceHouseStyle = enforceHouseStyle
        self.houseStyleInstruction = houseStyleInstruction
        self.stripDashes = stripDashes
        self.spendCapEnabled = spendCapEnabled
        self.monthlyCapUSD = monthlyCapUSD
        self.spendWarnFraction = spendWarnFraction
        self.historyMode = historyMode
        self.historyRetentionDays = historyRetentionDays
        self.clearHistoryOnQuit = clearHistoryOnQuit
        self.largeSelectionGuardEnabled = largeSelectionGuardEnabled
        self.largeSelectionThreshold = largeSelectionThreshold
        self.undoEnabled = undoEnabled
        self.undoWindowSeconds = undoWindowSeconds
        self.defaultProvider = defaultProvider
        self.defaultModel = defaultModel
        self.defaultTemperature = defaultTemperature
        self.defaultAlwaysReview = defaultAlwaysReview
    }

    /// Tolerant decoder: every field falls back to its `.default` value when the
    /// key is absent, so partial or older settings files load cleanly.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppPrefs.default
        self.globalHotkey = try c.decodeIfPresent(Hotkey.self, forKey: .globalHotkey) ?? d.globalHotkey
        self.enforceHouseStyle = try c.decodeIfPresent(Bool.self, forKey: .enforceHouseStyle) ?? d.enforceHouseStyle
        self.houseStyleInstruction = try c.decodeIfPresent(String.self, forKey: .houseStyleInstruction) ?? d.houseStyleInstruction
        self.stripDashes = try c.decodeIfPresent(Bool.self, forKey: .stripDashes) ?? d.stripDashes
        self.spendCapEnabled = try c.decodeIfPresent(Bool.self, forKey: .spendCapEnabled) ?? d.spendCapEnabled
        self.monthlyCapUSD = try c.decodeIfPresent(Double.self, forKey: .monthlyCapUSD) ?? d.monthlyCapUSD
        self.spendWarnFraction = try c.decodeIfPresent(Double.self, forKey: .spendWarnFraction) ?? d.spendWarnFraction
        self.historyMode = try c.decodeIfPresent(HistoryRetentionMode.self, forKey: .historyMode) ?? d.historyMode
        self.historyRetentionDays = try c.decodeIfPresent(Int.self, forKey: .historyRetentionDays) ?? d.historyRetentionDays
        self.clearHistoryOnQuit = try c.decodeIfPresent(Bool.self, forKey: .clearHistoryOnQuit) ?? d.clearHistoryOnQuit
        self.largeSelectionGuardEnabled = try c.decodeIfPresent(Bool.self, forKey: .largeSelectionGuardEnabled) ?? d.largeSelectionGuardEnabled
        self.largeSelectionThreshold = try c.decodeIfPresent(Int.self, forKey: .largeSelectionThreshold) ?? d.largeSelectionThreshold
        self.undoEnabled = try c.decodeIfPresent(Bool.self, forKey: .undoEnabled) ?? d.undoEnabled
        self.undoWindowSeconds = try c.decodeIfPresent(Int.self, forKey: .undoWindowSeconds) ?? d.undoWindowSeconds
        self.defaultProvider = try c.decodeIfPresent(Provider.self, forKey: .defaultProvider) ?? d.defaultProvider
        self.defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel) ?? d.defaultModel
        self.defaultTemperature = try c.decodeIfPresent(Double.self, forKey: .defaultTemperature) ?? d.defaultTemperature
        self.defaultAlwaysReview = try c.decodeIfPresent(Bool.self, forKey: .defaultAlwaysReview) ?? d.defaultAlwaysReview
    }
}

// MARK: - The store

/// Observable preferences store. Read `AppSettings.shared` from the app; inject a
/// temp `directory` in tests. Every mutation to `prefs` persists to disk
/// immediately (data is tiny and single-user, matching the StyleEditor autosave
/// decision). SwiftUI views bind straight to `settings.prefs.<field>`.
@MainActor
public final class AppSettings: ObservableObject {

    /// The one app-wide instance the Settings UI and the integrator read.
    public static let shared = AppSettings()

    /// The live preferences. Mutating any field re-persists the whole snapshot.
    @Published public var prefs: AppPrefs {
        didSet {
            guard prefs != oldValue else { return }
            save()
        }
    }

    private let overrideDirectory: URL?

    /// - Parameter directory: override the storage directory (tests inject a
    ///   temp dir). `nil` uses the shared Application Support location.
    public init(directory: URL? = nil) {
        self.overrideDirectory = directory
        // Load persisted prefs, else start from defaults. Assigning inside init
        // does not trip `didSet`, so no spurious write on first launch.
        if let url = try? Self.fileURL(overrideDirectory),
           let loaded = try? JSONFile.read(AppPrefs.self, from: url, fallback: AppPrefs.default) {
            self.prefs = loaded
        } else {
            self.prefs = AppPrefs.default
        }
    }

    private static func fileURL(_ override: URL?) throws -> URL {
        let dir = try override ?? StorageLocations.defaultDirectory()
        return dir.appendingPathComponent("settings.json")
    }

    /// Persist the current snapshot. Called on every field change.
    public func save() {
        guard let url = try? Self.fileURL(overrideDirectory) else { return }
        try? JSONFile.write(prefs, to: url)
    }

    /// Reset every setting to its default and persist.
    public func resetToDefaults() {
        prefs = AppPrefs.default
    }

    // MARK: - Enforcement API (pure; the integrator calls these)

    /// The house-style fragment (setting 3.2) to prepend to every prompt when
    /// enforcement is on, else `nil`.
    ///
    /// INTEGRATION(au-english): in `RewriteCoordinator`'s prompt assembly (around
    /// `beginRewrite` / `beginSilentRewrite` where `compose(...)` builds the user
    /// turn), prepend this fragment as a leading system/user instruction when it
    /// is non-nil.
    public func houseStylePromptFragment() -> String? {
        guard prefs.enforceHouseStyle else { return nil }
        let text = prefs.houseStyleInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Deterministically strip em/en dashes from model output (setting 3.2), so
    /// the house rule is a guarantee rather than a hope. Pure; no state read
    /// beyond the `stripDashes` toggle, so it is safe to call anywhere.
    ///
    /// INTEGRATION(au-english): in `RewriteCoordinator`, call this on the
    /// completed text after stream finish and BEFORE `replaceSelection` /
    /// `accept`, e.g. `let out = settings.applyDashStrip(model.rewrite)`.
    public func applyDashStrip(_ text: String) -> String {
        guard prefs.stripDashes else { return text }
        return AppSettings.stripDisallowedDashes(text)
    }

    /// The pure dash strip used by `applyDashStrip`. Replaces em dash (U+2014)
    /// and en dash (U+2013), plus the horizontal bar (U+2015) and figure/small
    /// dashes, with a spaced or bare hyphen so spacing stays natural. Exposed
    /// statically so tests and the integrator can call it without an instance.
    public static func stripDisallowedDashes(_ text: String) -> String {
        var out = text
        // A spaced dash used as punctuation ("word — word") becomes a comma-like
        // pause so the sentence still reads naturally.
        for spaced in [" \u{2014} ", " \u{2013} ", " \u{2015} "] {
            out = out.replacingOccurrences(of: spaced, with: ", ")
        }
        // Any remaining long dash (em, en, horizontal bar, figure, non-breaking
        // hyphen) collapses to a plain hyphen.
        for bare in ["\u{2014}", "\u{2013}", "\u{2015}", "\u{2012}", "\u{2011}"] {
            out = out.replacingOccurrences(of: bare, with: "-")
        }
        return out
    }

    /// Evaluate month-to-date spend against the configured cap (setting 3.3).
    /// Returns `.ok` when the cap is disabled.
    ///
    /// INTEGRATION(spend-cap): in `RewriteCoordinator`, before dispatching a
    /// rewrite (`beginRewrite` / `beginSilentRewrite`), call this with the
    /// month-to-date total. `CostMeter` does not yet expose a month-to-date
    /// figure; the integrator adds per-entry month keys to the tally (doc 3.3)
    /// and passes that here. On `.blocked`, refuse the rewrite and surface a
    /// warning-gold message; on `.warn`, proceed but flag it in the HUD/panel.
    public func evaluateSpendCap(monthToDateUSD: Double) -> SpendCapState {
        guard prefs.spendCapEnabled, prefs.monthlyCapUSD > 0 else { return .ok }
        let fraction = monthToDateUSD / prefs.monthlyCapUSD
        if fraction >= 1.0 { return .blocked(capUSD: prefs.monthlyCapUSD) }
        if fraction >= prefs.spendWarnFraction { return .warn(fractionUsed: fraction) }
        return .ok
    }

    /// Whether a selection of `characterCount` characters trips the
    /// large-selection guard (setting 3.5) and must open the review panel for
    /// confirmation before overwriting. Returns `false` when the guard is off.
    ///
    /// INTEGRATION(large-selection-guard): in `RewriteCoordinator.handleStyleHotkey`
    /// (the silent branch, where `style.alwaysReview == false`), call this on the
    /// captured selection length; when `true`, route to `beginRewrite` (the
    /// review panel) instead of `beginSilentRewrite` so a stray Cmd+A cannot
    /// silently overwrite a whole document.
    public func exceedsLargeSelection(_ characterCount: Int) -> Bool {
        guard prefs.largeSelectionGuardEnabled else { return false }
        return characterCount > prefs.largeSelectionThreshold
    }

    /// A cheap token estimate (chars / 4) for the large-selection confirmation
    /// copy and cost preview (doc 3.5).
    public static func estimateTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }

    /// Whether new rewrites should be written to the History store (setting 3.4).
    ///
    /// INTEGRATION(history-retention): gate `HistoryStore.add` on this (or have
    /// the coordinator skip the `history.add` call) so `.off` logs nothing.
    public func historyShouldLog() -> Bool {
        prefs.historyMode != .off
    }

    /// The cutoff date below which history entries should be trimmed (setting
    /// 3.4), or `nil` when no date-based trim applies (`.capped`, `.off`).
    /// `.session` returns the current process start so only this run survives.
    ///
    /// INTEGRATION(history-retention): the integrator runs a date-based trim in
    /// `HistoryStore` (beside the existing count cap) using this cutoff, and on
    /// quit honours `prefs.clearHistoryOnQuit` / `.session` by clearing.
    public func historyTrimCutoff() -> Date? {
        switch prefs.historyMode {
        case .off, .capped:
            return nil
        case .session:
            return AppSettings.processStart
        case .days:
            return Calendar.current.date(
                byAdding: .day, value: -max(1, prefs.historyRetentionDays), to: Date())
        }
    }

    /// Approximate process-start instant, for `.session` retention.
    static let processStart = Date()
}
