# AlembicRewrite: UI Audit and Liquid-Glass Redesign

Date: 2026-07-16
Scope: full UI audit, converged settings roadmap, liquid-glass redesign, progressive onboarding, and an implementation plan for the native SwiftUI menu-bar app at `/Users/jean-lucalder/Desktop/Claude/prompt-rewriter`.
Visual reference: `design/redesign-mockups.html` (self-contained before/after side-by-sides of palette, review panel, and settings, rendered in the liquid-glass style over the warm-dark wallpaper).

---

## 1. Executive summary

AlembicRewrite is a personal macOS menu-bar tool for one user (Jean-Luc). You select text anywhere on your Mac, press a hotkey, and an AI rewrites it in place. It has a command palette (Cmd+Shift+E), per-style direct hotkeys that either replace silently or open a review panel first, a settings window for editing styles and keys, a history list, and a running cost meter.

The app works, and nothing in it hard-crashes or loses your data. The clipboard is always restored, so the worst that goes wrong today is a rewrite landing in the wrong place or a floating panel that will not go away, not lost text. That said, the audit found fourteen bugs and ten friction points. Four bugs matter enough to fix first: floating panels do not close when you click away, arrow-key selection in the palette fights the mouse, typing a filter does not move the highlight to the top match (so Return can silently run the wrong style), and edits to a style are silently thrown away unless you press Save, which also means a hotkey you just recorded never actually gets registered. None of these lose clinical or personal data, but the silent-wrong-style and lost-edit ones are the kind of quiet failure worth fixing before anything else.

Alongside the fixes, this document sets out the ten settings worth building, chosen by convergence across five independent proposal lists and filtered hard for a single-user, local-first, no-cloud tool. The headline additions are a rebindable global hotkey, an always-on Australian-English and no-dashes rule with a deterministic strip, a monthly spend cap, history-retention controls, and a large-selection guard so a stray Select-All cannot silently overwrite a whole document.

The visual half of the document adapts the ratified Alembic liquid-glass design language (the "theme dock" reference) to a native SwiftUI menu-bar utility. The governing rule is simple: glass is for chrome, solid is for reading. Navigation and container surfaces get warm frosted glass; anything you read or type into stays opaque with pinned ink. The redesign restyles every screen (menu dropdown, palette, review panel, silent HUD, settings, onboarding) against that language, and in doing so fixes all fourteen bugs and all ten friction points without removing a single existing feature. Finally, it replaces the one-shot onboarding window with a resumable seven-stage wizard that walks a first-run user from the Accessibility permission through a real in-window first rewrite to a tour of the settings.

The work is sized into eight packages, ordered so the four critical bug fixes and the design-token and font foundations land first, the shared component library next, then screen-by-screen restyling, the settings, and onboarding last. A user should read the file to see exactly what changes and why; an engineer should read it to know which file and line to touch.

---

## 2. Bug report

None of these hard-crash or lose user data. The clipboard-restore `defer` in `SelectionService` (SelectionService.swift:45, 71) holds, so the worst outcomes below are wrong-target pastes and stuck panels, not data loss.

### 2.1 Critical

None.

### 2.2 Major

**B1. Floating panels never dismiss when you click away (stuck-panel dead end).**
Plain English: if you fire the palette or review panel and then click back into your app instead of pressing Esc, the panel stays floating on top forever.
Technical: `NonActivatingPanel` sets `hidesOnDeactivate = false` (RewritePanel.swift:56) and no controller observes `resignKey`/`windowDidResignKey`. The palette (Palette.swift:258) and review panel (RewritePanel.swift:482) only close on Esc/Cancel/Select.
Repro: fire Cmd+Shift+E, then click into another app without pressing Esc. Palette remains on screen.
Fix: add a `windowDidResignKey` delegate on the palette/panel controller that calls the cancel callback.

**B2. Arrow-key navigation fights mouse hover in the palette.**
Plain English: if the cursor is resting over the list, pressing Down keeps snapping the selection back to the row under the mouse.
Technical: `onHover` sets `selectedIndex` (Palette.swift:167-169), and every `selectedIndex` change auto-scrolls that row to `.center` (Palette.swift:175-179). Arrowing moves the highlighted row under a stationary cursor, which re-fires `onHover`, which resets `selectedIndex` to the hovered row.
Repro: open palette with cursor resting over the list, press Down repeatedly. Selection fights back toward the row under the mouse.
Fix: track last mouse location and ignore hover updates unless the mouse actually moved; or gate hover-select off during keyboard navigation.

**B3. Type-to-filter does not reset the highlight to the top match.**
Plain English: after you type a filter, the highlight can stay on a middle row, so Return runs a style you did not mean to.
Technical: `appendCharacters`/`deleteBackward` call `clampSelection` (Palette.swift:65-74, 89-95), which only clamps the upper bound, never resets to the first result.
Repro: open palette, Down twice, type a query that reorders/shrinks the list. Highlight is not on the top result.
Fix: set `selectedIndex = 0` on every filter mutation.

**B4. Unsaved style edits are silently lost.**
Plain English: edit a style (name, template, model, temperature, or a just-recorded hotkey), then click another style or close Settings without pressing Save, and every edit vanishes. The new hotkey never registers.
Technical: `StyleEditor` only persists via the explicit Save button (SettingsWindow.swift:333-336). Editing mutates the in-memory `styles` binding (SettingsWindow.swift:224-231) but never writes to disk until Save; hotkey registration runs from the store on window close (SettingsWindow onSettingsClosed to App.swift:208).
Repro: select a style, record a hotkey, close Settings. Hotkey is not registered; edit is gone.
Fix: autosave on field change (debounced), or block navigation/close with an unsaved-changes prompt; ensure hotkey registration fires on the autosaved change.

### 2.3 Minor

**B5. Accept during streaming pastes partial text and logs zero tokens.**
Plain English: hitting Accept before the rewrite finishes pastes the half-finished text and records the cost as zero.
Technical: `disableAccept` allows Accept while `.streaming` if `rewrite` is non-empty (RewritePanel.swift:467-472); `accept()` permits `.streaming` (RewritePanel.swift:178-181). The coordinator's `accept` reads `lastInputTokens`/`lastOutputTokens` (RewriteCoordinator.swift:389-390), which are only populated at stream finish (RewriteCoordinator.swift:342-344).
Fix: disable Accept until `.completed`, or capture usage on cancellation.

**B6. Iterating mid-stream captures partial assistant text as a completed turn.**
Technical: `onIterate` appends `model.rewrite` (possibly mid-stream) as the assistant turn (RewriteCoordinator.swift:370-376). The iterate field is always enabled regardless of phase (RewritePanel.swift:402-419).
Fix: disable the iterate field unless phase is `.completed`.

**B7. Stale "Saved" indicator in API Keys tab.**
Technical: `anthropicSaved`/`openaiSaved` stay true after the user edits the field to a new, unsaved value (SettingsWindow.swift:109-113, 129-133). The green "Saved" check keeps showing while typing a different key.
Fix: reset the flag on field `.onChange`.

**B8. Unpriced models silently meter at $0.**
Plain English: type a model id the price table does not know and the cost meter shows $0 while you are really spending money.
Technical: `PriceTable.cost` returns 0 for unknown models (PriceTable.swift:43-47) and `totalCostUSD` swallows it (CostMeter.swift:58-68). The model field is a free-text `TextField` (SettingsWindow.swift:315), so any id not in the 5-entry table (PriceTable.swift:32-40) accrues real spend shown as $0. The promised warning does not exist (PriceTable.swift:27).
Fix: surface an "unpriced model" indicator in the meter or style editor.

**B9. Empty-selection false negative on slow apps.**
Technical: `captureTimeout` is 1.0s (SelectionService.swift:29). An app that answers a synthetic Cmd+C slower than 1s yields "" and is treated as empty selection (RewriteCoordinator.swift:173-178, 220-225), showing "No text selected" over a real selection.
Fix: lengthen the timeout to about 2.0s or make it adaptive.

