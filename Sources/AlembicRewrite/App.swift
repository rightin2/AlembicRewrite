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

    func showSettings(env: AppEnvironment) {
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = SettingsView().environmentObject(env)
        let hosting = NSHostingController(rootView: root)
        let win = NSWindow(contentViewController: hosting)
        win.title = "Prompt Rewriter Settings"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showOnboarding(env: AppEnvironment) {
        if let win = onboardingWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let selection = env.selection
        let root = OnboardingView(
            onOpenSettings: { selection.openAccessibilitySettings() },
            onRecheck: { selection.hasAccessibilityPermission() },
            onDismiss: { [weak self] in
                self?.onboardingWindow?.close()
            }
        )
        let hosting = NSHostingController(rootView: root)
        let win = NSWindow(contentViewController: hosting)
        win.title = "Welcome to Prompt Rewriter"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.delegate = self
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

        // Seed the three built-in styles on a fresh install.
        try? env.styleStore.seedDefaultsIfEmpty()

        // First-launch bootstrap key import (advises rotation via a banner).
        if BootstrapKeyImporter.importIfNeeded(into: env.keychain) {
            env.setRotateBanner(true)
        }

        // Gate on the Accessibility permission the selection dance needs.
        if !env.selection.hasAccessibilityPermission() {
            windows.showOnboarding(env: env)
        }

        // Register the global palette hotkey (Cmd+Shift+R) and every per-style
        // direct hotkey, and re-sync per-style hotkeys whenever Settings closes.
        coordinator.registerHotkeys()
        windows.onSettingsClosed = { [weak coordinator] in
            coordinator?.syncStyleHotkeys()
        }
    }
}

// MARK: - Menu content

struct MenuContent: View {
    @ObservedObject var env: AppEnvironment
    let windows: WindowManager
    let coordinator: RewriteCoordinator

    var body: some View {
        // Cost-meter summary. Re-read on each render (NSMenu rebuilds on open).
        let cost = env.costMeter.totalCostUSD()
        let tokens = env.costMeter.totalTokens()

        Text(String(format: "Cost: $%.4f  •  %@ tokens",
                     cost, formattedTokens(tokens)))

        Button("Reset cost meter") {
            try? env.costMeter.reset()
            env.bumpRefresh()
        }

        Divider()

        Button("Rewrite Selection…") {
            coordinator.handleGlobalHotkey()
        }
        // .keyboardShortcut is intentionally omitted; the real trigger is the
        // global Carbon hotkey registered in AppDelegate.

        Divider()

        historyMenu

        Divider()

        Button("Settings…") {
            windows.showSettings(env: env)
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Quit Prompt Rewriter") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    @ViewBuilder
    private var historyMenu: some View {
        let entries = (try? env.historyStore.recent()) ?? []
        Menu("History") {
            if entries.isEmpty {
                Text("No rewrites yet")
            } else {
                ForEach(entries.prefix(10)) { entry in
                    Button(menuLabel(for: entry)) {
                        copyToClipboard(entry.result)
                    }
                }
            }
        }
    }

    private func menuLabel(for entry: HistoryEntry) -> String {
        let snippet = entry.result
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let clipped = snippet.count > 48 ? String(snippet.prefix(48)) + "…" : snippet
        return "\(entry.styleName): \(clipped)"
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
        .menuBarExtraStyle(.menu)
    }
}
