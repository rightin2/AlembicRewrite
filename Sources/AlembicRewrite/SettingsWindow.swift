//
//  SettingsWindow.swift
//  AlembicRewrite
//
//  Settings window, restyled to the Alembic liquid-glass language (design doc
//  section 5) and home to the ten consensus settings (section 3). Four tabs
//  inside one GlassPanel with a custom glass tab strip:
//
//    General   — startup, editable global hotkey (3.1), Accessibility status
//                (3.9), house-style enforcement (3.2), new-style defaults (3.10).
//    API Keys  — two provider cards saving to the Keychain; rotate-key banner.
//    Styles    — full CRUD + reorder, editor with the known-models picker (3.6),
//                per-style max tokens (3.8), key status + unpriced marker, and a
//                validating hotkey recorder.
//    Safety    — monthly spend cap (3.3), large-selection guard (3.5), history
//                retention and purge (3.4), undo window (3.7).
//
//  Glass is for chrome, solid is for reading: containers are GlassPanel, every
//  text field is a pinned-solid InputField, controls (Toggle/Stepper/Picker) sit
//  solid on the glass.
//

import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Root

public struct SettingsView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var tab: SettingsTab = .general

    public init() {}

    public var body: some View {
        GlassPanel(radius: AlembicMetrics.r3, material: .hudWindow) {
            VStack(spacing: 0) {
                SettingsTabBar(tab: $tab)
                Divider().overlay(Color.hairline)
                Group {
                    switch tab {
                    case .general:  GeneralTab()
                    case .apiKeys:  APIKeysTab()
                    case .styles:   StylesTab()
                    case .safety:   SafetyTab()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .tint(Alembic.accent)
    }
}

// MARK: - Tabs

enum SettingsTab: String, CaseIterable {
    case general = "General"
    case apiKeys = "API Keys"
    case styles = "Styles"
    case safety = "Safety"

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .apiKeys: return "key"
        case .styles:  return "square.stack"
        case .safety:  return "shield"
        }
    }
}

/// The glass tab strip: active tab carries a 2pt accent-vibrant underline and a
/// semibold body label; inactive tabs are muted.
struct SettingsTabBar: View {
    @Binding var tab: SettingsTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases, id: \.self) { t in
                SettingsTabButton(tab: t, active: tab == t) { tab = t }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

/// One tab in the settings strip: type-ramp label + icon, an accent-vibrant
/// underline when active, and (UI-8) keyboard focusability with the shared focus
/// ring, a hover ink-lift, and the selected accessibility trait so the strip is
/// no longer mouse-only.
private struct SettingsTabButton: View {
    let tab: SettingsTab
    let active: Bool
    let action: () -> Void

    @FocusState private var focused: Bool
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: tab.symbol).font(.alFieldLabel)
                    Text(tab.rawValue).font(.alButton)
                }
                .foregroundStyle(active ? Color.inkBase : Color.mutedBase)
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(active ? Color.accentVibrant : Color.clear)
                    .frame(height: 2)
            }
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .alFocusRing(focused, radius: AlembicMetrics.r2)
        .brightness(hovering && !active ? 0.06 : 0)
        .animation(reduceMotion ? nil : AlembicMotion.hover, value: hovering)
        .onHover { hovering = $0 }
        .accessibilityLabel(tab.rawValue)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Reusable section wrapper

/// A named settings block: the wide-tracked micro-label over its content, with
/// consistent vertical rhythm.
struct SettingsSection<Content: View>: View {
    let title: String
    var footnote: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title)
            content()
            if let footnote {
                Text(footnote)
                    .font(.alFootnote)
                    .foregroundStyle(Color.mutedBase)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The scrolling body shell every tab pours its sections into.
struct SettingsScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content()
            }
            .padding(20)
        }
    }
}

// MARK: - General tab

