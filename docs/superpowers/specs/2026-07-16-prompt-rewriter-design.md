# Prompt Rewriter — Design Spec

Date: 2026-07-16
Status: Approved by Jean-Luc (chat, 2026-07-16)
Owner: Jean-Luc Alder (personal use only; no notarization, no distribution)

## Purpose

A native macOS menu-bar app that rewrites selected text anywhere on the system using an LLM, with unlimited user-defined prompt styles. Personal replacement for RewriteCmd (which paywalls multiple shortcuts). Primary use case: rewriting rough prompts into effective ones.

## Approved decisions

- Core flow: review panel with iterate field (not silent inline replace)
- Trigger: one global hotkey opens a floating style palette, PLUS optional per-style direct hotkeys
- Providers: Claude + OpenAI, switchable per style; BYOK, keys in macOS Keychain
- Style storage: in-app database (SQLite or SwiftData), edited via Settings window
- v1 extras: streaming output, history, cost meter
- Deferred: diff/what-changed view, Ollama/OpenAI-compatible layer, per-app default styles, prompt variables beyond {{selection}}
- No prompt caching (calls too small to qualify)

## Stack

- Swift 5.9+, SwiftUI, menu-bar app (MenuBarExtra / NSStatusItem)
- Build via Swift Package Manager executable target (no Xcode project file needed); ad-hoc signing, no notarization
- macOS 14+ target
- Text capture: clipboard simulation (save clipboard -> synthesize Cmd+C -> read selection -> on Accept synthesize Cmd+V -> restore clipboard). Requires one-time Accessibility permission.

## Core flow

1. User selects text in any app, presses global hotkey (default: Cmd+Shift+R) or a per-style hotkey.
2. Global hotkey -> floating palette at cursor listing styles (arrow keys + Enter, type-to-filter). Per-style hotkey skips palette.
3. App captures selection via clipboard dance.
4. Review panel opens: original text on top, rewrite streams in below. Buttons: Accept (Return), Retry (Cmd+R), Cancel (Esc), plus an iterate text field ("shorter", "more direct") that sends a follow-up turn and re-streams.
5. Accept -> pastes rewrite over the original selection, restores prior clipboard, logs to History, adds tokens to cost meter.

## Components

| Component | Responsibility |
|---|---|
| HotkeyManager | Global shortcut registration (Carbon RegisterEventHotKey or a small wrapper); routes to palette or direct style |
| SelectionService | Clipboard save/Cmd+C/read/Cmd+V/restore dance via CGEvent; Accessibility permission check + onboarding prompt |
| StyleStore | SwiftData/SQLite CRUD for styles: name, prompt template, provider, model, temperature, optional hotkey, sort order. Seeded with 3 defaults incl. "Effective prompt rewrite" |
| LLMClient | Protocol with two backends: AnthropicClient (Messages API, SSE streaming) and OpenAIClient (chat completions, SSE streaming). Keys read from Keychain |
| KeychainStore | Save/load API keys |
| RewritePanel | Floating NSPanel (non-activating) with SwiftUI content: original, streaming rewrite, Accept/Retry/Cancel, iterate field. Multi-turn: iterate appends to the same message list |
| Palette | Floating style picker at mouse location; keyboard-first |
| HistoryStore | Last 200 rewrites (original, result, style, timestamp, tokens); viewable from menu bar; re-copy |
| CostMeter | Running token + dollar tally (per-model price table), shown in menu-bar dropdown; resettable |
| SettingsWindow | Tabs: Styles (CRUD + hotkey assignment), API Keys, General (global hotkey, launch at login) |

## Data model (styles)

Style: id, name, promptTemplate (contains {{selection}}), provider (.anthropic/.openai), model (string), temperature, hotkey (optional), sortOrder, createdAt.

## Error handling

- No Accessibility permission: onboarding sheet with button to open System Settings pane.
- Empty selection captured: panel shows "No text selected" and closes on any key.
- API error / no key: error state in the panel with a "Open Settings" shortcut; never lose the user's clipboard (restore always in defer/finally).
- Stream interruption: partial text kept, Retry available.

## Testing

- Unit tests: StyleStore CRUD, cost-meter arithmetic, price table, prompt templating, SSE chunk parsing (fixture-based) for both providers.
- Manual smoke script: build, launch, grant permission, run a rewrite in TextEdit end-to-end.
- SelectionService is thin over CGEvent and tested manually (cannot unit test synthetic events reliably).

## Security

- API keys live in Keychain only. The bootstrap key at .secrets/anthropic-key is gitignored and is imported into Keychain on first launch, then the user should rotate it (it was exposed in chat).
- No telemetry, no network calls other than the two LLM APIs.
