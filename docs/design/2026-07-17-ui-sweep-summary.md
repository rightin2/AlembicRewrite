# AlembicRewrite UI sweep + update feature + v1.1.0 staging

Date: 2026-07-17
Branch: main (working tree, uncommitted)
Build: clean. Tests: 92 passing (16 new UpdateChecker tests included).

## Plain English

This round did three things. First, it fixed 27 user-interface issues an audit
turned up, so the app now reads correctly, respects accessibility settings, and
matches its own design system. The most important were a false security claim in
the first-run wizard (it said your API key lives in the macOS Keychain when it
actually lives in a protected file), white-on-green text that was hard to read in
dark mode, and keyboard/VoiceOver dead ends. Second, it added a quiet in-app
update checker: on launch the app asks GitHub once a day whether a newer version
exists and, if so, shows a small banner offering "Update now" or "Later"; if
anything goes wrong it simply shows nothing. Third, it packaged all of this as
version 1.1.0 and pushed it to staging only.

Staging now shows the v1.1.0 site and a v1.1.0 pre-release with the DMG attached.
The public "latest" release and the production site are untouched and still point
at v1.0.0. Nothing has been promoted to production and nothing has been committed
to git; that step waits for your approval.

## What awaits approval

Running `./scripts/promote-production.sh` (guarded by a typed `promote` confirm)
is the only remaining step. It marks v1.1.0 as the latest release and deploys the
site to the production (main) branch. It has NOT been run.

---

## Technical

### 1. UI improvements (by ID)

All 27 audit items plus the cross-cutting integrator items were implemented across
three parallel packages. Before/after in brief:

High severity
- UI-1 (Onboarding.swift) - false "stored in your macOS Keychain" claim -> accurate
  "private file in the app's Application Support folder" wording matching Settings.
- UI-2 (Components.swift GlassListRow) - selected-row `Color.white` (~3.2:1 in dark)
  -> `Color.onAccent`.
- UI-3 (Palette.swift PaletteRow) - hardcoded `Color.white`/opacity on selected row
  -> `Color.onAccent` (+ .85/.9 for secondary line and hotkey glyph).
- UI-4 (Components.swift GlassPanel + DesignTokens.swift) - GlassPanel is now
  recipe-driven (`recipe: GlassRecipe = .regular`); material/tint/rim/topSpecular/
  radius/shadow read from the recipe; inline shadow -> `.alShadow(recipe.shadow)`.
  Legacy `radius:`/`material:` params kept as pass-throughs so callers compile.
  Intended visual shift toward the ratified spec, not pixel-preserving.
- UI-5 (Palette.swift searchHeader) - Text-mock search field now announces to
  VoiceOver: combined element, "Filter styles" label, typing hint, filter value;
  caret hidden; results list carries a match count.
- UI-6 (RewritePanel.swift) - panel clipped the iterate field on completion ->
  `hosting.sizingOptions = [.preferredContentSize]`; width still pinned, height grows.
- UI-7 / X-1 (RewriteCoordinator.swift:127) - removed `guard !styles.isEmpty` so the
  global hotkey opens the palette's "No styles yet" empty state instead of feeling
  dead. Empty path is safe (move/select methods guard `filtered.isEmpty`).

Medium severity
- UI-8 (SettingsWindow.swift) - settings tabs now keyboard-focusable with a visible
  focus ring, hover lift, and `.isSelected`/`.isButton` traits; on type ramp.
- UI-9 (Components.swift StatusBadge) - off-palette inline colour -> `Color.warningSoft`.
- UI-10 (DesignTokens/Components/Onboarding) - duplicate `#3a2e08` gold-label
  constants -> single `Alembic.onGold` / `Color.onGold` token.
- UI-11 (DesignTokens/Components) - invisible light-mode hover -> adaptive
  `Alembic.hoverFill` / `Color.hoverFill`.
- UI-12 (Components.swift GlassButton) - `.quiet` hover now paints a background fill
  instead of relying on brightness alone.
- UI-13 (RewritePanel.swift) - literal em dash placeholder `"—"` -> "Nothing captured".
- UI-14 (Onboarding.swift) - wrong "from Help" replay copy -> "from the menu bar icon"
  in `.alBody` mutedBase.
- UI-15 (RewriteHUD.swift) - label "Rewriting" -> "Rewriting…"; entry animation ->
  `AlembicMotion.spring`.
- UI-16 (App.swift) - MenuBarExtra label gained `.accessibilityLabel("AlembicRewrite")`
  on both the nsImage and SF Symbol branches.
- UI-17 (App.swift historySection) - history rows are now `Button(.plain)` with copy
  label + hint and a transient "Copied" confirmation (1.5s) in place of the timestamp.
- UI-18 (App.swift) - Settings window styleMask gained `.resizable` +
  `contentMinSize` 640x520.
- UI-19 (SettingsWindow.swift) - `.frame(width/height)` -> `.frame(minWidth/minHeight)`
  so the panel grows with the window.
- UI-20 (SettingsWindow.swift) - styles +/- buttons gained `.help`/labels; delete now
  goes through a destructive `confirmationDialog` (was instant, no undo).
- UI-21 (Components.swift InputField) - added `.focusEffectDisabled()` to all three
  field branches to stop the native ring stacking with the custom one.
- UI-22 (Palette.swift + RewritePanel.swift) - selection auto-scroll and streaming
  tail-follow now gate on `accessibilityReduceMotion`.