struct GeneralTab: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject private var settings = AppSettings.shared

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var accessibilityGranted = false

    var body: some View {
        SettingsScroll {
            SettingsSection(title: "About") {
                HStack {
                    Text("Version")
                        .foregroundStyle(Alembic.ink)
                    Spacer()
                    Text(AppVersion.currentString)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Alembic.inkMuted)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Version \(AppVersion.currentString)")
            }

            // 3 (startup)
            SettingsSection(title: "Startup") {
                GlassToggle("Launch AlembicRewrite at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            // 3.1 Editable global palette hotkey.
            //
            // INTEGRATION(global-hotkey): `RewriteCoordinator.registerHotkeys` /
            // `syncStyleHotkeys` currently register `HotkeyManager.defaultGlobalHotkey`.
            // Repoint them at `AppSettings.shared.prefs.globalHotkey` so this
            // recorder actually rebinds the palette trigger, and re-register on
            // change (Settings close already triggers `onSettingsClosed`).
            SettingsSection(
                title: "Global hotkey",
                footnote: "Opens the style palette over your current selection. The default is Command-Shift-E. The AlembicRewriter style has its own direct hotkey, Command-Shift-R, which skips the palette."
            ) {
                HotkeyRecorder(
                    hotkey: Binding(
                        get: { settings.prefs.globalHotkey },
                        set: { if let hk = $0 { settings.prefs.globalHotkey = hk } }
                    ),
                    allowClear: false,
                    conflict: { hk in
                        // Warn if a style already owns this combo.
                        let styles = (try? env.styleStore.all()) ?? []
                        if let s = styles.first(where: { $0.hotkey == hk }) {
                            return "Shared with the \(s.name) style"
                        }
                        return nil
                    }
                )
            }

            // 3.9 Accessibility permission status and re-grant.
            SettingsSection(
                title: "Accessibility",
                footnote: "AlembicRewrite needs Accessibility permission to read your selection and paste the rewrite. If it is revoked after an OS update, rewrites fail silently."
            ) {
                HStack(spacing: 12) {
                    if accessibilityGranted {
                        StatusBadge(.ready, text: "Granted")
                    } else {
                        StatusBadge(.error, text: "Not granted")
                    }
                    Spacer()
                    GlassButton("Open System Settings", style: .smoke) {
                        env.selection.openAccessibilitySettings()
                    }
                    GlassButton("Re-check", style: .quiet) {
                        accessibilityGranted = env.selection.hasAccessibilityPermission()
                    }
                }
            }

            // 3.2 Australian English + no em/en dash enforcement.
            SettingsSection(
                title: "House style",
                footnote: "This rule is appended to every prompt. With the dash strip on, any em or en dash the model still emits is removed before the text is pasted, so the rule is a guarantee rather than a hope."
            ) {
                GlassToggle("Enforce Australian English and no dashes", isOn: $settings.prefs.enforceHouseStyle)
                InputField(
                    "House-style instruction",
                    text: $settings.prefs.houseStyleInstruction,
                    multiline: true,
                    minHeight: 72
                )
                .disabled(!settings.prefs.enforceHouseStyle)
                .opacity(settings.prefs.enforceHouseStyle ? 1 : 0.5)
                GlassToggle("Strip em and en dashes from output", isOn: $settings.prefs.stripDashes)
            }

            // 3.10 App-level defaults for new styles.
            SettingsSection(
                title: "New style defaults",
                footnote: "Seed values for the + button in the Styles tab."
            ) {
                Picker("Provider", selection: $settings.prefs.defaultProvider) {
                    ForEach(Provider.allCases, id: \.self) { p in
                        Text(p == .anthropic ? "Anthropic" : "OpenAI").tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .onChange(of: settings.prefs.defaultProvider) { _, p in
                    // Keep the default model valid for the chosen provider.
                    if !KnownModels.forProvider(p).contains(where: { $0.id == settings.prefs.defaultModel }) {
                        settings.prefs.defaultModel = KnownModels.forProvider(p).first?.id ?? settings.prefs.defaultModel
                    }
                }

                Picker("Model", selection: $settings.prefs.defaultModel) {
                    ForEach(KnownModels.forProvider(settings.prefs.defaultProvider)) { m in
                        Text(m.displayName).tag(m.id)
                    }
                }
                .fixedSize()

                HStack {
                    Text("Temperature").font(.alBody).foregroundStyle(Color.inkBase)
                    Slider(value: $settings.prefs.defaultTemperature, in: 0...2, step: 0.05)
                        .frame(maxWidth: 240)
                    Text(String(format: "%.2f", settings.prefs.defaultTemperature))
                        .font(.alMono).foregroundStyle(Color.mutedBase)
                        .frame(width: 44, alignment: .trailing)
                }
                GlassToggle("New styles open the review panel by default", isOn: $settings.prefs.defaultAlwaysReview)
            }
        }
        .onAppear {
            accessibilityGranted = env.selection.hasAccessibilityPermission()
        }
    }
}

// MARK: - API Keys tab

struct APIKeysTab: View {
    @EnvironmentObject var env: AppEnvironment

    @State private var anthropicKey = ""
    @State private var openaiKey = ""
    @State private var anthropicSavedValue = ""
    @State private var openaiSavedValue = ""

    var body: some View {
        SettingsScroll {
            if env.showRotateKeyBanner {
                rotateBanner
            }
            providerCard(
                title: "Anthropic",
                placeholder: "sk-ant-…",
                key: $anthropicKey,
                savedValue: $anthropicSavedValue,
                provider: .anthropic
            )
            providerCard(
                title: "OpenAI",
                placeholder: "sk-…",
                key: $openaiKey,
                savedValue: $openaiSavedValue,
                provider: .openai
            )
            Text("Keys are stored in a private file in the app's Application Support folder, readable only by your user account, and are sent solely to their provider's API. There is no telemetry.")
                .font(.alFootnote)
                .foregroundStyle(Color.mutedBase)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: loadExisting)
    }

    private var rotateBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Alembic.warning)
            VStack(alignment: .leading, spacing: 6) {
                Text("Bootstrap key imported").font(.alTitle).foregroundStyle(Color.inkBase)
                Text("An Anthropic key from .secrets/anthropic-key was imported into local storage on first launch. That key was exposed in chat; rotate it in the Anthropic console and paste the new key below.")
                    .font(.alFootnote).foregroundStyle(Color.mutedBase)
                    .fixedSize(horizontal: false, vertical: true)
                GlassButton("Dismiss", style: .quiet) { env.setRotateBanner(false) }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: AlembicMetrics.r2, style: .continuous)
                .fill(Color.warningSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AlembicMetrics.r2, style: .continuous)
                .strokeBorder(Alembic.warning.opacity(0.35), lineWidth: 1)
        )
    }

    private func providerCard(
        title: String,
        placeholder: String,
        key: Binding<String>,
        savedValue: Binding<String>,
        provider: Provider
    ) -> some View {
        let isSaved = !savedValue.wrappedValue.isEmpty && key.wrappedValue == savedValue.wrappedValue
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title)
                Spacer()
                if isSaved { StatusBadge(.ready, text: "Saved") }
            }
            InputField(placeholder, text: key, secure: true)
            HStack(spacing: 10) {
                GlassButton("Save", style: .primaryFlat, disabled: key.wrappedValue.isEmpty) {
                    do {
                        try env.keychain.setKey(key.wrappedValue, for: provider)
                        savedValue.wrappedValue = key.wrappedValue
                    } catch { savedValue.wrappedValue = "" }
                }
                Spacer()
                if !savedValue.wrappedValue.isEmpty {
                    GlassButton("Remove", style: .danger) {
                        try? env.keychain.deleteKey(for: provider)
                        key.wrappedValue = ""
                        savedValue.wrappedValue = ""
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: AlembicMetrics.r2, style: .continuous)
                .fill(Color.surface3.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AlembicMetrics.r2, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 1)
        )
    }

    private func loadExisting() {
        if let k = (try? env.keychain.key(for: .anthropic)) ?? nil, !k.isEmpty {
            anthropicKey = k
            anthropicSavedValue = k
        }
        if let k = (try? env.keychain.key(for: .openai)) ?? nil, !k.isEmpty {
            openaiKey = k
            openaiSavedValue = k
        }
    }
}

