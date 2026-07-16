//
//  Onboarding.swift
//  AlembicRewrite
//
//  The resumable onboarding wizard (design section 7). A single 560x470 window
//  whose root content swaps between seven stages (welcome, permission, API key,
//  guided first rewrite, palette/panel tour, settings tour, finish). Progress is
//  persisted through OnboardingState (OnboardingFlow.swift), so quitting mid-flow
//  and relaunching resumes where the user left off.
//
//  The pure state machine and persistence live in OnboardingFlow.swift; this
//  file is only the view layer.
//
//  ---------------------------------------------------------------------------
//  INTEGRATION (App.swift, owned by the app-shell integrator, not this file)
//  ---------------------------------------------------------------------------
//  Three one-liners wire the wizard in. The legacy `OnboardingView` below is
//  kept only so the current App.swift compiles unchanged; swap these in to go
//  live, then delete `OnboardingView`.
//
//  1. WindowManager.showOnboarding gains a `startAt:` param, hides the title bar,
//     and hosts the wizard:
//
//        func showOnboarding(env: AppEnvironment, startAt: OnboardingStep = .welcome) {
//            if let win = onboardingWindow { win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
//            let root = OnboardingWizardView(
//                env: env,
//                startAt: startAt,
//                openSettings: { [weak self] in self?.showSettings(env: env) },
//                tryPalette: { [weak self] in self?.onTryPalette?() },   // wire to coordinator.handleGlobalHotkey
//                onClose: { [weak self] in self?.onboardingWindow?.close() }
//            )
//            let win = NSWindow(contentViewController: NSHostingController(rootView: root))
//            win.styleMask = [.titled, .closable]
//            win.titlebarAppearsTransparent = true
//            win.titleVisibility = .hidden
//            win.isMovableByWindowBackground = true
//            win.isReleasedWhenClosed = false
//            win.delegate = self
//            win.setContentSize(NSSize(width: 560, height: 470))
//            win.center()
//            onboardingWindow = win
//            win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
//        }
//
//  2. The App.swift launch gate (applicationDidFinishLaunching, replaces the
//     current `if !hasAccessibilityPermission() { showOnboarding }`) uses the
//     section-7.1 rule:
//
//        let onboarding = OnboardingState()
//        switch OnboardingFlow.launchOutcome(
//            satisfied: onboarding.isSatisfied,
//            granted: env.selection.hasAccessibilityPermission(),
//            lastStep: onboarding.lastStep
//        ) {
//        case .show(let step): windows.showOnboarding(env: env, startAt: step)
//        case .none: break
//        }
//
//     The RewriteCoordinator mid-flow trigger (hotkey with no permission) calls
//     windows?.showOnboarding(env: env, startAt: .permission).
//
//  INTEGRATION(onboarding-menu): add ONE item to MenuContent, above "Settings...",
//  that replays the walkthrough ignoring the completed flag:
//
//        Button("Replay setup walkthrough") {
//            windows.showOnboarding(env: env, startAt: .welcome)
//        }
//
//  ---------------------------------------------------------------------------
//

import SwiftUI
import AppKit

// MARK: - The wizard

/// The resumable onboarding wizard. Owns the current step as @State and drives
/// every transition through the pure `OnboardingFlow` helpers, persisting each
/// move via `OnboardingState`.
struct OnboardingWizardView: View {

    @ObservedObject var env: AppEnvironment
    let startAt: OnboardingStep

    /// Deep-link to the real Settings window (integrator: WindowManager).
    let openSettings: () -> Void
    /// Fire the real global palette hotkey over this window (integrator:
    /// RewriteCoordinator.handleGlobalHotkey).
    let tryPalette: () -> Void
    /// Close the wizard window (integrator: onboardingWindow.close).
    let onClose: () -> Void

    private let persistence = OnboardingState()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: OnboardingStep
    @State private var granted = false
    @State private var showGateNote = false

    // API key step
    @State private var anthropicField = ""
    @State private var openAIField = ""
    @State private var savedAnthropic = false
    @State private var savedOpenAI = false
    @State private var importedAnthropic = false

    // First-rewrite step
    @State private var sampleText = OnboardingWizardView.sampleSentence
    @State private var firstRewriteDone = false

    private static let sampleSentence =
        "write a short reminder to my team about tomorrow's deadline"

