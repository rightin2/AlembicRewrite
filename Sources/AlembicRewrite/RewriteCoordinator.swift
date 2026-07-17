//
//  RewriteCoordinator.swift
//  AlembicRewrite
//
//  The glue that turns the shipped modules into a working app. Owns the full
//  runtime flow:
//
//    global hotkey  -> capture selection -> Palette -> chosen style ─┐
//    per-style hotkey ------------------> capture selection ---------┤
//                                                                    ▼
//                        RewritePanel streams from the right LLMClient backend
//                        (provider/model from the Style, key from Keychain)
//                                                                    │
//        Accept -> replaceSelection (paste) -> HistoryEntry -> CostMeter
//        Retry  -> re-stream the same message list
//        Iterate-> append assistant + user turns, re-stream
//        Cancel -> tear the panel down
//
//  Error states handled per the spec, and the user's clipboard is never lost
//  (SelectionService restores it in a defer on every capture/paste):
//    - No Accessibility permission -> onboarding window, flow aborts.
//    - Empty selection             -> panel shows the hint, closes on any key.
//    - Missing API key             -> panel error state pointing at Settings.
//    - Stream failure              -> panel error state, partial text kept, Retry.
//

import SwiftUI
import AppKit

/// Thread-safe holder for the out-of-band token usage a backend reports via its
/// `onUsage` callback (which may fire off the main actor).
private final class UsageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (input: Int, output: Int)?

    func set(input: Int, output: Int) {
        lock.lock(); defer { lock.unlock() }
        stored = (input, output)
    }

    var value: (input: Int, output: Int)? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

@MainActor
final class RewriteCoordinator {
    private let env: AppEnvironment
    private weak var windows: WindowManager?

    private let paletteController = PaletteController()
    private let panelController = RewritePanelController()
    private let hudController = HUDController()

    /// The in-flight capture/stream task, cancelled on new triggers, Cancel,
    /// Retry, Iterate and Accept.
    private var activeTask: Task<Void, Never>?
    /// Local key monitor used only for the "empty selection -> close on any key"
    /// behaviour while that panel is showing.
    private var emptyKeyMonitor: Any?

    /// Conversation state for the panel currently on screen. Retry re-streams
    /// `messages` as-is; Iterate appends an assistant + user turn first.
    private var messages: [ChatMessage] = []
    /// Token usage from the most recently completed stream, logged on Accept.
    private var lastInputTokens = 0
    private var lastOutputTokens = 0

    /// The app-preferences store the ten settings enforce through (section 3).
    private let settings = AppSettings.shared

    /// The pre-rewrite original text stashed for the undo window (setting 3.7),
    /// with the instant it expires. Set after every paste when undo is on.
    private var undoStash: (original: String, expiry: Date)?

    init(env: AppEnvironment, windows: WindowManager) {
        self.env = env
        self.windows = windows
    }

    // MARK: - Substitution (kept static + pure so it is unit-testable)

    nonisolated static func compose(template: String, selection: String) -> String {
        template.replacingOccurrences(of: "{{selection}}", with: selection)
    }

    // MARK: - Hotkey registration

    /// Register the global palette hotkey and every per-style direct hotkey.
    /// INTEGRATION(global-hotkey): the global trigger is the user-editable
    /// `AppSettings.shared.prefs.globalHotkey` (setting 3.1), not the hardcoded
    /// default. `syncStyleHotkeys` re-reads it, so rebinding then closing Settings
    /// (which fires `onSettingsClosed -> syncStyleHotkeys`) re-registers it live.
    func registerHotkeys() {
        try? env.hotkeys.registerGlobalHotkey(settings.prefs.globalHotkey) { [weak self] in
            self?.handleGlobalHotkey()
        }
        syncStyleHotkeys()
    }

