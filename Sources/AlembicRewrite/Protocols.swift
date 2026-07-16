//
//  Protocols.swift
//  AlembicRewrite
//
//  THE CONTRACT FILE.
//
//  This file is the single source of truth for every type and protocol the
//  parallel module agents implement against. Do not change a signature here
//  without coordinating: five modules compile against these declarations.
//
//  ---------------------------------------------------------------------------
//  STORAGE DECISION (PINNED)
//  ---------------------------------------------------------------------------
//  Concrete storage is JSON-file-backed, hidden behind the StyleStoring and
//  HistoryStoring protocols below.
//
//  Rationale: SwiftData's macro-driven model container is unreliable inside a
//  bare SwiftPM executable target (no Xcode project, no generated Info.plist /
//  entitlements, ad-hoc signing). JSON files under Application Support are
//  fully SPM-safe, need no schema migration ceremony for v1's tiny data, and
//  keep the "everything is a file" ethos. Because all reads/writes go through
//  the protocols, a later swap to SwiftData or raw sqlite3 touches only the
//  concrete store types, never their callers.
//
//  Storage location (concrete impls own this):
//    ~/Library/Application Support/AlembicRewrite/styles.json
//    ~/Library/Application Support/AlembicRewrite/history.json
//
//  ---------------------------------------------------------------------------
//  FILE -> IMPLEMENTS
//  ---------------------------------------------------------------------------
//  SelectionService.swift ...... SelectionServicing
//  HotkeyManager.swift ......... HotkeyManaging
//  LLMClient.swift ............. LLMClienting factory / shared helpers
//  AnthropicClient.swift ....... LLMClienting (Anthropic Messages API, SSE)
//  OpenAIClient.swift .......... LLMClienting (OpenAI chat completions, SSE)
//  KeychainStore.swift ......... KeychainStoring
//  StyleStore.swift ............ StyleStoring (JSON-file-backed)
//  HistoryStore.swift .......... HistoryStoring (JSON-file-backed)
//  CostMeter.swift ............. CostMetering
//  PriceTable.swift ............ per-model price data consumed by CostMetering
//

import Foundation

// MARK: - Providers

/// The two LLM backends a style can target. Raw values are stable identifiers
/// used for JSON persistence; do not renumber or rename.
public enum Provider: String, Codable, CaseIterable, Sendable {
    case anthropic
    case openai
}

// MARK: - Style

/// A user-defined rewrite style. Persisted by `StyleStoring`, edited in the
/// Styles tab of the Settings window.
public struct Style: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// Display name shown in the palette and settings list.
    public var name: String
    /// Prompt template. Contains the `{{selection}}` placeholder, replaced with
    /// the captured selection before the request is sent.
    public var promptTemplate: String
    public var provider: Provider
    /// Model identifier string, e.g. "claude-3-5-sonnet-latest" or "gpt-4o".
    public var model: String
    public var temperature: Double
    /// Optional per-style direct hotkey. `nil` means the style is only
    /// reachable through the global palette.
    public var hotkey: Hotkey?
    /// Ascending display order in palette and settings.
    public var sortOrder: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        promptTemplate: String,
        provider: Provider,
        model: String,
        temperature: Double,
        hotkey: Hotkey? = nil,
        sortOrder: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.promptTemplate = promptTemplate
        self.provider = provider
        self.model = model
        self.temperature = temperature
        self.hotkey = hotkey
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

