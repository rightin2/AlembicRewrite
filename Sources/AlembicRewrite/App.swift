//
//  App.swift
//  AlembicRewrite
//
//  @main entry point. Menu-bar-only app (LSUIElement-style) via MenuBarExtra.
//
//  Owns: the shared AppEnvironment (concrete stores), the menu-bar dropdown
//  (cost-meter summary, History submenu, Settings, Quit), window management for
//  the Settings and Onboarding windows, first-launch seeding, bootstrap-key
//  import, and the Accessibility onboarding gate.
//
//  INTEGRATION POINTS for the capture -> palette -> panel flow are marked with
//  `// INTEGRATION:` comments below. Everything the integrator needs (stores,
//  selection service, hotkey manager, keychain) is reachable via AppEnvironment.
//

import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Bundled icon loading

/// Loads the bundled app + menu-bar icons via `Bundle.module`. Every accessor
/// fails soft (returns nil) if the resource is absent, so callers keep their
/// SF Symbol / system-default fallbacks.
enum AppIcons {
    /// The Dock / application icon (`AppIcon.icns`).
    static func appIcon() -> NSImage? {
        guard let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    /// The menu-bar status icon, built from the 1x + 2x PNGs and rendered as a
    /// template so it adapts to light/dark menu bars. Base logical size ~18pt.
    static func menuBarIcon() -> NSImage? {
        guard let base = loadPNG("MenuBarIcon") else { return nil }
        if let retina = loadPNG("MenuBarIcon@2x"),
           let rep = retina.representations.first {
            base.addRepresentation(rep)
        }
        base.size = NSSize(width: 18, height: 18)
        base.isTemplate = true
        return base
    }

    private static func loadPNG(_ name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}

// MARK: - Shared environment

/// Single container for every concrete store and service. Instantiated once in
/// the AppDelegate and handed to the menu, the settings window, and (via the
/// same instance) the integrator's capture/palette/panel flow.
@MainActor
final class AppEnvironment: ObservableObject {
    let styleStore: StyleStoring
    let historyStore: HistoryStoring
    let costMeter: CostMetering
    let keychain: KeychainStoring
    let selection: SelectionServicing
    let hotkeys: HotkeyManaging

    /// Bumped whenever the menu should re-read the stores (cost, history).
    @Published var refreshToken = UUID()

    /// True after the bootstrap `.secrets/anthropic-key` file was imported into
    /// the Keychain on first launch. Drives the "rotate this key" banner in the
    /// API Keys tab. Persisted so the advice survives until the user dismisses.
    @Published var showRotateKeyBanner: Bool

    init(
        styleStore: StyleStoring = StyleStore(),
        historyStore: HistoryStoring = HistoryStore(),
        costMeter: CostMetering = CostMeter(),
        keychain: KeychainStoring = KeychainStore(),
        selection: SelectionServicing = SelectionService(),
        hotkeys: HotkeyManaging = HotkeyManager()
    ) {
        self.styleStore = styleStore
        self.historyStore = historyStore
        self.costMeter = costMeter
        self.keychain = keychain
        self.selection = selection
        self.hotkeys = hotkeys
        self.showRotateKeyBanner = UserDefaults.standard.bool(forKey: Self.rotateBannerKey)
    }

    static let rotateBannerKey = "AlembicRewrite.showRotateKeyBanner"

    func setRotateBanner(_ on: Bool) {
        showRotateKeyBanner = on
        UserDefaults.standard.set(on, forKey: Self.rotateBannerKey)
    }

    func bumpRefresh() { refreshToken = UUID() }
}

// MARK: - Window management

/// Owns the two auxiliary NSWindows (Settings, Onboarding). A menu-bar-only app
/// has no default window, so we build and retain them here.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    /// Called after the Settings window closes so the coordinator can re-sync
    /// per-style hotkeys (styles may have been added, edited, or deleted).
    var onSettingsClosed: (() -> Void)?

    /// Fires the real global palette hotkey from the onboarding "try it" step
    /// (wired to `RewriteCoordinator.handleGlobalHotkey`).
    var onTryPalette: (() -> Void)?

    func showSettings(env: AppEnvironment) {
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = SettingsView().environmentObject(env)
        let hosting = NSHostingController(rootView: root)
        let win = NSWindow(contentViewController: hosting)
        win.title = "AlembicRewrite Settings"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showOnboarding(env: AppEnvironment, startAt: OnboardingStep = .welcome) {
        if let win = onboardingWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = OnboardingWizardView(
            env: env,
            startAt: startAt,
            openSettings: { [weak self] in self?.showSettings(env: env) },
            tryPalette: { [weak self] in self?.onTryPalette?() },
            onClose: { [weak self] in self?.onboardingWindow?.close() }
        )
        let hosting = NSHostingController(rootView: root)
        let win = NSWindow(contentViewController: hosting)
        win.styleMask = [.titled, .closable]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.setContentSize(NSSize(width: 560, height: 540))
        win.center()
        onboardingWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow else { return }
        if win == settingsWindow {
            settingsWindow = nil
            onSettingsClosed?()
        }
        if win == onboardingWindow { onboardingWindow = nil }
    }
}

// MARK: - App delegate (launch wiring)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let env = AppEnvironment()
    let windows = WindowManager()
    lazy var coordinator = RewriteCoordinator(env: env, windows: windows)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set the Dock/app icon at runtime. A bare SPM executable has no
        // Info.plist, so we load the bundled .icns and assign it directly.
        // Fails soft: if the resource is missing, the system default is kept.
        if let icon = AppIcons.appIcon() {
            NSApp.applicationIconImage = icon
        }

        // Seed the built-in styles on a fresh install, then run the one-time
        // migration that adds "AlembicRewriter" to installs seeded before it
        // existed (no-op once present).
        try? env.styleStore.seedDefaultsIfEmpty()
        try? env.styleStore.migrateAlembicRewriterIfMissing()

        // First-launch bootstrap key import (advises rotation via a banner).
        if BootstrapKeyImporter.importIfNeeded(into: env.keychain) {
            env.setRotateBanner(true)
        }

        // First-run onboarding gate (design 7.1): resume an unfinished wizard,
        // jump straight to the permission step when onboarding is done but the
        // permission has since dropped, or stay menu-bar-only when all is well.
        let onboarding = OnboardingState()
        switch OnboardingFlow.launchOutcome(
            satisfied: onboarding.isSatisfied,
            granted: env.selection.hasAccessibilityPermission(),
            lastStep: onboarding.lastStep
        ) {
        case .show(let step):
            windows.showOnboarding(env: env, startAt: step)
        case .none:
            break
        }

        // Register the global palette hotkey and every per-style direct hotkey,
        // and re-sync per-style hotkeys whenever Settings closes. The onboarding
        // "try it" step fires the same global palette trigger.
        coordinator.registerHotkeys()
        windows.onSettingsClosed = { [weak coordinator] in
            coordinator?.syncStyleHotkeys()
        }
        windows.onTryPalette = { [weak coordinator] in
            coordinator?.handleGlobalHotkey()
        }
    }