**B10. HUD steals keyboard focus when a sticky error is clicked.**
Technical: the HUD panel is `orderFront` (not key) by design (RewriteHUD.swift:129), but `NonActivatingPanel.canBecomeKey` is true (RewritePanel.swift:60). Clicking the sticky error pill to dismiss it (RewriteHUD.swift:60-64) can make the panel key and pull focus off the user's app.
Fix: override `canBecomeKey` to false for the HUD, or dismiss via a mouse-down monitor rather than a tappable panel.

**B11. Hotkey glyph maps diverge between palette and settings.**
Technical: `HotkeyFormatter.keyName` (Palette.swift:240-249) has no mappings for arrows or delete, while `HotkeyCarbon.specialNames` (SettingsWindow.swift:454-461) does. A style bound to an arrow key shows the arrow glyph in Settings but "?" in the palette row.
Fix: share one formatter.

### 2.4 Cosmetic

**B12. Wrong hotkey in code comment.** App.swift:206 comment says the global palette hotkey is "Cmd+Shift+R"; it is actually Cmd+Shift+E (HotkeyManager.swift:23). Cmd+Shift+R is the AlembicRewriter style's direct key.

**B13. "Streaming..." flash before capture.** `beginRewrite` shows the panel in `.streaming` (RewriteCoordinator.swift:150-154) before `captureSelection` runs (RewriteCoordinator.swift:163). An empty/failed selection shows a brief spinner then flips to the hint/error.

**B14. Iterate field renders in empty-selection and error layouts** (RewritePanel.swift:225-228 always includes `iterateField`), so an "iterate" input appears under a "Nothing was selected" hint.

### 2.5 Friction points

**F1. No duplicate/reserved-hotkey validation.** `HotkeyField` accepts any modifier+key combo (SettingsWindow.swift:402-421); `syncStyleHotkeys` registers each with `try?` and swallows failures (RewriteCoordinator.swift:94-108). Two styles can claim the same combo, or a style can shadow the global Cmd+Shift+E, with no warning and silent non-registration (SettingsWindow.swift:325-331, RewriteCoordinator.swift:103-107).

**F2. History is a near-dead feature.** The menu submenu shows only a 48-char result snippet and copies it on click (App.swift:259-287). No original text, no timestamp, no re-run, no Clear, even though `HistoryStore.clear()` exists (HistoryStore.swift:45) and entries carry `original`, `timestamp`, and token counts (Protocols.swift:147-159).

**F3. Empty style list = silent dead end.** `handleGlobalHotkey` returns with no feedback when there are no styles (RewriteCoordinator.swift:116-117). Reachable by deleting all styles.

**F4. No cost meter live refresh and no per-model breakdown.** The dropdown reads totals on menu-open only (App.swift:224-227). A rewrite completed while the menu was closed is invisible until reopened, and there is no way to see which model drove the spend.

**F5. Global hotkey is fixed and unchangeable.** The General tab only describes Cmd+Shift+E as static text (SettingsWindow.swift:58-66); there is no recorder for it, unlike per-style hotkeys.

**F6. Onboarding "Later" strands the app with no visible recovery.** Dismissing without granting (Onboarding.swift:75) means the only way back is triggering a hotkey (RewriteCoordinator.swift:427-430). Settings shows no Accessibility status and offers no grant-permission entry point.

**F7. Window-drag vs text-selection conflict.** `isMovableByWindowBackground = true` (RewritePanel.swift:49) with `textSelection(.enabled)` on the ORIGINAL/REWRITE panes (RewritePanel.swift:332, 362). Click-dragging to select the rewritten text can drag the whole panel.

**F8. No visible caret or editing in the palette query.** The filter is static `Text` driven by panel-level key routing (Palette.swift:132-138, 277-301). No caret, no paste, no mid-string editing, only append/backspace; it reads as an inert header rather than an input.

**F9. Silent-replace styles give no success confirmation.** The HUD closes the instant paste is issued (RewriteCoordinator.swift:272). If the paste lands in the wrong app/cursor, there is no trace except the History snippet, and no copy fallback.

**F10. No way to distinguish provider without a key set.** The style editor lets you pick a provider/model (SettingsWindow.swift:309-323) with no inline indicator of whether that provider has a saved key. The missing-key error only appears at rewrite time (RewriteCoordinator.swift:230-233, 316-318).

---

## 3. The ten consensus settings

Method: same-setting proposals were normalised across five independent lists and scored by number of backing proposers, average rank, and fit with a single-user, local-first, no-cloud menu-bar utility. Cloud/telemetry items were rejected outright. Nothing below routes data anywhere except the user's chosen provider.

### 3.1 Editable global palette hotkey
Make the hardcoded Cmd+Shift+E palette trigger a recordable Hotkey, like the per-style hotkeys already are.
Use case: Cmd+Shift+E collides with another app (some editors, Excel) or does not suit muscle memory; the user rebinds it once, permanently.
Implementation: persist a `globalHotkey: Hotkey` in a new app-prefs store; swap the static `Text` in GeneralTab for the existing `HotkeyField` recorder; pass it to `HotkeyManaging.registerGlobalHotkey`, which already accepts a `Hotkey`. Only the persisted value is missing.
Consensus: all 5 proposers (ranks 1, 7, 9, 1, 5). Highest expectation-to-effort ratio in the set: the machinery is fully present, yet the one hotkey every user hits most is read-only today.

### 3.2 Australian English + no em/en dash enforcement
A global, always-on rule appended to every prompt enforcing Australian English and no em/en dashes, plus a deterministic post-process pass that strips any dash the model still emits before paste.
Use case: the user's standing house rule on every rewrite; a mechanical strip beats hoping each style's template holds, and it de-duplicates the rule out of all templates.
Implementation: prepend a stored system fragment in `RewriteCoordinator`'s prompt assembly; add a pure string pass between stream-complete and `replaceSelection`. Toggle plus editable text in General.
Consensus: all 5 proposers (ranks 11, 10, 16, 5, 19). Encodes a known hard requirement for this exact user at near-zero cost; the deterministic strip makes it a guarantee rather than a hope.

### 3.3 Monthly spend cap with warn + hard stop
A dollar ceiling per calendar month: a warn threshold flags in the HUD/panel, and at 100 percent new rewrites are blocked until the cap is raised or the month rolls over.
Use case: a direct-hotkey Opus style fired on a huge accidental selection several times; the cap prevents a surprise BYOK bill rather than reporting it after the fact.
Implementation: new `Budget` struct persisted beside `cost.json`; `CostMeter` gains month-to-date totals (add per-entry timestamps / a month key to `ModelTally`); `RewriteCoordinator` checks the cap before dispatch. New Cost section or tab.
Consensus: all 5 proposers (ranks 13, 15, 1, 17, 9). The only candidate that can prevent unbounded spend; leverages existing metering.

### 3.4 History retention and purge controls
Choose whether rewrites are logged at all (Off / session-only / N days / the current 200-cap), a "clear history now" button, and a "clear on quit" toggle. Optionally log analytics only, blanking the original/result plaintext.
Use case: the user rewrites system-wide text that may be sensitive; originals and results currently sit in cleartext in `history.json` indefinitely up to 200 entries.
Implementation: `HistoryStoring` gains a retention policy (`add()` becomes a no-op when Off; a date-based trim runs beside the count trim); `clear()` already exists and needs a button; a `clearHistoryOnQuit` flag checked in `applicationWillTerminate`.
Consensus: 4 proposers (ranks 12, 17, 15, 1). The privacy-lens proposer ranked it #1 as the single biggest data exposure; squarely on-brand for the local-first ethos; store methods largely exist.

### 3.5 Large-selection guard / length-gated confirmation
A configurable character threshold above which a silent style is forced to open the review panel (or show an estimated token count and cost) and require confirmation before overwriting.
Use case: a stray Cmd+A then hotkey would silently ship an entire document to the API and overwrite it with no easy undo; the guard forces eyes-on where the stakes are high.
Implementation: length check in the dispatch path (currently keys only on `style.alwaysReview`); a cheap chars/4 token estimate in `RewriteCoordinator.compose`; threshold field in settings; panel gains a confirm state.
Consensus: 4 proposers backed variants (ranks 6, 5, 12, 8). Unites a safety concern (irreversible large overwrite) and a cost concern (huge accidental payload) in one small conditional on an existing branch.