/// A registered global shortcut: a virtual key code plus Carbon modifier flags.
/// Kept provider-agnostic so both HotkeyManager (Carbon) and the settings UI
/// can round-trip it through JSON.
public struct Hotkey: Codable, Hashable, Sendable {
    /// Virtual key code (Carbon `kVK_*`).
    public var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey | shiftKey | optionKey | controlKey`).
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

// MARK: - History

/// One completed rewrite, appended to the History log (last 200 kept by the
/// store). Persisted by `HistoryStoring`.
public struct HistoryEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// The captured selection that was rewritten.
    public var original: String
    /// The accepted rewrite result.
    public var result: String
    /// Name of the style used (denormalised so history survives style deletion).
    public var styleName: String
    public var provider: Provider
    public var model: String
    public var timestamp: Date
    public var inputTokens: Int
    public var outputTokens: Int

    public init(
        id: UUID = UUID(),
        original: String,
        result: String,
        styleName: String,
        provider: Provider,
        model: String,
        timestamp: Date = Date(),
        inputTokens: Int,
        outputTokens: Int
    ) {
        self.id = id
        self.original = original
        self.result = result
        self.styleName = styleName
        self.provider = provider
        self.model = model
        self.timestamp = timestamp
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

// MARK: - Usage / cost

/// Token usage for a single LLM turn, reported by an `LLMClienting` backend via
/// its usage callback and folded into the running cost tally by `CostMetering`.
public struct UsageRecord: Codable, Hashable, Sendable {
    public var provider: Provider
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var timestamp: Date

    public init(
        provider: Provider,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        timestamp: Date = Date()
    ) {
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.timestamp = timestamp
    }
}

// MARK: - Storage protocols

/// CRUD for styles. Concrete impl: `StyleStore` (JSON-file-backed).
public protocol StyleStoring: AnyObject {
    /// All styles, ascending by `sortOrder`.
    func all() throws -> [Style]
    /// Insert or update by `id`.
    func save(_ style: Style) throws
    func delete(id: UUID) throws
    /// Persist a full reordering (updates each style's `sortOrder`).
    func reorder(_ styles: [Style]) throws
    /// Populate the store with the three built-in defaults if it is empty
    /// (including "Effective prompt rewrite"). No-op if styles already exist.
    func seedDefaultsIfEmpty() throws
}

/// Append-only rewrite log, capped at the most recent 200 entries.
/// Concrete impl: `HistoryStore` (JSON-file-backed).
public protocol HistoryStoring: AnyObject {
    /// Most-recent-first.
    func recent() throws -> [HistoryEntry]
    /// Append an entry, trimming the oldest beyond the 200-entry cap.
    func add(_ entry: HistoryEntry) throws
    func clear() throws
}

/// Running token + dollar tally, resettable, shown in the menu-bar dropdown.
/// Concrete impl: `CostMeter`.
public protocol CostMetering: AnyObject {
    /// Fold one turn's usage into the running totals and persist.
    func record(_ usage: UsageRecord) throws
    /// Cumulative dollar cost since the last reset, priced via `PriceTable`.
    func totalCostUSD() -> Double
    /// Cumulative input + output tokens since the last reset.
    func totalTokens() -> Int
    /// Zero the tally.
    func reset() throws
}

/// BYOK API-key storage in the macOS Keychain. Concrete impl: `KeychainStore`.
public protocol KeychainStoring: AnyObject {
    func setKey(_ key: String, for provider: Provider) throws
    func key(for provider: Provider) throws -> String?
    func deleteKey(for provider: Provider) throws
}

// MARK: - LLM client

/// A streaming LLM backend. Both `AnthropicClient` and `OpenAIClient` conform.
///
/// The stream yields incremental text deltas. Token usage is delivered
/// out-of-band through `onUsage`, which the backend invokes once (typically at
/// stream end) with the turn's input/output token counts. The panel builds the
/// message list for multi-turn iteration and passes the whole thing each call.
public protocol LLMClienting: Sendable {
    /// Stream a completion for the given message list.
    ///
    /// - Parameters:
    ///   - messages: Ordered conversation turns (system/user/assistant).
    ///   - model: Model identifier from the `Style`.
    ///   - temperature: Sampling temperature from the `Style`.
    ///   - apiKey: BYOK key for this provider, read from Keychain by the caller.
    ///   - onUsage: Invoked once with the turn's token usage (input/output).
    /// - Returns: An async stream of text deltas.
    func stream(
        messages: [ChatMessage],
        model: String,
        temperature: Double,
        apiKey: String,
        onUsage: @escaping @Sendable (_ inputTokens: Int, _ outputTokens: Int) -> Void
    ) -> AsyncThrowingStream<String, Error>
}

/// A single conversation turn passed to `LLMClienting`.
public struct ChatMessage: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }
    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

// MARK: - Selection service

/// The clipboard-simulation "dance" that captures the current selection and
/// pastes a rewrite back. Concrete impl: `SelectionService`.
///
/// Contract: `replaceSelection` must always restore the caller's prior
/// clipboard, even on error (restore in a `defer`/`finally`).
public protocol SelectionServicing: Sendable {
    /// Save clipboard, synthesize Cmd+C, read the selection, restore clipboard.
    /// - Returns: The captured selection text (may be empty if nothing selected).
    func captureSelection() async throws -> String
    /// Save clipboard, place `text`, synthesize Cmd+V over the selection,
    /// restore the prior clipboard.
    func replaceSelection(with text: String) async throws
    /// Whether the Accessibility permission needed for synthetic events is
    /// currently granted.
    func hasAccessibilityPermission() -> Bool
    /// Open the System Settings Accessibility pane for onboarding.
    func openAccessibilitySettings()
}

// MARK: - Hotkey manager

/// Global shortcut registration (Carbon `RegisterEventHotKey`) that routes a
/// press either to the palette (global hotkey) or straight to a style
/// (per-style hotkey). Concrete impl: `HotkeyManager`.
public protocol HotkeyManaging: AnyObject {
    /// Register the single global hotkey that opens the style palette.
    func registerGlobalHotkey(_ hotkey: Hotkey, action: @escaping () -> Void) throws
    /// Register a per-style direct hotkey that skips the palette.
    func registerStyleHotkey(_ hotkey: Hotkey, styleID: UUID, action: @escaping (UUID) -> Void) throws
    /// Remove a previously registered per-style hotkey.
    func unregisterStyleHotkey(styleID: UUID)
    /// Tear down every registration.
    func unregisterAll()
}