    /// Honour history clear-on-quit and the session-only retention mode (setting
    /// 3.4) as the app terminates.
    func applicationWillTerminate(_ notification: Notification) {
        let prefs = AppSettings.shared.prefs
        if prefs.clearHistoryOnQuit || prefs.historyMode == .session {
            try? env.historyStore.clear()
        }
    }
}

// MARK: - Menu content

struct MenuContent: View {
    @ObservedObject var env: AppEnvironment
    let windows: WindowManager
    let coordinator: RewriteCoordinator

    var body: some View {
        // `env` is observed, so the coordinator's `bumpRefresh()` after each
        // rewrite re-renders this window live, even while it is open (F4). The
        // stores are re-read on every render.
        GlassPanel(radius: AlembicMetrics.r3, material: .popover) {
            VStack(alignment: .leading, spacing: 14) {
                spendCard
                GlassButton("Rewrite Selection",
                            style: .primaryFlat,
                            large: true,
                            trailingGlyph: HotkeyGlyph.string(for: HotkeyManager.defaultGlobalHotkey)) {
                    coordinator.handleGlobalHotkey()
                }
                .frame(maxWidth: .infinity)
                historySection
                navSection
            }
            .padding(16)
        }
        .frame(width: 300)
        .tint(Alembic.accent)
    }