### 3.6 Model picker backed by a known-models registry
Replace the free-text `model` TextField with a Picker populated from the `PriceTable` models, filtered by provider, with an "Other..." escape hatch for new ids.
Use case: a typo like `claude-sonnet-4.6` today silently yields an unpriced model recorded as $0 that may 404 at request time; the picker prevents both.
Implementation: promote `PriceTable.prices` keys into a `KnownModels` list (id, display name, provider); Picker in `StyleEditor`; keep a text fallback. No protocol change.
Consensus: 3 proposers (ranks 9, 3, 16). Cheapest correctness fix: closes the silent $0 mispricing (B8) that undermines every cost setting.

### 3.7 Undo / restore original after paste
Retain the pre-rewrite selection for a configurable window and expose "Undo last rewrite" (menu item plus optional hotkey) that pastes the original back.
Use case: a silent replace clobbered important text and the target app's Cmd+Z did not fully restore it; the user wants a reliable one-key revert.
Implementation: `RewriteCoordinator` stashes the last captured original in memory for N seconds; `HistoryStore` already stores it; add a menu action and optional hotkey that re-pastes via `SelectionServicing`.
Consensus: 3 proposers (ranks 8, 13, 15). The reversibility backstop for the defining silent-replace flow, which is otherwise irreversible; the original is already captured.

### 3.8 Per-style max output tokens
An integer `maxTokens` field on each Style (sensible default, e.g. 1024), threaded into both backends.
Use case: a "tighten this" or "one sentence" style should never emit 4k tokens; capping output is the single biggest per-call cost lever, since output tokens are roughly 5x input rate on the Anthropic models in the table.
Implementation: add `maxTokens: Int` to `Style` via `decodeIfPresent` (matching the `alwaysReview` migration pattern); stepper in `StyleEditor`; thread through `LLMClienting.stream` into Anthropic `max_tokens` (which that API requires anyway) and OpenAI `max_tokens`.
Consensus: 2 proposers at ranks 2 and 7 (avg 4.5, highest average of any 2-proposer item). Near-zero cost against high, always-on value.

### 3.9 Accessibility permission status and re-grant
A live "Accessibility: granted / not granted" row in General with an "Open settings" button.
Use case: after an OS update or reinstall the permission silently drops and every rewrite fails with no visible reason; the user needs to see why and fix it without hunting.
Implementation: GeneralTab row reading `SelectionServicing.hasAccessibilityPermission()` and calling `openAccessibilitySettings()`, both already on the protocol and currently unused in settings.
Consensus: 2 proposers (ranks 2, 13). The app's single biggest silent-failure mode; plumbing already exists; serves trust and debuggability for a tool that reads every selection.

### 3.10 App-level defaults for new styles
Default provider, model, and temperature (and optionally default review-vs-silent) that `addStyle()` seeds from, instead of the hardcoded Anthropic / claude-haiku-4-5 / 0.7.
Use case: a user who standardises on one model stops re-editing three fields on every new style.
Implementation: three `@AppStorage` values read by `StylesTab.addStyle()` in place of the literals; a Defaults section in General.
Consensus: 2 proposers (ranks 3, 8; avg 5.5). Tiny, low-blast-radius change that removes daily friction for a power user building many styles.

### 3.11 Near misses (not selected)

1. **Streaming on/off toggle** - 3 proposers, all low-conviction (ranks 16, 10, 9); the streaming UX is fine and the perceived-speed gain is marginal.
2. **Per-app style overrides (bundle-ID routing)** - 1 proposer; needs a new `AppRule` model and frontmost-app capture, a medium build on a single lens.
3. **Import / export styles as a file** - 2 proposers, on-ethos and cheap, but single-user single-machine blunts the sharing/backup rationale.
4. **Fallback provider / model on failure** - 2 proposers; useful resilience but meaningfully more error-handling logic, an availability nicety not a protective control.
5. **Local / offline endpoint (BYO base URL)** - 2 proposers, strongest privacy payoff in principle, but it is a feature (client changes, no-key path, model-id UX), not a setting toggle, and unproven for this user's actual need.

---

## 4. Liquid-glass pattern library (condensed to what the redesign uses)

Extracted from `app/alembic-light-glass.html` (the ratified theme dock, 2026-07-16) plus `glass.css`, `materials.css`, `app-glass.css`, `globals.css`, `fonts.css`. Governing rule: **glass is for chrome, solid is for reading.** Translucency lives on navigation and container surfaces; anything a user reads or types into stays opaque with pinned ink.

### 4.1 Core tokens

Corner radii, three tiers, all `.continuous` (squircle, native macOS feel):
```
r1 = 6px   small controls: buttons, menu rows, chips
r2 = 8px   inputs, chips, pills, clear-glass overlays, HUD pill
r3 = 12px  cards, modal frames, regular-glass chrome, panels
```
(The theme-dock HTML uses 13px for r3; the shipped token is 12px. Use 12/8/6.)

Motion:
```
dur-fast  120ms  hover/press feedback   -> .easeOut(0.12)
dur-base  180ms  view + modal show/hide -> .easeOut(0.18)
dur-slow  280ms  large surface slides
ease-spring cubic-bezier(0.32,0.72,0,1) settle-without-overshoot
            -> .timingCurve(0.32,0.72,0,1, dur 0.28) or ~ .spring(response:0.28, dampingFraction:0.9)
```
Body text base is 14px.

### 4.2 Typography

Two families plus mono:
```
--font-display: 'Source Serif 4', Georgia, serif    headers, names, quotes, titles
--font-body:    'DM Sans', -apple-system, 'Segoe UI', sans-serif   everything else
--font-mono:    'IBM Plex Mono', ui-monospace, monospace   code / tabular / hotkeys
```
Bundled weights (woff2, OFL): DM Sans 400/500/700, Source Serif 4 400/600, IBM Plex Mono 400. Only these weights exist; do not request 600 DM Sans or 700 Source Serif (they synthesise).

Concrete type ramp (exact, from the theme dock):

| Role | Family | Size | Weight | Tracking | Transform |
|---|---|---|---|---|---|
| Chrome title (rail H1) | Source Serif 4 | 15px | 600 | normal | none |
| Widget title (accent) | DM Sans | 11px | 700 | .09em | uppercase |
| Section label | DM Sans | 10.5px | 800 | .12em | uppercase |
| Rail group label | DM Sans | 9.5px | 800 | .13em | uppercase |
| Tab strip | DM Sans | 13px | 600 | normal | none |
| Body / note | DM Sans | 11.5-13px | 400 | normal | line-height 1.6 |
| Button label | DM Sans | 12.5px | 600 | normal | none |
| Field label | DM Sans | 11px | 700 | normal | none |
| Input text | DM Sans | 12.5px | 400 | normal | none |
| State caption | DM Sans | 9.5px | 700 | .08em | uppercase |

Signature move: tiny, heavy, wide-tracked uppercase labels (800 weight, .12-.13em tracking, ~10px) against a quiet serif for anything that names a thing.

SwiftUI:
```swift
extension Font {
  static let alTitle   = Font.custom("Source Serif 4", size: 15).weight(.semibold)
  static let alTitleLg = Font.custom("Source Serif 4", size: 17).weight(.semibold)
  static let alBody    = Font.custom("DM Sans", size: 13)
  static let alInput   = Font.custom("DM Sans", size: 12.5)
  static let alButton  = Font.custom("DM Sans", size: 12.5).weight(.semibold)
  static let alLabel   = Font.custom("DM Sans", size: 10.5).weight(.heavy)   // + tracking 1.3
  static let alState   = Font.custom("DM Sans", size: 9.5).weight(.bold)     // + tracking 0.8, uppercase
  static let alMono    = Font.custom("IBM Plex Mono", size: 11).weight(.regular)
}
// Wide-tracked uppercase label (.12em at 10.5px is about 1.26pt):
Text("REWRITE STYLES").font(.alLabel).tracking(1.3).textCase(.uppercase)
```
Bundle the woff2s as OTF/TTF and register via `ATSApplicationFontsPath` in Info.plist. `.custom` falls back to system if the face is missing, matching the CSS fallback chain. Rule: Source Serif 4 for anything that names a thing (style names, panel titles); DM Sans for controls and body.