- UI-23 (Onboarding.swift) - `.alState` micro-captions now carry the required
  `.tracking(0.8).textCase(.uppercase)` treatment.
- UI-24 (App.swift) - per-render `DateFormatter` -> `Date.FormatStyle`
  (`.dateTime.day().month().hour().minute()`), honouring locale and 24-hour settings.

Low severity
- UI-25 (Palette.swift) - provider letters "A"/"O" now carry `.help` and accessibility
  labels "Anthropic"/"OpenAI".
- UI-26 (Onboarding.swift + App.swift) - corrected stale 560x470 header comment to
  560x540; onboarding NSWindow `title = "AlembicRewrite Setup"`.
- UI-27 (Onboarding.swift) - deleted dead legacy `OnboardingView` and its stale
  integration note.
- X-3 (DesignTokens + SettingsWindow) - added `Font.alFootnote`; three
  `.system(size: 11)` captions swapped onto it.

Cross-cutting confirmed by integrator: X-1 done (above). X-2 motion-token sweep and
X-4 spacing-token sweep remain scheduled follow-ups (not blocking; X-4 conflicts with
every package and was deliberately deferred). X-5 verify pass: build + full test run
below.

Pre-existing `onChange(of:perform:)` macOS 14 deprecation warnings were left untouched
(surgical-changes rule; they are warnings, not errors).

### 2. Update feature specification

Files (new): `Sources/AlembicRewrite/UpdateChecker.swift`,
`Tests/AlembicRewriteTests/UpdateCheckerTests.swift`.

- `SemanticVersion(_:)` - Comparable; strips leading `v`/`V`, tolerates missing
  minor/patch and prerelease suffixes.
- `AppVersion` - reads `CFBundleShortVersionString`, else fallback "1.1.0".
- `GitHubUpdateChecker` - GETs
  `https://api.github.com/repos/rightin2/AlembicRewrite/releases/latest`, 10s timeout,
  parses `tag_name`/`html_url`/the `.dmg` asset (falls back to the release page if no
  dmg). Never throws; every failure collapses to `.failed`. Only network call is an
  anonymous read of the public releases API; no client data involved (privacy guardrail
  respected).
- `UpdatePolicy` (`@MainActor ObservableObject`) - `checkOnLaunch()` 24h-throttled,
  `checkNow()`, `dismiss()`, `openDownload()`. Persists last-check date and dismissed
  version; a dismissed version is suppressed until a strictly newer one appears.
- `UpdateBanner(policy:)` - glass banner reusing GlassPanel/GlassButton, "Update now"
  / "Later".

Integration (App.swift, done):
- `AppDelegate` gained `let updatePolicy = UpdatePolicy()` and a non-blocking
  `Task { await updatePolicy.checkOnLaunch() }` at the end of
  `applicationDidFinishLaunching`.
- `MenuContent` gained `@ObservedObject var updatePolicy` and renders
  `UpdateBanner(policy: updatePolicy)` at the top of its VStack (above `spendCard`);
  the scene passes `appDelegate.updatePolicy` in.

### 3. Test results

- `swift build` - Build complete, 0 errors (deprecation warnings only).
- `swift test` - Executed 92 tests, 0 failures. UpdateCheckerTests: 16/16 passing
  (semver tolerant-parse/compare, available/upToDate/failed status paths, dmg-vs-page
  fallback, non-2xx/transport/malformed -> failed, policy surfacing, dismissal
  suppression + re-prompt, 24h throttle, checkNow bypass, no-corruption-on-failure).

### 4. Versioning + staging

- `VERSION` = `1.1.0` (single source of truth). `make-app.sh` interpolates it into
  `CFBundleShortVersionString` and `CFBundleVersion`; verified on the installed app:
  both keys read `1.1.0`.
- DMG: `dist/AlembicRewrite.dmg`, 7277514 bytes (6.9 MB) - matches the site's existing
  "6.9 MB" figure, so no site size edit is needed before promotion. (Executor 5's
  integrator comment at site/index.html:370 can be removed at promotion time; left in
  place for now.)

Regression results:
- Staging site `https://staging.alembicrewrite.pages.dev` -> HTTP/2 200.
- DMG asset `https://github.com/rightin2/AlembicRewrite/releases/download/v1.1.0/AlembicRewrite.dmg`
  -> 302 then 200, content-length 7277514 (~7 MB).
- `https://github.com/rightin2/AlembicRewrite/releases/latest` -> redirects to
  `.../tag/v1.0.0` (production release untouched).
- Release flags: v1.1.0 `isPrerelease: true`, v1.0.0 `isPrerelease: false`.
- Secret scan: mounted the new DMG and grepped for `sk-ant-api03-4xN8` and any
  `sk-ant-api03-…` pattern - both absent (pass).

### 5. Staging URLs

- Site (alias): https://staging.alembicrewrite.pages.dev
- Site (deployment): https://2b051d18.alembicrewrite.pages.dev
- Pre-release: https://github.com/rightin2/AlembicRewrite/releases/tag/v1.1.0

### 6. Exact promote-to-production step (NOT run)

```
cd /Users/jean-lucalder/Desktop/Claude/prompt-rewriter
./scripts/promote-production.sh    # type: promote
```

This runs `gh release edit v1.1.0 --prerelease=false --latest` (makes v1.1.0 the
latest release) then `npx wrangler pages deploy site --project-name alembicrewrite
--branch main` (production site). Nothing else in this round should be re-run.