    /// Re-register per-style direct hotkeys to match the current style list.
    /// Called at launch and whenever the Settings window closes (styles may have
    /// changed). The global hotkey is left untouched.
    func syncStyleHotkeys() {
        let styles = (try? env.styleStore.all()) ?? []
        // Clear existing per-style registrations by re-registering global first,
        // then re-adding each. unregisterAll would also drop the global, so we
        // rebuild both to stay in sync.
        env.hotkeys.unregisterAll()
        try? env.hotkeys.registerGlobalHotkey(settings.prefs.globalHotkey) { [weak self] in
            self?.handleGlobalHotkey()
        }
        for style in styles where style.hotkey != nil {
            try? env.hotkeys.registerStyleHotkey(style.hotkey!, styleID: style.id) { [weak self] id in
                self?.handleStyleHotkey(styleID: id)
            }
        }
    }

    // MARK: - Triggers

    /// Global hotkey (or the menu-bar "Rewrite Selection…" item): open the
    /// palette so the user can pick a style.
    func handleGlobalHotkey() {
        guard ensurePermission() else { return }
        let styles = (try? env.styleStore.all()) ?? []
        // Open the palette even with zero styles so its "No styles yet" empty
        // state renders (UI-7); guarding on emptiness made the hotkey feel dead.

        let vm = PaletteViewModel(styles: styles)
        vm.onSelect = { [weak self] style in
            self?.paletteController.close()
            self?.beginRewrite(style: style)
        }
        vm.onCancel = { [weak self] in
            self?.paletteController.close()
        }
        paletteController.show(model: vm)
    }

    /// Per-style direct hotkey: skip the palette. If the style opts into the
    /// review panel it opens as usual; otherwise the rewrite runs silently and
    /// the result is pasted straight over the selection.
    func handleStyleHotkey(styleID: UUID) {
        guard ensurePermission() else { return }
        guard let style = (try? env.styleStore.all())?.first(where: { $0.id == styleID }) else { return }
        if style.alwaysReview {
            beginRewrite(style: style)
        } else {
            beginSilentRewrite(style: style)
        }
    }

    // MARK: - Rewrite pipeline

    /// - Parameter preCaptured: when non-nil, the selection was already captured
    ///   upstream (the large-selection guard handing a silent rewrite over to the
    ///   review panel) so we skip a second Cmd+C. When nil, capture here.
    private func beginRewrite(style: Style, preCaptured: String? = nil) {
        // Tear down anything already on screen so we never orphan a panel.
        activeTask?.cancel()
        removeEmptyKeyMonitor()
        panelController.close()
        hudController.close()

        let model = RewritePanelViewModel(styleName: style.name, phase: .streaming)
        wireCallbacks(model: model, style: style)

        // INTEGRATION(spend-cap): refuse a new rewrite once the month is over the
        // cap (setting 3.3), surfacing the reason in the panel error state.
        if let blocked = self.spendCapBlockMessage() {
            model.original = preCaptured ?? ""
            model.fail(blocked)
            self.panelController.show(model: model)
            return
        }

        activeTask = Task { [weak self] in
            guard let self else { return }

            // 1. Capture the selection BEFORE the panel appears, so we never
            //    flash a streaming spinner over an empty or failed selection
            //    (B13). SelectionService restores the clipboard in a defer, so a
            //    throw here never loses the user's clipboard.
            let selection: String
            if let preCaptured {
                selection = preCaptured
            } else {
                do {
                    selection = try await self.env.selection.captureSelection()
                } catch {
                    if Task.isCancelled { return }
                    model.original = ""
                    model.fail("Could not read the selection. \(Self.describe(error))")
                    self.panelController.show(model: model)
                    return
                }
            }

            if Task.isCancelled { return }

            // 2. Empty selection -> hint panel that closes on any key.
            guard !selection.isEmpty else {
                model.original = ""
                model.phase = .emptySelection
                self.panelController.show(model: model)
                self.installEmptyKeyMonitor()
                return
            }

            // 3. Non-empty: build the first turn (with the house-style rule when
            //    enabled, setting 3.2), show the panel, then stream.
            model.original = selection
            self.messages = self.buildInitialMessages(style: style, selection: selection)
            self.panelController.show(model: model)

            await self.runStream(style: style, model: model)
        }
    }