    init(
        env: AppEnvironment,
        startAt: OnboardingStep = .welcome,
        openSettings: @escaping () -> Void = {},
        tryPalette: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {}
    ) {
        self.env = env
        self.startAt = startAt
        self.openSettings = openSettings
        self.tryPalette = tryPalette
        self.onClose = onClose
        _step = State(initialValue: startAt)
    }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                header
                Divider().overlay(Color.hairline)
                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 28)
                    .padding(.top, 20)
                    .id(step)
                    .transition(stepTransition)
                footer
            }
        }
        .frame(width: 560, height: 470)
        .tint(Alembic.accent)
        .onAppear { recheckPermission(); loadKeys() }
    }

    // MARK: Frame furniture

    private var background: some View {
        // Behind-window glass so the wizard reads on the warm-dark wallpaper.
        GlassPanel(radius: 0) { Color.clear }
            .ignoresSafeArea()
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("Prompt Rewriter")
                .font(.alTitle)
                .foregroundStyle(Color.inkBase)
            Spacer()
            headerProgress
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var headerProgress: some View {
        switch step {
        case .settingsTour:
            Text("Settings tour, optional")
                .font(.alState).tracking(0.8).textCase(.uppercase)
                .foregroundStyle(Color.mutedBase)
                .padding(.vertical, 3).padding(.horizontal, 8)
                .background(Capsule().fill(Color.surface3))
        case .finish:
            EmptyView()
        default:
            HStack(spacing: 14) {
                if let n = step.coreNumber {
                    Text("Step \(n) of 4")
                        .font(.alState).tracking(0.8).textCase(.uppercase)
                        .foregroundStyle(Color.mutedBase)
                }
                progressRail
            }
        }
    }

    private var progressRail: some View {
        HStack(spacing: 7) {
            ForEach(1...4, id: \.self) { i in
                let filled = step.rawValue >= i
                Circle()
                    .fill(filled ? Alembic.accent : Color.clear)
                    .overlay(Circle().strokeBorder(filled ? Color.clear : Color.hairline, lineWidth: 1))
                    .frame(width: 8, height: 8)
            }
        }
    }

    // MARK: Content router

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:      welcomeStep
        case .permission:   permissionStep
        case .apiKey:       apiKeyStep
        case .firstRewrite: firstRewriteStep
        case .tour:         tourStep
        case .settingsTour: settingsTourStep
        case .finish:       finishStep
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if step != .finish && step != .settingsTour {
                Button(step == .welcome ? "Skip setup" : "Skip tour") { skipTour() }
                    .buttonStyle(.plain)
                    .font(.alButton)
                    .foregroundStyle(Color.mutedBase)
            }
            Spacer()
            if step.rawValue >= OnboardingStep.permission.rawValue && step.isCore {
                GlassButton("Back", style: .quiet) { go(to: OnboardingFlow.back(from: step)) }
            }
            primaryCTA
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var primaryCTA: some View {
        switch step {
        case .welcome:
            GlassButton("Get started", style: .primaryFlat) { go(to: .permission) }
        case .permission:
            GlassButton("Continue", style: .primaryFlat, disabled: !granted) { go(to: .apiKey) }
        case .apiKey:
            GlassButton("Continue", style: .primaryFlat, disabled: !hasAnyKey) { go(to: .firstRewrite) }
        case .firstRewrite:
            if hasAnyKey {
                GlassButton("Continue", style: .primaryFlat) { go(to: .tour) }
            } else {
                GlassButton("Skip this step", style: .smoke) { skipStep() }
            }
        case .tour:
            GlassButton("Finish setup", style: .primaryFlat) { go(to: .settingsTour) }
        case .settingsTour:
            GlassButton("Open Settings", style: .primaryFlat) {
                openSettings(); go(to: .finish)
            }
        case .finish:
            GlassButton("Start using Prompt Rewriter", style: .primaryLiquid, large: true) {
                persistence.markCompleted(); onClose()
            }
        }
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 40))
                .foregroundStyle(Alembic.accent)
            Text("Welcome to Prompt Rewriter")
                .font(.alTitleLg)
                .foregroundStyle(Color.inkBase)
            Text("Prompt Rewriter rewrites whatever text you have selected, in any app, using styles you control. This quick walkthrough gets you set up in about a minute.")
                .font(.alBody)
                .foregroundStyle(Color.inkBase)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("What you'll set up")
                setupItem("1", "Grant the Accessibility permission")
                setupItem("2", "Add an API key")
                setupItem("3", "Try your first rewrite")
            }
            Spacer(minLength: 0)
        }
    }

    private func setupItem(_ n: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "\(n).circle.fill")
                .foregroundStyle(Alembic.accent)
            Text(text).font(.alBody).foregroundStyle(Color.inkBase)
        }
    }

    // MARK: - Step 1: Accessibility permission

    private var permissionStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Grant Accessibility")
                    .font(.alTitleLg)
                    .foregroundStyle(Color.inkBase)
                Spacer()
                StatusBadge(granted ? .ready : .empty,
                            text: granted ? "Permission granted" : "Not granted")
            }

            if showGateNote && !granted {
                Text("Grant Accessibility first. It is the one permission Prompt Rewriter cannot run without.")
                    .font(.alBody)
                    .foregroundStyle(Color.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("To read your selection and paste a rewrite back, macOS needs to grant Prompt Rewriter the Accessibility permission.")
                .font(.alBody)
                .foregroundStyle(Color.inkBase)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                permissionNumberedItem("1", "Click Open System Settings below.")
                permissionNumberedItem("2", "Enable Prompt Rewriter under Accessibility.")
                permissionNumberedItem("3", "Come back here and click Re-check.")
            }

            HStack(spacing: 10) {
                GlassButton("Open System Settings", style: .primaryFlat) {
                    env.selection.openAccessibilitySettings()
                    recheckPermission()
                }
                GlassButton("Re-check", style: .smoke) { recheckPermission() }
            }

            if granted {
                Label("Permission granted", systemImage: "checkmark.seal.fill")
                    .font(.alBody)
                    .foregroundStyle(Alembic.accent)
            }
            Spacer(minLength: 0)
        }
        .onAppear { recheckPermission() }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            if step == .permission { recheckPermission() }
        }
    }

    private func permissionNumberedItem(_ n: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "\(n).circle")
                .foregroundStyle(Color.mutedBase)
            Text(text).font(.alBody).foregroundStyle(Color.inkBase)
        }
    }

    // MARK: - Step 2: API key

    private var apiKeyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add an API key")
                .font(.alTitleLg)
                .foregroundStyle(Color.inkBase)
            Text("Prompt Rewriter uses your own key. It is stored in your macOS Keychain and never leaves this machine. Add at least one to continue.")
                .font(.alBody)
                .foregroundStyle(Color.inkBase)
                .fixedSize(horizontal: false, vertical: true)

            ProviderKeyRow(
                title: "Anthropic",
                saved: savedAnthropic,
                importedCaption: importedAnthropic,
                field: $anthropicField,
                onSave: { saveKey(.anthropic) },
                onRemove: { removeKey(.anthropic) }
            )
            ProviderKeyRow(
                title: "OpenAI",
                saved: savedOpenAI,
                importedCaption: false,
                field: $openAIField,
                onSave: { saveKey(.openai) },
                onRemove: { removeKey(.openai) }
            )

            Button("I'll add this later") { skipStep() }
                .buttonStyle(.plain)
                .font(.alButton)
                .foregroundStyle(Color.mutedBase)
            Spacer(minLength: 0)
        }
        .onAppear { loadKeys() }
    }

    // MARK: - Step 3: Guided first rewrite

    private var firstRewriteStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Try your first rewrite")
                .font(.alTitleLg)
                .foregroundStyle(Color.inkBase)
            Text("Select the sample line below, then press the AlembicRewriter hotkey. Prompt Rewriter reads the selection, rewrites it, and pastes the result straight back in place.")
                .font(.alBody)
                .foregroundStyle(Color.inkBase)
                .fixedSize(horizontal: false, vertical: true)

            InputField("Sample text", text: $sampleText, multiline: true, minHeight: 64)
                .textSelection(.enabled)
                .disabled(!hasAnyKey)
                .opacity(hasAnyKey ? 1 : 0.5)

            HStack(spacing: 12) {
                keyCap(rewriterHotkey, fallback: "\u{2318}\u{21e7}R")
                    .opacity(hasAnyKey ? 1 : 0.4)
                outcomeStrip
            }

            if !hasAnyKey {
                HStack(spacing: 10) {
                    Text("Add an API key to try this")
                        .font(.alBody).foregroundStyle(Color.mutedBase)
                    GlassButton("Back to keys", style: .smoke) { go(to: .apiKey) }
                }
            }
            Spacer(minLength: 0)
        }
        .onChange(of: env.refreshToken) { _ in
            // A silent rewrite completed (history + cost were logged). This is the
            // real, user-visible signal that the sample was rewritten in place.
            if step == .firstRewrite { firstRewriteDone = true }
        }
    }

    @ViewBuilder
    private var outcomeStrip: some View {
        if firstRewriteDone {
            Label("Done. The line above was rewritten in place.",
                  systemImage: "checkmark.seal.fill")
                .font(.alBody)
                .foregroundStyle(Alembic.accent)
        } else {
            Text("Waiting for your first rewrite...")
                .font(.alBody)
                .foregroundStyle(Color.mutedBase)
        }
    }

    // MARK: - Step 4: Palette + review tour

    private var tourStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Two ways to rewrite")
                .font(.alTitleLg)
                .foregroundStyle(Color.inkBase)

            paletterPreview
            reviewPreview

            GlassButton("Try the palette now", style: .quiet) { tryPalette() }
            Spacer(minLength: 0)
        }
    }

    private var paletterPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassPanel(radius: AlembicMetrics.r2) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Color.mutedBase)
                        Text("Filter styles...").font(.alBody).foregroundStyle(Color.mutedBase)
                    }
                    previewRow("AlembicRewriter", selected: true)
                    previewRow("Make concise", selected: false)
                }
                .padding(10)
            }
            Text("Press Cmd+Shift+E anywhere. Type to filter your styles, press Return to run the highlighted one,")
                .font(.alBody).foregroundStyle(Color.mutedBase)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var reviewPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassPanel(radius: AlembicMetrics.r2) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        previewPane("ORIGINAL")
                        previewPane("REWRITE")
                    }
                    HStack(spacing: 8) {
                        Spacer()
                        miniButton("Cancel", tint: Color.surface3, fg: Color.inkBase)
                        miniButton("Retry", tint: Color.surface3, fg: Color.inkBase)
                        miniButton("Accept", tint: Alembic.gold, fg: Color.warningText)
                    }
                }
                .padding(10)
            }
            Text("Any style set to review opens this first.")
                .font(.alBody).foregroundStyle(Color.mutedBase)
        }
    }

    private func previewRow(_ name: String, selected: Bool) -> some View {
        HStack {
            Text(name).font(.alBody).foregroundStyle(selected ? .white : Color.inkBase)
            Spacer()
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: AlembicMetrics.r1, style: .continuous)
                .fill(selected ? Alembic.accent : Color.clear)
        )
    }

    private func previewPane(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.alState).tracking(0.8).foregroundStyle(Color.mutedBase)
            RoundedRectangle(cornerRadius: AlembicMetrics.r1, style: .continuous)
                .fill(Color.inputBg)
                .frame(height: 34)
        }
        .frame(maxWidth: .infinity)
    }

    private func miniButton(_ title: String, tint: Color, fg: Color) -> some View {
        Text(title)
            .font(.alButton).foregroundStyle(fg)
            .padding(.vertical, 4).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: AlembicMetrics.r1, style: .continuous).fill(tint))
    }

    // MARK: - Step 5: Settings tour

    private var settingsTourStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What you can tune later")
                .font(.alTitleLg)
                .foregroundStyle(Color.inkBase)
            Text("Ten settings converge everything worth controlling. Here is the map; open Settings any time from the menu bar.")
                .font(.alBody).foregroundStyle(Color.inkBase)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    settingsGroup("Everyday defaults", Self.everydayDefaults)
                    settingsGroup("Spending controls", Self.spendingControls)
                    settingsGroup("Safety and undo", Self.safetyAndUndo)
                    settingsGroup("Privacy", Self.privacy)
                }
                .padding(.bottom, 4)
            }

            Button("Dismiss") { go(to: .finish) }
                .buttonStyle(.plain)
                .font(.alButton)
                .foregroundStyle(Color.mutedBase)
        }
    }

    private func settingsGroup(_ title: String, _ rows: [(String, String)]) -> some View {
        GlassPanel(radius: AlembicMetrics.r2) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title)
                ForEach(rows, id: \.0) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.0).font(.alBody).bold().foregroundStyle(Color.inkBase)
                        Text(row.1).font(.alBody).foregroundStyle(Color.mutedBase)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
        }
    }

    // The ten consensus settings (design 3.1-3.10), grouped per 7.3. Names match
    // the design section 3 headings so they line up with AppSettings when it lands.
    private static let everydayDefaults: [(String, String)] = [
        ("Global palette hotkey", "Rebind the shortcut that opens the style palette."),
        ("Model picker", "Choose each style's model from a known-models registry."),
        ("Per-style max output tokens", "Cap how long each rewrite can run."),
        ("Defaults for new styles", "Set the provider, model, and tone new styles start from."),
        ("Australian English and no dashes", "Enforce AU spelling and strip em and en dashes."),
    ]
    private static let spendingControls: [(String, String)] = [
        ("Monthly spend cap", "Warn near a limit and hard-stop at it."),
    ]
    private static let safetyAndUndo: [(String, String)] = [
        ("Large-selection guard", "Confirm before rewriting very long selections."),
        ("Undo and restore original", "Put the original text back after a paste."),
    ]
    private static let privacy: [(String, String)] = [
        ("History retention and purge", "Choose how long rewrites are kept, and clear them."),
        ("Accessibility status", "See the permission state and re-grant it here."),
    ]

    // MARK: - Step 6: Finish

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundStyle(Alembic.accent)
            Text("You're all set")
                .font(.alTitleLg)
                .foregroundStyle(Color.inkBase)

            GlassPanel(radius: AlembicMetrics.r2) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader("Hotkey cheat sheet")
                    cheatRow(paletteHotkey, "\u{2318}\u{21e7}E", "open the palette")
                    cheatRow(rewriterHotkey, "\u{2318}\u{21e7}R", "AlembicRewriter silent")
                    HStack(spacing: 10) {
                        Image(systemName: "menubar.arrow.up.rectangle").foregroundStyle(Color.mutedBase)
                        Text("Menu bar icon").font(.alBody).bold().foregroundStyle(Color.inkBase)
                        Text("settings, history, cost").font(.alBody).foregroundStyle(Color.mutedBase)
                    }
                }
                .padding(12)
            }

            Text("You can replay this walkthrough any time from Help,")
                .font(.alState).foregroundStyle(Color.mutedBase)
            Spacer(minLength: 0)
        }
        .onAppear { persistence.markCompleted() }
    }

    private func cheatRow(_ hotkey: Hotkey?, _ fallback: String, _ label: String) -> some View {
        HStack(spacing: 10) {
            keyCap(hotkey, fallback: fallback)
            Text(label).font(.alBody).foregroundStyle(Color.inkBase)
        }
    }

    // MARK: - Shared key-cap

    private func keyCap(_ hotkey: Hotkey?, fallback: String) -> some View {
        Group {
            if let hotkey {
                HotkeyGlyph(hotkey, color: Color.inkBase)
            } else {
                Text(fallback).font(.alMono).foregroundStyle(Color.inkBase)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: AlembicMetrics.r1, style: .continuous)
                .fill(Color.surface3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AlembicMetrics.r1, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 1)
        )
    }

    // MARK: - Transitions and persistence

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 8)),
            removal: .opacity
        )
    }

    private func go(to newStep: OnboardingStep) {
        if newStep == step { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            step = newStep
        }
        if newStep != .finish { persistence.recordStep(newStep) }
        if newStep != .permission { showGateNote = false }
    }

    private func skipStep() {
        guard let next = OnboardingFlow.skipStep(from: step) else { return }
        go(to: next)
    }

    private func skipTour() {
        let out = OnboardingFlow.skipTour(granted: granted)
        showGateNote = out.showGateNote
        go(to: out.target)
        // go(to:) clears showGateNote for non-permission targets; re-apply for the
        // gated case since the target IS permission.
        if out.showGateNote { showGateNote = true }
    }

    // MARK: - Live conditions

    private var hasAnyKey: Bool { savedAnthropic || savedOpenAI }

    private func recheckPermission() {
        granted = env.selection.hasAccessibilityPermission()
        if granted { showGateNote = false }
    }

    private var paletteHotkey: Hotkey? { HotkeyManager.defaultGlobalHotkey }

    private var rewriterHotkey: Hotkey? {
        (try? env.styleStore.all())?
            .first(where: { $0.name == "AlembicRewriter" })?
            .hotkey
    }

    // MARK: - Keychain plumbing

    private func loadKeys() {
        savedAnthropic = keyExists(.anthropic)
        savedOpenAI = keyExists(.openai)
        // A bootstrap-imported Anthropic key shows as saved with an "imported" note.
        importedAnthropic = savedAnthropic && env.showRotateKeyBanner
    }

    private func keyExists(_ provider: Provider) -> Bool {
        ((try? env.keychain.key(for: provider)) ?? nil)?.isEmpty == false
    }

    private func saveKey(_ provider: Provider) {
        let field = provider == .anthropic ? anthropicField : openAIField
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? env.keychain.setKey(trimmed, for: provider)
        if provider == .anthropic { anthropicField = "" } else { openAIField = "" }
        loadKeys()
    }

    private func removeKey(_ provider: Provider) {
        try? env.keychain.deleteKey(for: provider)
        if provider == .anthropic { env.setRotateBanner(false) }
        loadKeys()
    }
}

