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
    func registerHotkeys() {
        try? env.hotkeys.registerGlobalHotkey(HotkeyManager.defaultGlobalHotkey) { [weak self] in
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
        try? env.hotkeys.registerGlobalHotkey(HotkeyManager.defaultGlobalHotkey) { [weak self] in
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
        guard !styles.isEmpty else { return }

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

    private func beginRewrite(style: Style) {
        // Tear down anything already on screen so we never orphan a panel.
        activeTask?.cancel()
        removeEmptyKeyMonitor()
        panelController.close()
        hudController.close()

        let model = RewritePanelViewModel(styleName: style.name, phase: .streaming)
        wireCallbacks(model: model, style: style)
        panelController.show(model: model)

        activeTask = Task { [weak self] in
            guard let self else { return }

            // 1. Capture the selection. SelectionService restores the clipboard
            //    in a defer, so a throw here never loses the user's clipboard.
            let selection: String
            do {
                selection = try await self.env.selection.captureSelection()
            } catch {
                model.original = ""
                model.fail("Could not read the selection. \(Self.describe(error))")
                return
            }

            if Task.isCancelled { return }

            // 2. Empty selection -> hint panel that closes on any key.
            guard !selection.isEmpty else {
                model.original = ""
                model.phase = .emptySelection
                self.installEmptyKeyMonitor()
                return
            }

            // 3. Build the first turn from the style template.
            model.original = selection
            let prompt = Self.compose(template: style.promptTemplate, selection: selection)
            self.messages = [ChatMessage(role: .user, content: prompt)]

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
            let prompt = Self.compose(template: style.promptTemplate, selection: selection)
            let msgs = [ChatMessage(role: .user, content: prompt)]
            let client = LLMClientFactory.client(for: style.provider)
            let usage = UsageBox()
            var result = ""
            do {
                let stream = client.stream(
                    messages: msgs,
                    model: style.model,
                    temperature: style.temperature,
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

            // 5. Hide the HUD, then paste over the selection.
            self.hudController.close()
            do {
                try await self.env.selection.replaceSelection(with: result)
            } catch {
                NSLog("AlembicRewrite: silent paste failed: \(error)")
            }

            // 6. Log history + fold cost.
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
            try? self.env.historyStore.add(entry)
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
            apiKey: apiKey,
            onUsage: { input, output in usage.set(input: input, output: output) }
        )

        do {
            for try await delta in stream {
                try Task.checkCancellation()
                model.appendToken(delta)
            }
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
            try? self.env.historyStore.add(entry)
            self.env.bumpRefresh()
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
        windows?.showOnboarding(env: env)
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