    // MARK: - Silent rewrite pipeline (no review panel)

    /// Direct-hotkey rewrite with no panel: show a HUD, capture the selection,
    /// stream the whole result in the background, then paste it over the
    /// selection and log history + cost. Errors surface in the HUD.
    private func beginSilentRewrite(style: Style) {
        // Tear down anything already on screen so we never orphan a surface.
        activeTask?.cancel()
        removeEmptyKeyMonitor()
        panelController.close()
        hudController.close()

        let hud = HUDViewModel()
        hud.onCancel = { [weak self] in self?.cancelSilent() }
        hud.onDismiss = { [weak self] in self?.hudController.close() }
        hudController.show(model: hud)

        // INTEGRATION(spend-cap): refuse the silent rewrite when over the monthly
        // cap (setting 3.3), surfacing the reason as a sticky HUD error.
        if let blocked = spendCapBlockMessage() {
            hud.showError(blocked, sticky: true)
            return
        }

        activeTask = Task { [weak self] in
            guard let self else { return }

            // 1. Capture. SelectionService restores the clipboard in a defer.
            let selection: String
            do {
                selection = try await self.env.selection.captureSelection()
            } catch {
                hud.showError("Could not read the selection. \(Self.describe(error))", sticky: true)
                return
            }
            if Task.isCancelled { return }

            // 2. Empty selection -> transient HUD error, auto-dismiss after ~3s.
            guard !selection.isEmpty else {
                hud.showError("No text selected", sticky: false)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !Task.isCancelled { self.hudController.close() }
                return
            }

            // 2b. INTEGRATION(large-selection-guard): a silent style fired on a
            //     very large selection (setting 3.5) is forced into the review
            //     panel so a stray Select-All cannot silently overwrite a whole
            //     document. Hand the already-captured selection over unchanged.
            if self.settings.exceedsLargeSelection(selection.count) {
                self.hudController.close()
                self.beginRewrite(style: style, preCaptured: selection)
                return
            }

            // 3. Read the BYOK key.
            let apiKey: String
            do {
                guard let key = try self.env.keychain.key(for: style.provider), !key.isEmpty else {
                    hud.showError("No API key set for \(style.provider.rawValue). Open Settings to add one.", sticky: true)
                    return
                }
                apiKey = key
            } catch {
                hud.showError("Could not read the API key. \(Self.describe(error))", sticky: true)
                return
            }

            // 4. Stream the whole result (no panel, no incremental display).
            //    Messages carry the house-style rule when enabled (setting 3.2).
            let msgs = self.buildInitialMessages(style: style, selection: selection)
            let client = LLMClientFactory.client(for: style.provider)
            let usage = UsageBox()
            var result = ""
            do {
                let stream = client.stream(
                    messages: msgs,
                    model: style.model,
                    temperature: style.temperature,
                    maxTokens: style.maxTokens,
                    apiKey: apiKey,
                    onUsage: { input, output in usage.set(input: input, output: output) }
                )
                for try await delta in stream {
                    try Task.checkCancellation()
                    result += delta
                }
            } catch is CancellationError {
                return
            } catch {
                hud.showError(Self.describe(error), sticky: true)
                return
            }

            if Task.isCancelled { return }
            guard !result.isEmpty else {
                hud.showError("The model returned no text.", sticky: true)
                return
            }

            // 4b. INTEGRATION(au-english): deterministically strip any em/en dash
            //     the model still emitted before it hits the document (setting 3.2).
            result = self.settings.applyDashStrip(result)

            // 5. Hide the HUD, then paste over the selection. Stash the original
            //    for the undo window (setting 3.7) BEFORE the paste.
            self.stashForUndo(original: selection)
            self.hudController.close()
            do {
                try await self.env.selection.replaceSelection(with: result)
            } catch {
                NSLog("AlembicRewrite: silent paste failed: \(error)")
            }

            // 6. Log history (honouring the retention policy, setting 3.4) + fold
            //    cost.
            let value = usage.value
            let entry = HistoryEntry(
                original: selection,
                result: result,
                styleName: style.name,
                provider: style.provider,
                model: style.model,
                inputTokens: value?.input ?? 0,
                outputTokens: value?.output ?? 0
            )
            self.logHistory(entry)
            if let value {
                try? self.env.costMeter.record(UsageRecord(
                    provider: style.provider,
                    model: style.model,
                    inputTokens: value.input,
                    outputTokens: value.output
                ))
            }
            self.env.bumpRefresh()
        }
    }