// MARK: - Provider key row (Step 2)

/// One provider's hairline-bordered API-key card: name + saved dot, a masked
/// field with Save, a green Saved tick and Remove when a key already exists.
private struct ProviderKeyRow: View {
    let title: String
    let saved: Bool
    let importedCaption: Bool
    @Binding var field: String
    let onSave: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: saved ? "key.fill" : "key")
                    .foregroundStyle(saved ? Alembic.accent : Color.mutedBase)
                Text(title).font(.alBody).bold().foregroundStyle(Color.inkBase)
                if saved {
                    Text("key saved").font(.alState).foregroundStyle(Color.mutedBase)
                }
                if importedCaption {
                    Text("imported").font(.alState).foregroundStyle(Color.mutedBase)
                }
                Spacer()
                if saved {
                    Label("Saved", systemImage: "checkmark").font(.alState).foregroundStyle(Alembic.accent)
                }
            }
            HStack(spacing: 8) {
                InputField("API key", text: $field, secure: true)
                GlassButton("Save", style: .primaryFlat,
                            disabled: field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    onSave()
                }
                if saved {
                    GlassButton("Remove", style: .danger) { onRemove() }
                }
            }
        }
        .padding(12)
        .overlay(
            RoundedRectangle(cornerRadius: AlembicMetrics.r2, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 1)
        )
    }
}