// MARK: - Styles tab

struct StylesTab: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject private var settings = AppSettings.shared

    @State private var styles: [Style] = []
    @State private var selectedID: UUID?
    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 0) {
            styleList
                .frame(width: 172)
            Divider().overlay(Color.hairline)
            editorPane
        }
        .onAppear(perform: reload)
    }

    private var styleList: some View {
        VStack(spacing: 0) {
            List {
                ForEach(styles) { style in
                    GlassListRow(selected: style.id == selectedID) {
                        Text(style.name.isEmpty ? "Untitled" : style.name)
                            .font(.alBody)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selectedID = style.id }
                    .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .onMove(perform: move)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            Divider().overlay(Color.hairline)

            HStack(spacing: 6) {
                Button(action: addStyle) { Image(systemName: "plus") }
                    .help("Add style")
                    .accessibilityLabel("Add style")
                Button { confirmingDelete = true } label: { Image(systemName: "minus") }
                    .disabled(selectedID == nil)
                    .help("Delete style")
                    .accessibilityLabel("Delete style")
                Spacer()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.inkBase)
            .padding(8)
        }
        // UI-20: deleting a style is destructive with no undo, so confirm first.
        .confirmationDialog(
            "Delete \(selectedStyleName)?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectedStyleName)", role: .destructive, action: deleteSelected)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the style and its hotkey. It cannot be undone.")
        }
    }

    private var selectedStyleName: String {
        guard let index = selectedIndex else { return "style" }
        let name = styles[index].name
        return name.isEmpty ? "Untitled" : name
    }

    @ViewBuilder
    private var editorPane: some View {
        if let index = selectedIndex {
            StyleEditor(
                style: Binding(
                    get: { styles[index] },
                    set: { styles[index] = $0 }
                ),
                allStyles: styles,
                onSave: { saveStyle($0) }
            )
            .id(styles[index].id)
        } else {
            VStack {
                Spacer()
                Text("Select a style, or add one with +")
                    .font(.alBody)
                    .foregroundStyle(Color.mutedBase)
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
        // 3.10: seed the new style from the app-level defaults.
        let p = settings.prefs
        let nextOrder = (styles.map(\.sortOrder).max() ?? -1) + 1
        let new = Style(
            name: "New Style",
            promptTemplate: "Rewrite the following text.\n\n{{selection}}",
            provider: p.defaultProvider,
            model: p.defaultModel,
            temperature: p.defaultTemperature,
            sortOrder: nextOrder,
            alwaysReview: p.defaultAlwaysReview
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
    @EnvironmentObject var env: AppEnvironment
    @Binding var style: Style
    /// All styles, so the hotkey recorder can flag a combo already claimed by
    /// another style (F1).
    let allStyles: [Style]
    /// Persist on every field change (autosave, B4) so edits and a just-recorded
    /// hotkey are never lost when the user switches styles or closes Settings.
    let onSave: (Style) -> Void

    @ObservedObject private var settings = AppSettings.shared
    @State private var customModel = false

    var body: some View {
        SettingsScroll {
            SettingsSection(title: "Name") {
                InputField("Style name", text: $style.name)
            }

            SettingsSection(
                title: "Prompt template",
                footnote: "Use {{selection}} where the captured text should be inserted."
            ) {
                InputField("Prompt with {{selection}}", text: $style.promptTemplate,
                           multiline: true, mono: true, minHeight: 120)
            }

            SettingsSection(title: "Model") {
                Picker("Provider", selection: $style.provider) {
                    ForEach(Provider.allCases, id: \.self) { p in
                        Text(p == .anthropic ? "Anthropic" : "OpenAI").tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .onChange(of: style.provider) { _, _ in syncModelChoice() }

                keyStatusRow

                Picker("Model", selection: modelChoiceBinding) {
                    ForEach(KnownModels.forProvider(style.provider)) { m in
                        Text(m.displayName).tag(m.id)
                    }
                    Text("Other…").tag(Self.otherTag)
                }
                .fixedSize()

                if customModel {
                    InputField("Model identifier", text: $style.model)
                }

                if !KnownModels.isPriced(style.model) {
                    // B8: an unpriced id accrues real spend shown as $0.
                    Label("Unpriced, metered at $0", systemImage: "exclamationmark.triangle.fill")
                        .font(.alState).tracking(0.8).textCase(.uppercase)
                        .foregroundStyle(Color.warningText)
                }

                HStack {
                    Text("Temperature").font(.alBody).foregroundStyle(Color.inkBase)
                    Slider(value: $style.temperature, in: 0...2, step: 0.05)
                        .frame(maxWidth: 220)
                    Text(String(format: "%.2f", style.temperature))
                        .font(.alMono).foregroundStyle(Color.mutedBase)
                        .frame(width: 44, alignment: .trailing)
                }

                // 3.8 Per-style max output tokens.
                Stepper(value: $style.maxTokens, in: 64...8192, step: 64) {
                    HStack {
                        Text("Max output tokens").font(.alBody).foregroundStyle(Color.inkBase)
                        Text("\(style.maxTokens)").font(.alMono).foregroundStyle(Color.mutedBase)
                    }
                }
            }

            SettingsSection(
                title: "Direct hotkey (optional)",
                footnote: "When the review toggle is off, this style's direct hotkey rewrites silently and pastes over your selection. When on, it opens the review panel. The palette always opens the review panel."
            ) {
                HotkeyRecorder(
                    hotkey: $style.hotkey,
                    allowClear: true,
                    conflict: { hk in
                        if hk == settings.prefs.globalHotkey {
                            return "Reserved by the global palette"
                        }
                        if let s = allStyles.first(where: { $0.id != style.id && $0.hotkey == hk }) {
                            return "Shared with the \(s.name) style"
                        }
                        return nil
                    }
                )
                GlassToggle("Always show review panel", isOn: $style.alwaysReview)
            }
        }
        .onAppear(perform: syncModelChoice)
        .onChange(of: style) { _, newValue in onSave(newValue) }
    }

    // MARK: model picker plumbing

    static let otherTag = "\u{0}other"

    private var modelChoiceBinding: Binding<String> {
        Binding(
            get: { customModel ? Self.otherTag : style.model },
            set: { newVal in
                if newVal == Self.otherTag {
                    customModel = true
                } else {
                    customModel = false
                    style.model = newVal
                }
            }
        )
    }

    private func syncModelChoice() {
        let known = KnownModels.forProvider(style.provider).contains { $0.id == style.model }
        customModel = !known
    }

    @ViewBuilder private var keyStatusRow: some View {
        let hasKey = ((try? env.keychain.key(for: style.provider)) ?? nil).map { !$0.isEmpty } ?? false
        HStack(spacing: 6) {
            Circle()
                .fill(hasKey ? Color.accentVibrant : Color.warning)
                .frame(width: 7, height: 7)
            Text(hasKey
                 ? "\(style.provider == .anthropic ? "Anthropic" : "OpenAI") key set"
                 : "No key for \(style.provider == .anthropic ? "Anthropic" : "OpenAI")")
                .font(.alState).tracking(0.8).textCase(.uppercase)
                .foregroundStyle(hasKey ? Color.accentText : Color.warningText)
        }
    }
}

// MARK: - Safety tab (spend cap, large-selection guard, history, undo)

struct SafetyTab: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject private var settings = AppSettings.shared

    @State private var historyCleared = false

    var body: some View {
        SettingsScroll {
            // 3.3 Monthly spend cap.
            //
            // INTEGRATION(spend-cap): `RewriteCoordinator` must call
            // `AppSettings.shared.evaluateSpendCap(monthToDateUSD:)` before
            // dispatch. `CostMeter` needs a month-to-date total first (add a
            // month key to its tally, doc 3.3); pass that figure here.
            SettingsSection(
                title: "Monthly spend cap",
                footnote: "A dollar ceiling per calendar month. At the warn threshold it flags in the HUD; at 100 percent new rewrites are blocked until you raise the cap or the month rolls over."
            ) {
                GlassToggle("Enforce a monthly spend cap", isOn: $settings.prefs.spendCapEnabled)
                if settings.prefs.spendCapEnabled {
                    Stepper(value: $settings.prefs.monthlyCapUSD, in: 5...1000, step: 5) {
                        HStack {
                            Text("Cap per month").font(.alBody).foregroundStyle(Color.inkBase)
                            Text(String(format: "$%.0f", settings.prefs.monthlyCapUSD))
                                .font(.alMono).foregroundStyle(Color.mutedBase)
                        }
                    }
                    HStack {
                        Text("Warn at").font(.alBody).foregroundStyle(Color.inkBase)
                        Slider(value: $settings.prefs.spendWarnFraction, in: 0.5...0.95, step: 0.05)
                            .frame(maxWidth: 220)
                        Text("\(Int(settings.prefs.spendWarnFraction * 100))%")
                            .font(.alMono).foregroundStyle(Color.mutedBase)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            // 3.5 Large-selection guard.
            //
            // INTEGRATION(large-selection-guard): in
            // `RewriteCoordinator.handleStyleHotkey` silent branch, call
            // `AppSettings.shared.exceedsLargeSelection(selection.count)`; when
            // true, route to the review panel instead of the silent paste.
            SettingsSection(
                title: "Large-selection guard",
                footnote: "Above this many characters, a silent style is forced to open the review panel so a stray Select-All cannot overwrite a whole document."
            ) {
                GlassToggle("Confirm before rewriting a large selection", isOn: $settings.prefs.largeSelectionGuardEnabled)
                if settings.prefs.largeSelectionGuardEnabled {
                    Stepper(value: $settings.prefs.largeSelectionThreshold, in: 200...20000, step: 100) {
                        HStack {
                            Text("Threshold").font(.alBody).foregroundStyle(Color.inkBase)
                            Text("\(settings.prefs.largeSelectionThreshold) chars")
                                .font(.alMono).foregroundStyle(Color.mutedBase)
                        }
                    }
                }
            }

            // 3.4 History retention and purge.
            //
            // INTEGRATION(history-retention): gate `HistoryStore.add` on
            // `AppSettings.shared.historyShouldLog()`, run a date trim from
            // `historyTrimCutoff()`, and on quit honour `clearHistoryOnQuit` /
            // the `.session` mode by clearing.
            SettingsSection(
                title: "History",
                footnote: "Rewrites are logged with their original and result in cleartext. Choose how long to keep them."
            ) {
                Picker("Retention", selection: $settings.prefs.historyMode) {
                    ForEach(HistoryRetentionMode.allCases, id: \.self) { m in
                        Text(m.label).tag(m)
                    }
                }
                .fixedSize()
                if settings.prefs.historyMode == .days {
                    Stepper(value: $settings.prefs.historyRetentionDays, in: 1...365, step: 1) {
                        HStack {
                            Text("Keep for").font(.alBody).foregroundStyle(Color.inkBase)
                            Text("\(settings.prefs.historyRetentionDays) days")
                                .font(.alMono).foregroundStyle(Color.mutedBase)
                        }
                    }
                }
                GlassToggle("Clear history on quit", isOn: $settings.prefs.clearHistoryOnQuit)
                HStack(spacing: 10) {
                    GlassButton("Clear history now", style: .danger) {
                        try? env.historyStore.clear()
                        env.bumpRefresh()
                        historyCleared = true
                    }
                    if historyCleared {
                        StatusBadge(.ready, text: "Cleared")
                    }
                }
            }

            // 3.7 Undo / restore original after paste.
            //
            // INTEGRATION(undo): `RewriteCoordinator` stashes the last captured
            // original in memory for `prefs.undoWindowSeconds`; App.swift adds an
            // "Undo last rewrite" menu item (and optional hotkey) that re-pastes
            // it via `SelectionServicing`. Gate both on `prefs.undoEnabled`.
            SettingsSection(
                title: "Undo",
                footnote: "Keep the pre-rewrite text for a short window so a silent replace can be reverted in one step."
            ) {
                GlassToggle("Allow undo of the last rewrite", isOn: $settings.prefs.undoEnabled)
                if settings.prefs.undoEnabled {
                    Stepper(value: $settings.prefs.undoWindowSeconds, in: 5...120, step: 5) {
                        HStack {
                            Text("Keep original for").font(.alBody).foregroundStyle(Color.inkBase)
                            Text("\(settings.prefs.undoWindowSeconds)s")
                                .font(.alMono).foregroundStyle(Color.mutedBase)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Hotkey recorder

/// A restyled key-capture recorder (design doc 5.7): a solid monospaced pill
/// showing the current combo, "Click to record", or the arming prompt; a
/// two-layer focus ring while armed; an x-clear when set (when `allowClear`);
/// and an amber conflict caption when `conflict` returns a warning. Uses the
/// shared `HotkeyGlyph` formatter for display (B11).
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey?
    var allowClear: Bool = true
    /// Returns a warning string when the given combo collides with another
    /// style or the reserved global hotkey (F1), else nil.
    var conflict: (Hotkey) -> String? = { _ in nil }

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: toggleRecording) {
                    Text(fieldLabel)
                        .font(.alMono)
                        .foregroundStyle(recording ? Color.accentText : Color.inkBase)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .background(
                            RoundedRectangle(cornerRadius: AlembicMetrics.r2, style: .continuous)
                                .fill(Color.inputBg)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: AlembicMetrics.r2, style: .continuous)
                                .strokeBorder(Color.inputBorder, lineWidth: 1)
                        )
                        .alFocusRing(recording, radius: AlembicMetrics.r2)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 260)

                if allowClear, hotkey != nil, !recording {
                    Button { hotkey = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.mutedBase)
                    }
                    .buttonStyle(.plain)
                    .help("Clear hotkey")
                }
            }

            if let hk = hotkey, let warning = conflict(hk) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.alState).tracking(0.8).textCase(.uppercase)
                    .foregroundStyle(Color.warningText)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private var fieldLabel: String {
        if recording { return "Press keys (Esc to cancel)" }
        if let hk = hotkey { return HotkeyGlyph.string(for: hk) }
        return "Click to record"
    }

    private func toggleRecording() {
        if recording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 { // Escape cancels.
                self.stopRecording()
                return nil
            }
            let carbonMods = HotkeyCarbon.carbonModifiers(from: event.modifierFlags)
            if carbonMods != 0, HotkeyCarbon.displayName(forKeyCode: UInt32(event.keyCode)) != nil {
                self.hotkey = Hotkey(keyCode: UInt32(event.keyCode), modifiers: carbonMods)
                self.stopRecording()
            }
            return nil // consume every key while armed
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
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

    // A few non-alphanumeric keys worth allowing in a recorded shortcut.
    private static let specialNames: [UInt32: String] = [
        0x24: "↩",   // return
        0x30: "⇥",   // tab
        0x31: "Space",
        0x33: "⌫",   // delete
        0x35: "⎋",   // escape
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑"
    ]

    static func keyCode(for character: Character) -> UInt32? {
        map[character]
    }

    static func character(forKeyCode code: UInt32) -> String? {
        map.first { $0.value == code }.map { String($0.key) }
    }

    /// Human-readable name for a virtual key code (letters/digits uppercased,
    /// plus a handful of special keys). `nil` for unmappable codes.
    static func displayName(forKeyCode code: UInt32) -> String? {
        if let ch = character(forKeyCode: code) { return ch.uppercased() }
        return specialNames[code]
    }

    /// Convert AppKit modifier flags into the Carbon modifier mask used by
    /// `Hotkey`.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= command }
        if flags.contains(.shift) { mods |= shift }
        if flags.contains(.option) { mods |= option }
        if flags.contains(.control) { mods |= control }
        return mods
    }

    /// Render a `Hotkey` as a symbol string, e.g. "⌘⇧R" (modifier order ⌃⌥⇧⌘).
    static func displayString(for hotkey: Hotkey) -> String {
        var s = ""
        if hotkey.modifiers & control != 0 { s += "⌃" }
        if hotkey.modifiers & option != 0 { s += "⌥" }
        if hotkey.modifiers & shift != 0 { s += "⇧" }
        if hotkey.modifiers & command != 0 { s += "⌘" }
        s += displayName(forKeyCode: hotkey.keyCode) ?? "?"
        return s
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
