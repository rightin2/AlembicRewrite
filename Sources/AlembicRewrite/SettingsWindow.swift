//
//  SettingsWindow.swift
//  AlembicRewrite
//
//  Settings window with three tabs:
//    General  — launch at login (SMAppService), global-hotkey description.
//    API Keys — two secure fields saving to the Keychain; first-launch import
//               banner advising the user to rotate the bootstrap key.
//    Styles   — full CRUD + reorder over StyleStoring, with an editor form for
//               every Style field including an optional per-style hotkey.
//

import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Root

public struct SettingsView: View {
    @EnvironmentObject var env: AppEnvironment

    public init() {}

    public var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            APIKeysTab()
                .tabItem { Label("API Keys", systemImage: "key") }
            StylesTab()
                .tabItem { Label("Styles", systemImage: "square.stack") }
        }
        .frame(width: 620, height: 480)
    }
}

// MARK: - General tab

struct GeneralTab: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch Prompt Rewriter at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            // Revert the toggle if the service call failed.
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section("Global hotkey") {
                LabeledContent("Open style palette") {
                    Text("⌘⇧R")
                        .font(.system(.body, design: .monospaced))
                }
                Text("The global hotkey opens the style palette over your current selection. Recording a custom hotkey is not yet wired up in v1; the default is Command-Shift-R.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - API Keys tab

struct APIKeysTab: View {
    @EnvironmentObject var env: AppEnvironment

    @State private var anthropicKey = ""
    @State private var openaiKey = ""
    @State private var anthropicSaved = false
    @State private var openaiSaved = false

    var body: some View {
        Form {
            if env.showRotateKeyBanner {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Bootstrap key imported")
                                .font(.headline)
                            Text("An Anthropic key from .secrets/anthropic-key was imported into your Keychain on first launch. That key was exposed in chat — rotate it in the Anthropic console and paste the new key below.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("Dismiss") { env.setRotateBanner(false) }
                                .controlSize(.small)
                        }
                        Spacer()
                    }
                }
            }

            Section("Anthropic") {
                SecureField("sk-ant-…", text: $anthropicKey)
                HStack {
                    Button("Save") { save(.anthropic, key: anthropicKey, saved: &anthropicSaved) }
                        .disabled(anthropicKey.isEmpty)
                    if anthropicSaved {
                        Label("Saved to Keychain", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.footnote)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) {
                        try? env.keychain.deleteKey(for: .anthropic)
                        anthropicKey = ""
                        anthropicSaved = false
                    }
                    .controlSize(.small)
                }
            }

            Section("OpenAI") {
                SecureField("sk-…", text: $openaiKey)
                HStack {
                    Button("Save") { save(.openai, key: openaiKey, saved: &openaiSaved) }
                        .disabled(openaiKey.isEmpty)
                    if openaiSaved {
                        Label("Saved to Keychain", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.footnote)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) {
                        try? env.keychain.deleteKey(for: .openai)
                        openaiKey = ""
                        openaiSaved = false
                    }
                    .controlSize(.small)
                }
            }

            Section {
                Text("Keys are stored only in the macOS Keychain and are sent solely to their provider's API. There is no telemetry.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear(perform: loadExisting)
    }

    private func loadExisting() {
        if let k = (try? env.keychain.key(for: .anthropic)) ?? nil, !k.isEmpty {
            anthropicKey = k
            anthropicSaved = true
        }
        if let k = (try? env.keychain.key(for: .openai)) ?? nil, !k.isEmpty {
            openaiKey = k
            openaiSaved = true
        }
    }

    private func save(_ provider: Provider, key: String, saved: inout Bool) {
        do {
            try env.keychain.setKey(key, for: provider)
            saved = true
        } catch {
            saved = false
        }
    }
}

// MARK: - Styles tab

struct StylesTab: View {
    @EnvironmentObject var env: AppEnvironment

    @State private var styles: [Style] = []
    @State private var selectedID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            styleList
                .frame(width: 220)
            Divider()
            editorPane
        }
        .onAppear(perform: reload)
    }

    private var styleList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(styles) { style in
                    Text(style.name.isEmpty ? "Untitled" : style.name)
                        .tag(style.id)
                }
                .onMove(perform: move)
            }

            Divider()

            HStack {
                Button(action: addStyle) {
                    Image(systemName: "plus")
                }
                Button(action: deleteSelected) {
                    Image(systemName: "minus")
                }
                .disabled(selectedID == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
    }

    @ViewBuilder
    private var editorPane: some View {
        if let index = selectedIndex {
            StyleEditor(
                style: Binding(
                    get: { styles[index] },
                    set: { styles[index] = $0 }
                ),
                onSave: { saveStyle(styles[index]) }
            )
            .id(styles[index].id)
        } else {
            VStack {
                Spacer()
                Text("Select a style, or add one with +")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var selectedIndex: Int? {
        guard let id = selectedID else { return nil }
        return styles.firstIndex { $0.id == id }
    }

    // MARK: store operations

    private func reload() {
        styles = (try? env.styleStore.all()) ?? []
        if selectedID == nil { selectedID = styles.first?.id }
    }

    private func saveStyle(_ style: Style) {
        try? env.styleStore.save(style)
    }

    private func addStyle() {
        let nextOrder = (styles.map(\.sortOrder).max() ?? -1) + 1
        let new = Style(
            name: "New Style",
            promptTemplate: "Rewrite the following text.\n\n{{selection}}",
            provider: .anthropic,
            model: "claude-3-5-sonnet-latest",
            temperature: 0.7,
            sortOrder: nextOrder
        )
        try? env.styleStore.save(new)
        reload()
        selectedID = new.id
    }

    private func deleteSelected() {
        guard let id = selectedID else { return }
        try? env.styleStore.delete(id: id)
        reload()
        selectedID = styles.first?.id
    }

    private func move(from source: IndexSet, to destination: Int) {
        styles.move(fromOffsets: source, toOffset: destination)
        for i in styles.indices { styles[i].sortOrder = i }
        try? env.styleStore.reorder(styles)
    }
}

// MARK: - Style editor form

struct StyleEditor: View {
    @Binding var style: Style
    let onSave: () -> Void

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $style.name)
            }

            Section("Prompt template") {
                TextEditor(text: $style.promptTemplate)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                Text("Use {{selection}} where the captured text should be inserted.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Model") {
                Picker("Provider", selection: $style.provider) {
                    ForEach(Provider.allCases, id: \.self) { p in
                        Text(p == .anthropic ? "Anthropic" : "OpenAI").tag(p)
                    }
                }
                TextField("Model identifier", text: $style.model)
                HStack {
                    Text("Temperature")
                    Slider(value: $style.temperature, in: 0...2, step: 0.05)
                    Text(String(format: "%.2f", style.temperature))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 44, alignment: .trailing)
                }
            }

            Section("Direct hotkey (optional)") {
                HotkeyField(hotkey: $style.hotkey)
            }

            Section {
                Button("Save") { onSave() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Hotkey field

/// A minimal per-style hotkey editor for v1: modifier toggles plus a single
/// key character. Converts to/from the Carbon-flavoured `Hotkey` value. A full
/// key-capture recorder is deferred.
struct HotkeyField: View {
    @Binding var hotkey: Hotkey?

    @State private var enabled = false
    @State private var useCommand = true
    @State private var useShift = true
    @State private var useOption = false
    @State private var useControl = false
    @State private var keyCharacter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Assign a direct hotkey", isOn: $enabled)
                .onChange(of: enabled) { _, on in if !on { hotkey = nil } else { rebuild() } }

            if enabled {
                HStack(spacing: 12) {
                    Toggle("⌘", isOn: $useCommand).onChange(of: useCommand) { _, _ in rebuild() }
                    Toggle("⇧", isOn: $useShift).onChange(of: useShift) { _, _ in rebuild() }
                    Toggle("⌥", isOn: $useOption).onChange(of: useOption) { _, _ in rebuild() }
                    Toggle("⌃", isOn: $useControl).onChange(of: useControl) { _, _ in rebuild() }
                }
                .toggleStyle(.button)

                TextField("Key (single letter or digit)", text: $keyCharacter)
                    .frame(width: 220)
                    .onChange(of: keyCharacter) { _, new in
                        if new.count > 1 { keyCharacter = String(new.suffix(1)) }
                        rebuild()
                    }

                Text(hotkey == nil
                     ? "Enter one letter or digit to set the shortcut."
                     : "Shortcut set.")
                    .font(.footnote)
                    .foregroundStyle(hotkey == nil ? .orange : .secondary)
            }
        }
        .onAppear(perform: loadFromBinding)
    }

    private func loadFromBinding() {
        guard let hk = hotkey else {
            enabled = false
            return
        }
        enabled = true
        useCommand = hk.modifiers & HotkeyCarbon.command != 0
        useShift = hk.modifiers & HotkeyCarbon.shift != 0
        useOption = hk.modifiers & HotkeyCarbon.option != 0
        useControl = hk.modifiers & HotkeyCarbon.control != 0
        keyCharacter = HotkeyCarbon.character(forKeyCode: hk.keyCode) ?? ""
    }

    private func rebuild() {
        guard enabled,
              let char = keyCharacter.lowercased().first,
              let code = HotkeyCarbon.keyCode(for: char) else {
            hotkey = nil
            return
        }
        var mods: UInt32 = 0
        if useCommand { mods |= HotkeyCarbon.command }
        if useShift { mods |= HotkeyCarbon.shift }
        if useOption { mods |= HotkeyCarbon.option }
        if useControl { mods |= HotkeyCarbon.control }
        hotkey = Hotkey(keyCode: code, modifiers: mods)
    }
}

// MARK: - Carbon hotkey helpers

/// Carbon modifier masks and a small key-character <-> virtual-keycode map, so
/// the settings UI can build `Hotkey` values without importing Carbon.
enum HotkeyCarbon {
    static let command: UInt32 = 0x0100  // cmdKey
    static let shift: UInt32   = 0x0200  // shiftKey
    static let option: UInt32  = 0x0800  // optionKey
    static let control: UInt32 = 0x1000  // controlKey

    // Carbon kVK_ANSI_* virtual key codes for letters and digits.
    private static let map: [Character: UInt32] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11,
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17,
        "9": 0x19, "7": 0x1A, "8": 0x1C, "0": 0x1D,
        "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26,
        "k": 0x28, "n": 0x2D, "m": 0x2E
    ]

    static func keyCode(for character: Character) -> UInt32? {
        map[character]
    }

    static func character(forKeyCode code: UInt32) -> String? {
        map.first { $0.value == code }.map { String($0.key) }
    }
}

// MARK: - Bootstrap key import

/// Imports the gitignored `.secrets/anthropic-key` file into the Keychain once,
/// on first launch. Returns true if a key was actually imported (so the caller
/// can show the "rotate this key" banner). Idempotent via a UserDefaults flag.
enum BootstrapKeyImporter {
    static let importedFlagKey = "AlembicRewrite.bootstrapKeyImported"

    /// Candidate locations for the bootstrap file, in priority order.
    private static var candidatePaths: [String] {
        var paths: [String] = []
        // 1. Relative to the current working directory (typical `swift run`).
        paths.append(FileManager.default.currentDirectoryPath + "/.secrets/anthropic-key")
        // 2. The known project root for this personal build.
        paths.append("/Users/jean-lucalder/Desktop/Claude/prompt-rewriter/.secrets/anthropic-key")
        return paths
    }

    @discardableResult
    static func importIfNeeded(into keychain: KeychainStoring) -> Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: importedFlagKey) else { return false }

        for path in candidatePaths {
            guard FileManager.default.fileExists(atPath: path),
                  let raw = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            do {
                try keychain.setKey(key, for: .anthropic)
                defaults.set(true, forKey: importedFlagKey)
                return true
            } catch {
                return false
            }
        }
        // No file found; mark as handled so we do not scan on every launch.
        defaults.set(true, forKey: importedFlagKey)
        return false
    }
}