    private func cancelSilent() {
        activeTask?.cancel()
        activeTask = nil
        hudController.close()
    }

    /// Stream `messages` from the style's backend into `model`.
    private func runStream(style: Style, model: RewritePanelViewModel) async {
        model.beginStreaming()

        // Read the BYOK key from the Keychain.
        let apiKey: String
        do {
            guard let key = try env.keychain.key(for: style.provider), !key.isEmpty else {
                model.fail("No API key set for \(style.provider.rawValue). Open Settings from the menu bar to add one.")
                return
            }
            apiKey = key
        } catch {
            model.fail("Could not read the API key. \(Self.describe(error))")
            return
        }

        let client = LLMClientFactory.client(for: style.provider)
        let usage = UsageBox()
        let stream = client.stream(
            messages: messages,
            model: style.model,
            temperature: style.temperature,
            maxTokens: style.maxTokens,
            apiKey: apiKey,
            onUsage: { input, output in usage.set(input: input, output: output) }
        )

        do {
            for try await delta in stream {
                try Task.checkCancellation()
                model.appendToken(delta)
            }
            // INTEGRATION(au-english): strip disallowed dashes on completion so
            // the preview matches exactly what Accept will paste (setting 3.2).
            let stripped = settings.applyDashStrip(model.rewrite)
            if stripped != model.rewrite { model.rewrite = stripped }
            model.finish()
            if let value = usage.value {
                lastInputTokens = value.input
                lastOutputTokens = value.output
                let record = UsageRecord(
                    provider: style.provider,
                    model: style.model,
                    inputTokens: value.input,
                    outputTokens: value.output
                )
                try? env.costMeter.record(record)
                env.bumpRefresh()
            }
        } catch is CancellationError {
            // Superseded by Retry/Iterate/Cancel; leave the panel alone.
        } catch {
            model.fail(Self.describe(error))
        }
    }

    private func wireCallbacks(model: RewritePanelViewModel, style: Style) {
        model.onAccept = { [weak self] text in
            self?.accept(text: text, style: style, model: model)
        }
        model.onRetry = { [weak self] in
            guard let self else { return }
            self.activeTask?.cancel()
            self.activeTask = Task { await self.runStream(style: style, model: model) }
        }
        model.onIterate = { [weak self] instruction in
            guard let self else { return }
            self.messages.append(ChatMessage(role: .assistant, content: model.rewrite))
            self.messages.append(ChatMessage(role: .user, content: instruction))
            self.activeTask?.cancel()
            self.activeTask = Task { await self.runStream(style: style, model: model) }
        }
        model.onCancel = { [weak self] in
            self?.dismiss()
        }
    }

    private func accept(text: String, style: Style, model: RewritePanelViewModel) {
        let original = model.original
        activeTask?.cancel()
        activeTask = nil
        removeEmptyKeyMonitor()
        panelController.close()

        let inputTokens = lastInputTokens
        let outputTokens = lastOutputTokens

        Task { [weak self] in
            guard let self else { return }
            // Stash the original for the undo window (setting 3.7) before pasting.
            self.stashForUndo(original: original)
            // Paste over the selection. Clipboard is restored in a defer inside
            // the service, so a paste failure still leaves the user's clipboard
            // intact.
            do {
                try await self.env.selection.replaceSelection(with: text)
            } catch {
                NSLog("AlembicRewrite: paste failed: \(error)")
            }
            let entry = HistoryEntry(
                original: original,
                result: text,
                styleName: style.name,
                provider: style.provider,
                model: style.model,
                inputTokens: inputTokens,
                outputTokens: outputTokens
            )
            self.logHistory(entry)
            self.env.bumpRefresh()
        }
    }