### 4.3 The accent family and gold

Green (Alembic Green, the default pack):
```
--accent         light #4a6741   dark #6B9464   base brand green, flat fills
--accent-vibrant light #5d8a50   dark #86b37e   glowing green for text/marks ON glass
--accent-soft    light #c8d9c3   dark #3D5A36   pale selection background, soft chips
--accent-text    light #3F5A35   dark #86B07E   darkened for small text on light surfaces
--on-accent      light #f0ece6   dark #111111   warm off-white text ON the accent fill (never pure white)
```
Two-green discipline: `--accent` fills (buttons, bars). `--accent-vibrant` is the glowing colour used only for text/marks on translucent glass, always paired with a white underglow plate (section 4.7). Never put bare `--accent` text on a glass surface.

Gold is warning-only. There is no gold in the default green pack; gold is the identity of alternate packs. As a semantic it is the warning/caregiving amber:
```
--warning      light #b67a2a   dark #D9A85F
--warning-text light #8F5F1E   dark #D9A85F
--warning-soft light #f4e9d2   dark #453a20
```
Reserve gold/amber strictly for a warning or caregiving semantic (cost meter near budget, unsaved state, unpriced model). Do not use gold as a general accent.

State:
```
--danger        light #c8392f   dark #E06B63
--danger-btn-bg light #B3332A   dark #A63E36   darker fill so white label clears 4.5:1
--on-danger     #ffffff (both)
```
Define these as light/dark dynamic colours (keep the existing `NSColor(name:dynamicProvider:)` pattern). The warm off-white `--on-accent` (#f0ece6) matters: buttons use a warm white label, not #ffffff.

### 4.4 The frosted surface recipes (the heart of the system)

**Regular glass (chrome: sidebars, top bar, modal frames):** blur 24px, saturate 1.3, warm tint, border `rgba(255,255,255,0.25)`, and the signature asymmetric specular rim (full-strength 1px inset highlight on the top edge plus a half-strength inset on the left edge, reading as light from the upper-left). Drop `0 8px 32px rgba(0,0,0,0.06)`. Dark: background `rgba(30,28,25,0.55)`, saturate 1.4, edge light `rgba(255,255,255,0.10)`, drop `rgba(0,0,0,0.35)`.

**Clear glass (small overlays: popovers, tooltips, inline menus):** blur 12px, saturate 1.3, radius 8px, background `rgba(255,255,255,0.55)` (a contrast floor, never below .5), tighter drop `0 4px 16px .06`. Same rim. Dark: `rgba(38,35,31,0.45)`.

**Smoke card (the ratified dashboard-card recipe, best for the review panel):**
```
background: warm grey-white #f4f1ea at smoke density 54-96%
border: rgba(255,255,255,0.55)   brighter rim than chrome .25
box-shadow:
  inset 0 1px 0 rgba(255,255,255,0.6)     strong top specular
  inset 0 0 40px rgba(255,255,255,0.12)   soft inner glow, "lit from within"
  0 10px 30px rgba(0,0,0, .10-.34)        step-scaled drop
radius 12px; blur 22px; saturate 1.25; padding 16x18
```
It feels warmer and more solid than chrome glass through the warm tint, the brighter `.55` border and `.6` top rim, and the 40px inner glow. Nested glass goes one step whiter (`--smoke 58%` outer to `--smoke-inner 66%` inner); depth comes from smoke density plus shadow, never z-index or a darker step.

**SwiftUI, the critical decisions.** Do not use `.ultraThinMaterial` for main chrome; it is neutral-cool and reads as generic macOS. Path A (recommended for the menu-bar window and review panel): `NSVisualEffectView` with `.behindWindow` blending plus a warm tint overlay:
```swift
struct FrostedBackground: NSViewRepresentable {
  var material: NSVisualEffectView.Material = .hudWindow
  func makeNSView(context: Context) -> NSVisualEffectView {
    let v = NSVisualEffectView()
    v.material = material          // .hudWindow for 24px chrome, .popover for 12px clear
    v.blendingMode = .behindWindow // blurs the desktop/wallpaper behind the window
    v.state = .active
    return v
  }
  func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
```
Then overlay warm tint + bright rim + top specular gradient and clip to the continuous rounded rect. Material mapping: chrome/regular (24px) to `.hudWindow` or `.underWindowBackground` behind-window; clear/popover (12px) to `.popover` or `.menu`; content surfaces (editor, transcript) to no material, solid `#ffffff` light / `#201F1C` dark. `.behindWindow` gives the wallpaper-show-through effect the CSS `backdrop-filter` produces, exactly right for a menu-bar app floating over arbitrary windows. The saturation lift is baked into the materials, so you get it for free. The 40px inner glow has no direct equivalent; approximate with a centre-fading radial `.white.opacity(0.12)` overlay, or skip first and add if the panel reads flat.

### 4.5 Depth: shadows and z-hierarchy

Three elevation tiers (exact):
```
shadow1  0 1px 4px  rgba(0,0,0,0.04)   resting card   -> dark 0 2px 8px  .35
shadow2  0 4px 16px rgba(0,0,0,0.12)   raised chrome, dropdown, HUD pill -> dark 0 6px 24px .45
shadow3  0 12px 48px rgba(0,0,0,0.18)  modal / review panel, deepest -> dark 0 16px 56px .55
```
Dark mode goes deeper and softer (higher alpha, larger blur) because shadows read weaker on dark surfaces. Cards separate from the canvas by shadow + rim, not z-index.
```swift
.shadow(color: .black.opacity(0.04), radius: 4,  x: 0, y: 1)   // shadow1
.shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 4)   // shadow2
.shadow(color: .black.opacity(0.18), radius: 48, x: 0, y: 12)  // shadow3
```
If SwiftUI blur reads too tight, bump radius up about 1.5x and verify on-screen. For dark mode swap to the deeper tier.

### 4.6 Buttons

```
.btn      font 600 12.5px DM Sans; radius 8; padding 10x16; min-height 32; transition 120ms
.btn-lg   padding 12x20; min-height 40   primary target size
hover  filter brightness(1.06)   active translateY(1px)   disabled opacity .45
```
Variants:
- primaryFlat: `background #4a6741`, label `#f0ece6`. Main action for a system utility (punches clearest).
- primaryLiquid: `accent @ 58%` over material, rim `.white .45`, white label with `.shadow(.black .3, y:1)`.
- smoke (secondary): the frosted recipe at button scale, warm tint, `.55` rim, `inset 0 1px 0 .4` top highlight, label pinned `--ink-base` (never a sliding label).
- gold: `background #b67a2a`, near-black label `#3a2e08`. Warning-adjacent affirmatives only (the review-panel Accept, per existing Alembic.gold convention).
- danger: `#B3332A`, `#ffffff`.
- quiet: transparent, `--accent` bold, permitted only inside opaque panels.
SwiftUI: hover `.brightness(0.06)` (0.12s easeOut); press `.offset(y: pressed ? 1 : 0)`; disabled `.opacity(0.45)`; respect `accessibilityReduceMotion` (no transform/brightness animation).

### 4.7 Focus ring (two-layer) and accent underglow

Two-layer focus ring survives every material and fade: inner 2px `--accent-vibrant`, outer 2px near-white `rgba(255,255,255,0.9)`. The white outer guarantees visibility on an accent-adjacent or busy wallpaper.
```swift
.overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
  .strokeBorder(Color.accentVibrant, lineWidth: 2))
.overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
  .strokeBorder(Color.white.opacity(0.9), lineWidth: 2).padding(-2))
```
Apply on `.focused`; set `.focusEffectDisabled()` and draw this instead.

Accent-title underglow plate: accent display text on glass never sits bare; it wears a 10px white glow plus a 1px white bottom-plate.
```swift
Text(...).foregroundStyle(Color.accentVibrant)
  .shadow(color: .white.opacity(0.65), radius: 5)
  .shadow(color: .white.opacity(0.45), radius: 0, y: 1)
```
Only on glass; on opaque panels the underglow is removed. Dark mode flips the plate to a dark glow.

### 4.8 Inputs and reading surfaces (pinned, never glass)

Hard rule: anything you type into or read from is opaque with pinned ink and a pinned placeholder. No backdrop blur, no adaptive text. This is the entire "solid is for reading" half of the system.
```
input/textarea: font 400 12.5px DM Sans; color --ink-base;
  background color-mix(#fff 92%, paper-tint)  light  /  #2a2c26  dark;
  border rgba(0,0,0,0.18) light / rgba(255,255,255,0.16) dark; radius 8; padding 8x10;
  placeholder --muted-base #6E6B65 (pinned so it never whitens into invisibility)
```
SwiftUI: `TextField`/`TextEditor` with a solid background, hairline border overlay, fixed foreground. Never place a text editor on a material. Prompt editors use `.alMono`.

### 4.9 Wallpaper-fade and accessibility

The full app has a five-step wallpaper-bleed system (Solid, Hint, Balanced, Airy, Immersive) with adaptive ink. For a menu-bar app you do not need it: `NSVisualEffectView` with `.behindWindow` blending IS the wallpaper-fade, done natively. Panel content sits on the smoke tint (a card backing), so it stays near-dark ink at all times per the on-card rule. Do not render bare text over pure blur.

Reduced-transparency does not turn glass off; it flattens to designed solid tiers, keeping the shadow so elevation stays readable:
```
regular glass -> surface-2  #fafaf8 / dark #272521  (backdrop-filter none, shadow-2)
clear glass   -> surface-3  #f0ece4 / dark #312F2B  (shadow 0 2px 8px .12)
```
Honour `@Environment(\.accessibilityReduceTransparency)`: swap the material for the solid surface-2 fill and keep the shadow; drop the rim.

### 4.10 The seven rules that define the look

1. Glass on chrome, solid on reading.
2. Warm, not cool (tints #f4f1ea, text #f0ece6, never Apple's cool default glass).
3. Asymmetric specular rim (full top edge + half left edge inset highlight, lit upper-left).
4. Nested glass goes one step whiter, not darker; depth from smoke + shadow.
5. Two greens: #4a6741 fills, #5d8a50 glows on glass (always with a white underglow plate). Gold is warning-only.
6. Two-layer focus ring: accent-vibrant inner, near-white outer.
7. Tiny heavy wide-tracked uppercase labels against a quiet serif for anything that names a thing.

---

## 5. Screen-by-screen redesign (current vs redesigned)

All values below draw from the pattern library. Every bug and friction point is addressed and cross-referenced. No functionality is removed. See `design/redesign-mockups.html` for the visuals.

### 5.1 Menu bar dropdown

| | Current | Redesigned |
|---|---|---|
| Container | `.menuBarExtraStyle(.menu)` system menu, no design tokens | Label stays `.menu`; body moves to `.menuBarExtraStyle(.window)` hosting a `GlassPanel(material:.popover, radius:12)`, width 300 |
| Cost | cost/token `Text`, read on menu-open only (F4) | Inner clear-glass card (r2, 12x14): SectionHeader "SPEND", `Cost: $%.4f` in `.alTitleLg`, tokens muted. Live-refreshes via `onReceive` of the cost store publisher. Per-model "Breakdown" DisclosureGroup (fixes F4) |
| Reset | Reset button | "Reset" quiet button |
| Action | "Rewrite Selection..." (no shortcut) | Primary flat GlassButton "Rewrite Selection" showing the Cmd+Shift+E glyph on the right |
| History | submenu, 48-char snippet, copy-on-click, no original/timestamp/re-run/clear (F2) | SectionHeader "HISTORY" + "Clear" quiet button (wires `HistoryStore.clear()`). Up to 10 GlassListRows: original snippet, result snippet (muted), timestamp (`.alState`), token count. Click copies result; a small Re-run icon re-fires the style. Empty state "No rewrites yet" (fixes F2) |
| Nav | Settings (Cmd+,), Quit (Cmd+Q) | Same, as quiet rows; plus a Help "Replay setup walkthrough" item above Settings |

Why: the glass window body replaces the flat system menu so the brand recipe reaches the most-used surface; History and the cost meter, whose backing data far exceeds what the UI exposes, are surfaced. Every existing item remains.

### 5.2 Command palette

| | Current | Redesigned |
|---|---|---|
| Container | width 360 non-activating popover-material panel at mouse | `GlassPanel(material:.popover, radius:12)`, width 360, at mouse; `canBecomeKey = true` for typing |
| Search | static `Text` filter, no caret (F8) | accent `magnifyingglass` (underglow) + query in `.alTitle` (serif) + a blinking 1.5pt accent caret so it reads as a live input (F8); placeholder "Filter styles"; right-side result count ("4 of 6") |
| Results | `PaletteRow`s, arrow glyph shows "?" (B11) | ScrollView maxHeight 320, GlassListRow each: provider glyph (A/O in accentText), name `.alBody`, model `.alState` muted, hotkey via shared HotkeyGlyph. Selected row `.accent` fill, white text, r6. Empty "No matching styles" |
| Dismiss | Esc/Cancel/Select only (B1) | `windowDidResignKey` delegate calls cancel (B1) |
| Nav | hover fights arrows (B2), highlight not reset on filter (B3) | hover updates `selectedIndex` only when the pointer moved, gated off during keyboard nav (B2); `selectedIndex = 0` on every filter mutation (B3) |
| Empty list | silent return (F3) | in-panel empty state "No styles yet, open Settings to add one" + quiet "Open Settings" (F3) |

### 5.3 Review panel

| | Current | Redesigned |
|---|---|---|
| Container | width 520 hudWindow-material panel | `GlassPanel(material:.hudWindow, radius:12)`, width 520, minHeight 360, centred on cursor's screen, shadow3 |
| Header | icon, name, status badge, close | accent `wand.and.stars` (underglow) + style name `.alTitleLg` (serif) + StatusBadge (ready/streaming/error/empty) + circular close |
| Reading panes | ORIGINAL/REWRITE with `.textSelection(.enabled)` on glass | SectionHeader "ORIGINAL"/"REWRITE", each a solid opaque surface (`inputBg`, r2, hairline), never glass (rule L5). ORIGINAL maxHeight 90; REWRITE min120/max220, auto-scroll-to-bottom on token append; error layout shows message + preserved partial in the same solid pane |
| Iterate | field always enabled (B6, B14) | solid InputField on `accentSoft @ .55` backing, icon + submit chevron; rendered only when phase `.completed` (fixes B14, and B6 by construction) |
| Actions | Cancel / Retry / Accept (gold), Accept enabled mid-stream (B5) | Cancel (smoke, Esc) / spacer / Retry (smoke, Cmd+R) / Accept (gold, dark label, defaultAction). Accept and iterate-submit disabled until `.completed` (fixes B5, B6) |
| Show timing | shown in `.streaming` before capture (B13) | shown only after a non-empty capture, or a neutral "Preparing" state, never a spinner over an empty selection (B13) |
| Drag | movable-by-background conflicts with text select (F7) | `isMovableByWindowBackground = false`; the header is the explicit drag region so dragging to select text never drags the window (F7) |
| Dismiss | Esc/Cancel only (B1) | shared `windowDidResignKey` cancel (B1) |

Why: reading panes go solid-opaque on glass chrome (the core rule); the two data-integrity bugs (partial paste, partial iterate) close by gating on `.completed`. Gold Accept retained per existing convention.

### 5.4 Silent HUD pill

| | Current | Redesigned |
|---|---|---|
| Container | ~220x44 hudWindow capsule, `orderFront`, above-right of cursor | `GlassPanel(material:.hudWindow, radius:8)` capsule, shadow2, spring entry (`.spring(response:0.28, dampingFraction:0.9)`) |
| Rewriting | spinner + "Rewriting..." + cancel | accent spinner + "Rewriting" `.alBody` + circular close |
| Success | none (F9) | new brief green check + "Replaced" `.alState`, auto-dismiss ~0.9s; if focus changed, offers "Copy result" for ~2s before fading (F9) |
| Error | orange triangle + message + "Click to dismiss"; tap can steal focus (B10) | gold/danger triangle + message (maxWidth 320) + "Click to dismiss"; `canBecomeKey = false` and dismiss via a global mouse-down monitor so it never pulls focus (B10) |

### 5.5 Settings, General tab

| | Current | Redesigned |
|---|---|---|
| Container | grouped Form | `GlassPanel(material:.hudWindow, radius:12)` body, 620x480, glass tab strip (active underline accentVibrant 2pt, `.alBody` 13/600) |
| Startup | launch-at-login Toggle (SMAppService, reverts on failure) | "STARTUP" SectionHeader, GlassToggle "Launch at login" (unchanged behaviour) |
| Global hotkey | static "Cmd Shift E" text, no recorder (F5) | "GLOBAL HOTKEY" SectionHeader + HotkeyRecorder bound to the global palette hotkey, rebindable (F5); footnote on the default and the per-style direct key |
| Accessibility | none (F6) | new "ACCESSIBILITY" SectionHeader: live granted/not-granted status + "Open System Settings" quiet button + "Re-check" (F6) |

Also corrects B12 (comment: the global hotkey is Cmd+Shift+E, not Cmd+Shift+R).

### 5.6 Settings, API Keys tab

| | Current | Redesigned |
|---|---|---|
| Layout | grouped Form; rotate-key banner; Anthropic + OpenAI SecureField/Save/Saved/Remove | glass tab body; each provider in an inner clear-glass card (r2): SectionHeader, solid SecureField (pinned), Save (primaryFlat, disabled when empty) + green "Saved" StatusBadge + Remove (danger quiet) |
| Saved flag | stays true after editing (B7) | resets on the field's `.onChange` so "Saved" disappears the moment the user edits (B7) |
| Rotate banner | conditional | warning-soft (gold family) inline card + Dismiss quiet button |
| Key status | not exposed to editor (F10) | saved/not-saved status exposed to the style editor (F10). Footnote on local-only storage retained |

### 5.7 Settings, Styles tab + editor + hotkey recorder

| | Current | Redesigned |
|---|---|---|
| List | left selectable List, drag-reorder, +/- toolbar | inner clear-glass list (one step whiter than chrome), ~158 wide, GlassListRows, drag-reorder retained, +/- (minus disabled with no selection), selected row `.accent` fill |
| Fields | Name, prompt TextEditor, Provider Picker + model TextField + temp Slider, HotkeyField, Always-review toggle, Save | solid fields on glass: Name InputField; prompt InputField (`.alMono`, minHeight 120, `{{selection}}` hint); Provider Picker + model field + temp Slider (0-2 step 0.05, monospaced readout) |
| Key status | none (F10) | inline dot next to Provider: "Anthropic key set" / "No key" (warning), reading the API Keys store (F10) |
| Unpriced model | silent $0 (B8) | inline "Unpriced, metered at $0" warning-gold caption when the id is not in `PriceTable`; optional picker of known-priced models (B8) |
| Persistence | Save button only; edits lost, hotkey unregistered (B4) | autosave on field change (debounced ~500ms); hotkey registers on the autosaved change (B4) |
| Hotkey validation | none (F1) | HotkeyRecorder validates against other styles' combos and the reserved global Cmd+Shift+E; on collision shows an amber "shared with {style}" / "reserved by global palette" warning and refuses to register silently; surfaces the `try?` failure (F1) |
| Recorder visual | monospaced pill | solid monospaced pill (combo / "Click to record" / "Press keys (Esc to cancel)"), two-layer focus ring when armed, x-clear when set |

### 5.8 Onboarding window

Replaced by the seven-stage wizard (section 7). Restyled to `GlassPanel(material:.hudWindow, radius:12)`, 560x470, glass chrome edge to edge; "Later" no longer strands the app because the General tab now carries the Accessibility status and re-grant entry (F6).

### 5.9 Error states (cross-cutting)

- Empty selection: StatusBadge(empty) "No text selected" + one-line hint in the solid REWRITE pane; iterate field hidden (B14). Lengthen `captureTimeout` from 1.0s to ~2.0s (or adaptive) before concluding empty (B9).
- Provider/key missing: pre-empted in the style editor (F10); at rewrite time, a warning-gold badge + "No API key for {provider}" + a quiet "Open Settings" action.
- Stream error: StatusBadge(error), danger-tinted message in the solid pane, partial text preserved, Retry available. HUD sticky error dismissed via mouse-down monitor (B10).
- Unpriced model: cost meter shows the model with an amber "unpriced" marker rather than a silent $0 (B8).
All error surfaces use the danger/warning families only, never the green accent.

---

## 6. Component library

Build these once in a `Components/` group; they back every screen.

### 6.1 GlassPanel
The load-bearing chrome surface (Path A: NSVisualEffectView + tint + rim).
```swift
struct GlassPanel<Content: View>: View {
  var radius: CGFloat = 12
  var material: NSVisualEffectView.Material = .hudWindow   // .popover for clear tier
  @Environment(\.accessibilityReduceTransparency) var reduceTransparency
  @Environment(\.colorScheme) var scheme
  let content: () -> Content
  var body: some View {
    content()
      .background {
        if reduceTransparency {
          RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.surface2)
        } else {
          FrostedBackground(material: material).overlay(Color.paperTint.opacity(0.42))
        }
      }
      // asymmetric specular rim: top full + left half, lit upper-left
      .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
        .stroke(LinearGradient(colors: [.white.opacity(0.6), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
        .opacity(reduceTransparency ? 0 : 1))
      .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
        .strokeBorder(Color.glassRim, lineWidth: 1).opacity(reduceTransparency ? 0 : 1))
      .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
      .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.22),
              radius: scheme == .dark ? 30 : 24, x: 0, y: 10)
  }
}
```
Reduce-transparency keeps the shadow, drops blur/rim. Inner glow optional.

### 6.2 GlassButton
Variants: primaryFlat, primaryLiquid, smoke, gold, danger, quiet (section 4.6). Common: font `.alButton`, radius r2, large = 12x20/min-40 else 10x16/min-32; hover `.brightness(0.06)` 0.12s; press `.offset(y: pressed ? 1 : 0)`; disabled `.opacity(0.45)`; respect `accessibilityReduceMotion`; `.focusEffectDisabled()` + two-layer ring.
```swift
enum GlassButtonStyle { case primaryFlat, primaryLiquid, smoke, gold, danger, quiet }
struct GlassButton: View {
  let title: String; let style: GlassButtonStyle; let action: () -> Void
  var large = false; var disabled = false
  @State private var hovering = false; @State private var pressed = false
  @FocusState private var focused: Bool
  // ...
}
```

### 6.3 SectionHeader (wide-tracked micro-label)
```swift
struct SectionHeader: View {
  let text: String
  var body: some View {
    Text(text).font(.alLabel).tracking(1.3).textCase(.uppercase).foregroundStyle(Color.mutedBase)
  }
}
```
On glass (accent titles) add the underglow plate; on opaque panels remove it.

### 6.4 GlassListRow
Radius r1, padding 8x10. Selected: `RoundedRectangle(r1).fill(.accent)`, content `.white`. Rest: clear, `.inkBase`; hover fill `.white.opacity(0.07)`. Used in palette results, styles list, history rows.

### 6.5 InputField (solid, pinned ink)
Wraps TextField/TextEditor. Background `Color.inputBg` (never a material); overlay `RoundedRectangle(r2).strokeBorder(inputBorder)`; foreground `.inkBase`; pinned placeholder `.mutedBase`; font `.alInput`; padding 8x10. Prompt editors use `.alMono`.

### 6.6 GlassToggle
Native `Toggle` with `.tint(.accent)`, label `.alBody`. A solid control on glass, satisfying "solid for controls".

### 6.7 StatusBadge
```swift
enum Kind { case ready, streaming, error, empty }
// ready:    accentSoft bg, accentText label, dot
// streaming: warm-smoke bg #e6ddcb, warningText label, animated dot/spinner
// error:    danger @ .15 bg, danger label, exclamationmark.triangle
// empty:    mutedBase label, transparent
```
Font `.alState`, tracking 0.8, uppercase, capsule (radius 999), padding 3x8.

### 6.8 HotkeyGlyph (single shared formatter, fixes B11)
One `HotkeyFormatter` used by both palette rows and Settings, replacing the two divergent maps (`Palette.keyName` and `HotkeyCarbon.specialNames`). Full arrow/delete/tab/escape/space/function-key coverage. Monospaced `.alMono`.

### 6.9 FocusRing modifier (two-layer, rule C2)
```swift
extension View {
  func alFocusRing(_ on: Bool, radius: CGFloat = 6) -> some View {
    self
      .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
        .strokeBorder(Color.accentVibrant, lineWidth: 2).opacity(on ? 1 : 0))
      .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
        .strokeBorder(Color.white.opacity(0.9), lineWidth: 2).padding(-2).opacity(on ? 1 : 0))
  }
}
```
Applied on `.focused`/armed states everywhere, with `.focusEffectDisabled()`.

### 6.10 Design token catalogue (`DesignTokens.swift`, extend existing)
Add the full palette as light/dark dynamic colours (keep the `NSColor(name:dynamicProvider:)` pattern):
```
accent        #4a6741 / #6B9464     accentVibrant #5d8a50 / #86b37e
accentSoft    #c8d9c3 / #3D5A36     accentText    #3F5A35 / #86B07E
onAccent      #f0ece6 / #111111
gold(warning) #b67a2a / #D9A85F     warningText   #8F5F1E / #D9A85F   warningSoft #f4e9d2 / #453a20
danger        #c8392f / #E06B63     dangerBtnBg   #B3332A / #A63E36   onDanger    #ffffff
paperTint     #f4f1ea / rgba(30,28,25,.55)
inkBase       #2b2622 / #E8E2DA     mutedBase     #6E6B65 / #9A968E
surface2      #fafaf8 / #272521     surface3      #f0ece4 / #312F2B
inputBg       color-mix(#fff 92%, paperTint) / #2a2c26
inputBorder   rgba(0,0,0,0.18) / rgba(255,255,255,0.16)
glassRim rgba(255,255,255,0.55)   glassTop rgba(255,255,255,0.60)
hairline rgba(0,0,0,0.14) / rgba(255,255,255,0.10)
```
Radii r1=6/r2=8/r3=12 (.continuous); shadows shadow1/2/3 with the dark deeper tier; motion hover 0.12s / panel 0.18s / spring `.timingCurve(0.32,0.72,0,1, 0.28)`.

---

## 7. Onboarding script and flow

Replaces the one-shot `OnboardingView` (460x340, gated only on `hasAccessibilityPermission()` at launch, no first-run flag) with a single resumable wizard window: 560x470, `.titled/.closable`, non-resizable, centred, title bar hidden (`titlebarAppearsTransparent`, `titleVisibility = .hidden`) so the glass runs edge to edge. Same window instance, swapped root content, so `WindowManager` still owns exactly one `onboardingWindow`.

Persistent frame furniture on every core step: a small serif "Prompt Rewriter" wordmark (top-left), a "Step N of 4" counter (top-right), a four-dot progress rail (filled accent for done/current, hairline ring for pending; the settings tour is a separate labelled chip, not a fifth dot), and a footer bar (Skip tour left / spacer / Back / primary CTA). Stage transitions cross-fade + 8pt slide (0.22s ease); a completed step animates a `checkmark.seal.fill` in accent.

### 7.1 Persistence

New `UserDefaults` keys (grouped in an `OnboardingState` helper):

| Key | Type | Meaning |
|---|---|---|
| `onboarding.completed` | Bool | true once the user reaches Finish or hits Skip tour; suppresses auto-launch |
| `onboarding.lastStep` | Int (0=welcome, 1-4 core, 5=settings tour, 6=finish) | resume point if quit mid-flow |
| `onboarding.version` | Int | bump to re-surface onboarding after a release adds steps |

Launch rule (replaces App.swift:201-202): if not completed, show the wizard at `lastStep` (default welcome); else if not granted, jump straight to Step 1 (permission is the one hard gate, so a returning user who revoked permission lands on the fix-it screen); else no window, app runs silent in the menu bar. The mid-flow trigger from RewriteCoordinator (line 429, hotkey fired with no permission) also routes here, jumping to Step 1.

### 7.2 State machine

States: `welcome -> permission -> apiKey -> firstRewrite -> tour -> settingsTour -> finish`.
- Advance (primary CTA): writes `onboarding.lastStep`.
- Back: previous state, never below welcome, no side effects.
- Skip tour (footer): sets completed, jumps to finish only if Accessibility is granted; if still missing it jumps to permission with a "Grant Accessibility first" note. This is the single non-skippable gate.
- Skip this step (inline, steps 2-4 only): advances one state without completing; Step 1 has no inline skip.
- Close / quit: window closes, completed stays false, lastStep held; next launch resumes there.
- Live re-checks: Steps 1 and 2 poll their own condition on `.onAppear` and on any in-window action.

Plumbing leaned on, all already on protocols: `selection.hasAccessibilityPermission()`, `selection.openAccessibilitySettings()`, `env.keychain` load/save, `env.styleStore` (seeded defaults incl. AlembicRewriter), `RewriteCoordinator` dispatch, the silent HUD, the palette, the review panel.

### 7.3 Screen-by-screen copy and mechanism

Step 0 Welcome: a 6-second orientation, no dot highlighted. `wand.and.stars` 40pt accent, serif title, one paragraph, a three-item "what you'll set up" list. CTA "Get started" (always enabled) to permission; footer "Skip setup".

Step 1 Grant Accessibility: header with a live status pill (`hasAccessibilityPermission()` on appear, after every button press, and a 1.5s repeating poll). Body, three numbered steps, "Open System Settings" (primary) + "Re-check", a green "Permission granted" seal. CTA "Continue" disabled until granted; no inline skip. Verified at the user-visible level (the pill flips green and the CTA enables), not by an internal proxy.

Step 2 API key: two provider rows (Anthropic / OpenAI), each a hairline-bordered card: name + a filled/hollow "key saved" dot read from `env.keychain`, a masked SecureField + Save (disabled when empty) + green Saved tick + Remove (only when a key exists). A bootstrap-imported key (App.swift:196) shows as saved with a muted "imported" caption. CTA "Continue" enabled once at least one key is saved; inline "I'll add this later" advances to a fallback firstRewrite.

Step 3 Guided first rewrite: teaches the silent-replace flow using an in-window sample field, so the user never leaves the app to succeed. A hairline-bordered editable field pre-filled with a sample sentence, `textSelection(.enabled)`; a large monospaced Cmd+Shift+R key-cap (the AlembicRewriter silent style); a live outcome strip (idle "Waiting for your first rewrite..." to spinner "Rewriting..." to green "Done. The line above was rewritten in place."). The window listens for the AlembicRewriter direct hotkey; because the sample field is inside our own window and selected, the real selection dance + coordinator + silent HUD run against it. The user sees the actual HUD pill and the sample text replaced in place. No mock. Fallback with no key: hotkey cue dimmed, "Add an API key to try this," a "Back to keys" button, and the CTA becomes "Skip this step". Verified at the user-visible level (sample visibly changes, real pill appears).

Step 4 Two ways to rewrite: two static preview cards rendered in the real glass style: a mini palette (search glyph + two PaletteRow mocks) captioned "Press Cmd+Shift+E anywhere. Type to filter your styles, press Return to run the highlighted one," and a mini review panel (ORIGINAL/REWRITE + Cancel/Retry/gold Accept) captioned "Any style set to review opens this first." An optional "Try the palette now" ghost button fires the real Cmd+Shift+E over the window; Esc returns focus. CTA "Finish setup" to settingsTour.

Step 5 Settings tour (dismissible, not numbered; progress rail replaced by a "Settings tour, optional" chip): a scrollable digest of the ten consensus settings in four glass groups (Everyday defaults, Spending controls, Safety and undo, Privacy), each row a bold name + one muted sentence. It orients only; a footer "Open Settings" deep-links to the real window and marks complete; "Dismiss" goes to finish.

Step 6 Finish: green `checkmark.seal.fill`, serif title, a compact hotkey cheat sheet (Cmd Shift E open the palette / Cmd Shift R AlembicRewriter silent / Menu bar icon settings, history, cost), footnote "You can replay this walkthrough any time from Help," CTA "Start using Prompt Rewriter" (closes the window). On appear sets `onboarding.completed = true` and clears `lastStep`.

Re-entry: a menu-bar dropdown item "Replay setup walkthrough" (above Settings) calls `windows.showOnboarding(env:, startAt:.welcome)`, ignoring the completed flag, reusing the single window.

All copy uses Australian English and no em or en dashes.

### 7.4 Flow diagram

```
                          LAUNCH
                            |
              onboarding.completed == false ?
                   |                     |
                  YES                    NO
                   |                     |
        resume at lastStep      hasAccessibilityPermission() ?
                   |                |               |
                   |               YES              NO
                   |                |               |
                   |          (no window,      jump to STEP 1
                   |           menu bar only)   (permission)
                   v                                v
         +===================== WIZARD WINDOW =====================+
        |  [0] WELCOME                                             |
        |     Get started ---------------------------> [1]        |
        |     Skip setup --> (gate) ----------> FINISH / [1]      |
        |  [1] PERMISSION  (live pill, poll)                      |
        |     granted? --Continue--> [2]   not granted -> disabled|
        |     Back --> [0]                                        |
        |  [2] API KEY  (Anthropic / OpenAI, Keychain)            |
        |     >=1 key --Continue--> [3]                           |
        |     "I'll add later" ---> [3] (fallback)   Back --> [1] |
        |  [3] FIRST REWRITE  (in-window sample, real HUD)        |
        |     success --Continue--> [4]   Skip this step --> [4]  |
        |     no key -> Back to keys --> [2]         Back --> [2] |
        |  [4] PALETTE + REVIEW TOUR  (previews, optional try)    |
        |     Finish setup --> [5]         Skip this step --> [5] |
        |     Back --> [3]                                        |
        |  [5] SETTINGS TOUR  (10 settings, dismissible)          |
        |     Open Settings --> real Settings + --> [6]           |
        |     Dismiss ------------------------------> [6]         |
        |  [6] FINISH  (completed=true, clears lastStep)          |
        |     Start using --> close window                        |
        +=========================================================+
                            ^
     Help "Replay setup walkthrough" --> WIZARD at [0] (ignores completed)
   CLOSE / QUIT at any step: window closes, completed stays false,
     lastStep held -> next launch resumes there; a rewrite needing
     permission re-opens the wizard at [1]
   SKIP TOUR (footer, steps 0-4): granted? YES -> [6]; NO -> [1] with gate note
```

Build notes: extend `Onboarding.swift` into an `OnboardingWizardView` hosting an `enum OnboardingStep` and `@State step`; add `OnboardingState` (UserDefaults wrapper). `WindowManager.showOnboarding` gains a `startAt:` param and hides the title bar. The App.swift launch gate swaps to the section-7.1 rule. MenuContent gains the replay item. Reuse, do not rebuild: the permission screen is today's `OnboardingView` body plus the live poll and status pill; the API-key rows mirror the Settings API Keys controls; the Step 4 previews are static renders of the existing palette row and panel styling.

---

## 8. Implementation roadmap

Work packages ordered so foundations and the highest-value bug fixes land first. Sizes: S (a few hours), M (a day or so), L (multiple days). Dependencies noted.

| # | Package | Size | Depends on | Contents |
|---|---|---|---|---|
| WP1 | Critical bug fixes | M | none | B1 (windowDidResignKey cancel on palette + review panel), B2 (hover-vs-arrows gate), B3 (highlight reset on filter), B4 (autosave + hotkey registration on change). Standalone, shippable before any restyle. |
| WP2 | Design foundations | M | none (parallel with WP1) | Extend `DesignTokens.swift` with the full palette, radii, shadows, motion (6.10). Bundle DM Sans / Source Serif 4 / IBM Plex Mono, register via `ATSApplicationFontsPath`, add the `Font` extension (4.2). |
| WP3 | Shared component library | M | WP2 | GlassPanel, FrostedBackground, GlassButton, SectionHeader, GlassListRow, InputField, GlassToggle, StatusBadge, HotkeyGlyph (shared formatter, fixes B11), FocusRing (section 6). Reduced-transparency + reduced-motion honoured. |
| WP4 | Remaining minor + cosmetic bugs | S | WP1, WP3 | B5/B6 (gate Accept + iterate on `.completed`), B7 (Saved flag reset), B9 (captureTimeout to ~2.0s), B10 (HUD canBecomeKey false + mouse-down dismiss), B12 (comment), B13 (no streaming flash pre-capture), B14 (iterate excluded from empty/error). |
| WP5 | Restyle chrome surfaces | L | WP3 | Palette (5.2, absorbs F3/F8), review panel (5.3, solid reading panes, F7), silent HUD (5.4, F9 success + copy fallback), menu dropdown (5.1, F2 history + F4 live cost/breakdown). |
| WP6 | Settings restyle + editor safety | L | WP3, WP4 | General (5.5, F5 recorder + F6 accessibility row), API Keys (5.6), Styles editor (5.7, F1 hotkey validation, F10 key-status, B8 unpriced marker). |
| WP7 | The ten settings | L | WP6 for the UI homes | 3.1 global hotkey (needs WP6 recorder), 3.2 AU-English strip, 3.3 spend cap, 3.4 history retention, 3.5 large-selection guard, 3.6 model registry (subsumes B8), 3.7 undo, 3.8 max tokens, 3.9 accessibility status (delivered in WP6), 3.10 new-style defaults. Sequence within: 3.6 + 3.8 first (correctness + cost), then 3.3 + 3.4 + 3.5 (safety/spend), then 3.1/3.2/3.7/3.10 (convenience). |
| WP8 | Onboarding wizard | L | WP3, WP7 (settings tour references the ten settings) | `OnboardingWizardView` + `OnboardingState`, seven stages (section 7), launch-gate swap, replay menu item. Step 3 exercises the real coordinator against the in-window sample; verify at the user-visible level. |

Critical path: WP1 and WP2 in parallel, then WP3, then the rest fan out. WP1 ships independently of the redesign; WP5-WP8 all sit on WP3. Verify every change at the user-visible level (pixels and the real flow), never a DOM/internal proxy: the palette highlight lands on the top match, the panel closes on click-away, the sample text visibly changes with a real pill, the cost meter reflects a rewrite done while the menu was closed.

Coverage confirmation. Bugs fixed: B1-B14. Friction fixed: F1-F10. All existing functionality preserved: every command, hotkey, CRUD action, history copy, cost reset, launch-at-login, key save/remove, drag-reorder, and both run modes (silent replace + review panel). Changes are additive or corrective, never removals. Both product guardrails hold: no client data leaves the machine (BYOK, device-direct to the user's chosen provider), and the tool interprets nothing about a person (it rewrites the user's own selected text on demand).