// MARK: - Legacy view (kept only so the current App.swift compiles)

/// Deprecated permission-only onboarding screen. The current App.swift still
/// constructs this; the integrator replaces the showOnboarding body with
/// `OnboardingWizardView` (see the INTEGRATION block at the top of this file)
/// and then this type can be deleted.
public struct OnboardingView: View {
    private let onOpenSettings: () -> Void
    private let onRecheck: () -> Bool
    private let onDismiss: () -> Void
    @State private var granted = false

    public init(
        onOpenSettings: @escaping () -> Void = {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        },
        onRecheck: @escaping () -> Bool = { false },
        onDismiss: @escaping () -> Void = {}
    ) {
        self.onOpenSettings = onOpenSettings
        self.onRecheck = onRecheck
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 34))
                    .foregroundStyle(Alembic.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Prompt Rewriter")
                        .font(.alembicDisplay(22, weight: .semibold))
                        .foregroundStyle(Alembic.ink)
                    Text("One quick permission and you're set.")
                        .foregroundStyle(.secondary)
                }
            }

            Text("Prompt Rewriter rewrites whatever text you have selected in any app. To read your selection and paste the result back, macOS needs to grant it the Accessibility permission.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Label("Click Open System Settings below.", systemImage: "1.circle")
                Label("Enable Prompt Rewriter under Accessibility.", systemImage: "2.circle")
                Label("Come back here and click Re-check.", systemImage: "3.circle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if granted {
                Label("Permission granted. You're ready to go.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Alembic.accent)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Open System Settings") { onOpenSettings() }
                    .buttonStyle(.borderedProminent)
                Button("Re-check") { granted = onRecheck() }
                Spacer()
                Button(granted ? "Done" : "Later") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460, height: 340)
        .tint(Alembic.accent)
        .onAppear { granted = onRecheck() }
    }
}