    // MARK: - Prompt assembly, spend cap, history, undo (settings 3.2 - 3.7)

    /// Build the first-turn message list, prepending the house-style rule as a
    /// system turn when enforcement is on (setting 3.2).
    private func buildInitialMessages(style: Style, selection: String) -> [ChatMessage] {
        var msgs: [ChatMessage] = []
        if let fragment = settings.houseStylePromptFragment() {
            msgs.append(ChatMessage(role: .system, content: fragment))
        }
        let prompt = Self.compose(template: style.promptTemplate, selection: selection)
        msgs.append(ChatMessage(role: .user, content: prompt))
        return msgs
    }

    /// The message to show when the monthly spend cap blocks a rewrite (setting
    /// 3.3), or `nil` to proceed. `.warn` proceeds silently for now.
    private func spendCapBlockMessage() -> String? {
        switch settings.evaluateSpendCap(monthToDateUSD: env.costMeter.monthToDateCostUSD()) {
        case .ok, .warn:
            return nil
        case .blocked(let cap):
            return String(
                format: "Monthly spend cap of $%.2f reached. Raise the cap in Settings or wait for the new month.",
                cap
            )
        }
    }

    /// Append to History honouring the retention policy (setting 3.4): skip when
    /// logging is off, and run a date-based trim after each add.
    private func logHistory(_ entry: HistoryEntry) {
        guard settings.historyShouldLog() else { return }
        try? env.historyStore.add(entry)
        if let cutoff = settings.historyTrimCutoff() {
            try? env.historyStore.prune(olderThan: cutoff)
        }
    }

    /// Remember the pre-rewrite text for the undo window (setting 3.7). No-op when
    /// undo is disabled.
    private func stashForUndo(original: String) {
        guard settings.prefs.undoEnabled else { undoStash = nil; return }
        let window = TimeInterval(max(1, settings.prefs.undoWindowSeconds))
        undoStash = (original: original, expiry: Date().addingTimeInterval(window))
    }

    /// Whether an unexpired undo original is available (drives the menu item's
    /// enabled state, setting 3.7).
    var canUndo: Bool {
        guard settings.prefs.undoEnabled, let stash = undoStash else { return false }
        return Date() < stash.expiry
    }

    /// Re-paste the stashed original over the current selection (setting 3.7).
    /// Silently does nothing when the window has lapsed or undo is off.
    func undoLastRewrite() {
        guard settings.prefs.undoEnabled, let stash = undoStash, Date() < stash.expiry else { return }
        undoStash = nil
        let original = stash.original
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.env.selection.replaceSelection(with: original)
            } catch {
                NSLog("AlembicRewrite: undo paste failed: \(error)")
            }
        }
    }

    private func dismiss() {
        activeTask?.cancel()
        activeTask = nil
        removeEmptyKeyMonitor()
        panelController.close()
        hudController.close()
    }

    // MARK: - Permission gate

    @discardableResult
    private func ensurePermission() -> Bool {
        if env.selection.hasAccessibilityPermission() { return true }
        windows?.showOnboarding(env: env, startAt: .permission)
        return false
    }

    // MARK: - Empty-selection key monitor

    private func installEmptyKeyMonitor() {
        removeEmptyKeyMonitor()
        emptyKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            self?.dismiss()
            return nil
        }
    }

    private func removeEmptyKeyMonitor() {
        if let monitor = emptyKeyMonitor {
            NSEvent.removeMonitor(monitor)
            emptyKeyMonitor = nil
        }
    }

    // MARK: - Error text

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