    // MARK: Spend

    private var spendCard: some View {
        let cost = env.costMeter.totalCostUSD()
        let tokens = env.costMeter.totalTokens()
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionHeader("Spend")
                Spacer()
                GlassButton("Reset", style: .quiet) {
                    try? env.costMeter.reset()
                    env.bumpRefresh()
                }
            }
            Text(String(format: "$%.4f", cost))
                .font(.alTitleLg)
                .foregroundStyle(Color.inkBase)
            Text("\(formattedTokens(tokens)) tokens")
                .font(.alState)
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Color.mutedBase)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: AlembicMetrics.r2, style: .continuous)
                .fill(Color.surface3.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AlembicMetrics.r2, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: AlembicMetrics.hairline)
        )
    }

    // MARK: History

    @ViewBuilder
    private var historySection: some View {
        let entries = (try? env.historyStore.recent()) ?? []
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionHeader("History")
                Spacer()
                if !entries.isEmpty {
                    GlassButton("Clear", style: .quiet) {
                        try? env.historyStore.clear()
                        env.bumpRefresh()
                    }
                }
            }
            if entries.isEmpty {
                Text("No rewrites yet")
                    .font(.alBody)
                    .foregroundStyle(Color.mutedBase)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(entries.prefix(10)) { entry in
                            GlassListRow {
                                historyRow(entry)
                            }
                            .onTapGesture { copyToClipboard(entry.result) }
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.styleName)
                    .font(.alBody)
                    .foregroundStyle(Color.inkBase)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(timestamp(entry.timestamp))
                    .font(.alState)
                    .tracking(0.6)
                    .foregroundStyle(Color.mutedBase)
            }
            Text(snippet(entry.result))
                .font(.alState)
                .tracking(0.4)
                .foregroundStyle(Color.mutedBase)
                .lineLimit(1)
            Text("\(entry.inputTokens + entry.outputTokens) tokens")
                .font(.alState)
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(Color.mutedBase.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Click to copy the result")
    }

    // MARK: Navigation

    private var navSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Rectangle()
                .fill(Color.hairline)
                .frame(height: AlembicMetrics.hairline)
                .padding(.bottom, 6)
            // Undo the last rewrite (setting 3.7). Shown only while the stashed
            // original is still inside its undo window.
            if coordinator.canUndo {
                GlassButton("Undo last rewrite", style: .quiet) {
                    coordinator.undoLastRewrite()
                    env.bumpRefresh()
                }
            }
            GlassButton("Replay setup walkthrough", style: .quiet) {
                windows.showOnboarding(env: env, startAt: .welcome)
            }
            GlassButton("Settings", style: .quiet) {
                windows.showSettings(env: env)
            }
            GlassButton("Quit AlembicRewrite", style: .quiet) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    // MARK: Helpers

    private func snippet(_ text: String) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count > 48 ? String(flat.prefix(48)) + "…" : flat
    }

    private func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM, h:mm a"
        return f.string(from: date)
    }

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func formattedTokens(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

// MARK: - App

@main
struct AlembicRewriteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(
                env: appDelegate.env,
                windows: appDelegate.windows,
                coordinator: appDelegate.coordinator
            )
        } label: {
            // Bundled Alembic menu-bar glyph (template-rendered so it adapts to
            // light/dark bars). Falls back to the SF Symbol if the resource is
            // missing.
            if let icon = AppIcons.menuBarIcon() {
                Image(nsImage: icon)
            } else {
                Image(systemName: "wand.and.stars")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
