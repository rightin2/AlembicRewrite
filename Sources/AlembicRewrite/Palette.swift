//
//  Palette.swift
//  AlembicRewrite
//
//  The style picker: a floating, non-activating panel that appears at the
//  mouse location when the global hotkey fires. Keyboard-first: type to filter,
//  Up/Down to move the selection, Return to choose, Esc to dismiss. The panel
//  becomes key so it takes keystrokes WITHOUT activating (stealing focus from)
//  the app the user is working in.
//
//  All keyboard handling is driven at the panel level (see `NonActivatingPanel`
//  in RewritePanel.swift) rather than through a focused TextField, so arrow-key
//  navigation and type-to-filter never fight each other — the Spotlight pattern.
//
//  The view model exposes published state; the integrator supplies the style
//  list and the `onSelect` / `onCancel` callbacks (wired to selection capture +
//  the rewrite pipeline). This file owns only presentation and key routing.
//

import SwiftUI
import AppKit

// MARK: - View model

@MainActor
public final class PaletteViewModel: ObservableObject {
    /// The full style list, ascending by sort order (as delivered by the store).
    @Published public var styles: [Style]
    /// Current type-to-filter query.
    @Published public var filter: String = ""
    /// Index into `filtered` of the highlighted row.
    @Published public var selectedIndex: Int = 0

    /// Fired when the user chooses a style (Return or click).
    public var onSelect: ((Style) -> Void)?
    /// Fired when the user dismisses the palette (Esc).
    public var onCancel: (() -> Void)?

    public init(styles: [Style] = []) {
        self.styles = styles
    }

    /// Styles matching the current filter (case- and diacritic-insensitive
    /// substring on the name). Empty filter shows everything.
    public var filtered: [Style] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return styles }
        return styles.filter {
            $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    // Keyboard intents.

    func moveDown() {
        guard !filtered.isEmpty else { return }
        selectedIndex = min(selectedIndex + 1, filtered.count - 1)
    }

    func moveUp() {
        guard !filtered.isEmpty else { return }
        selectedIndex = max(selectedIndex - 1, 0)
    }

    func appendCharacters(_ characters: String) {
        filter += characters
        clampSelection()
    }

    func deleteBackward() {
        guard !filter.isEmpty else { return }
        filter.removeLast()
        clampSelection()
    }

    func submit() {
        guard filtered.indices.contains(selectedIndex) else { return }
        onSelect?(filtered[selectedIndex])
    }

    func choose(_ style: Style) {
        onSelect?(style)
    }

    func cancel() {
        onCancel?()
    }

    private func clampSelection() {
        if filtered.isEmpty {
            selectedIndex = 0
        } else if selectedIndex >= filtered.count {
            selectedIndex = filtered.count - 1
        }
    }
}

// MARK: - View

public struct PaletteView: View {
    @ObservedObject private var model: PaletteViewModel

    public init(model: PaletteViewModel) {
        self.model = model
    }

    // Convenience for previews / the scaffold's default construction.
    public init() {
        self.init(model: PaletteViewModel())
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchHeader
            Divider()
            results
        }
        .frame(width: 360)
        .background(VisualEffectBackground(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: AlembicMetrics.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AlembicMetrics.radius, style: .continuous)
                .strokeBorder(Alembic.border.opacity(0.6), lineWidth: AlembicMetrics.hairline)
        )
        .tint(Alembic.accent)
    }

    private var searchHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Alembic.accent)
            if model.filter.isEmpty {
                Text("Filter styles…")
                    .foregroundStyle(Alembic.inkMuted)
            } else {
                Text(model.filter)
                    .foregroundStyle(Alembic.ink)
            }
            Spacer()
        }
        .font(.alembicDisplay(19, weight: .regular))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var results: some View {
        let items = model.filtered
        if items.isEmpty {
            Text("No matching styles")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, style in
                            PaletteRow(
                                style: style,
                                isSelected: index == model.selectedIndex
                            )
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { model.choose(style) }
                            .onHover { hovering in
                                if hovering { model.selectedIndex = index }
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 320)
                .onChange(of: model.selectedIndex) { newValue in
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct PaletteRow: View {
    let style: Style
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(isSelected ? Color.white : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(style.name)
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.white : .primary)
                Text(style.model)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
            }
            Spacer()
            if let hotkey = style.hotkey {
                Text(HotkeyFormatter.string(for: hotkey))
                    .font(.caption.monospaced())
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : .secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Alembic.accent : Color.clear)
        )
    }

    private var icon: String {
        switch style.provider {
        case .anthropic: return "a.circle"
        case .openai: return "o.circle"
        }
    }
}

/// Renders a `Hotkey` as a compact glyph string (⌘⇧R) for the palette rows.
/// Presentation-only; the authoritative key handling lives in HotkeyManager.
enum HotkeyFormatter {
    static func string(for hotkey: Hotkey) -> String {
        var out = ""
        // Carbon modifier bit masks.
        if hotkey.modifiers & 0x1000 != 0 { out += "⌃" } // controlKey
        if hotkey.modifiers & 0x0800 != 0 { out += "⌥" } // optionKey
        if hotkey.modifiers & 0x0200 != 0 { out += "⇧" } // shiftKey
        if hotkey.modifiers & 0x0100 != 0 { out += "⌘" } // cmdKey
        out += keyName(hotkey.keyCode)
        return out
    }

    // A small subset of common virtual key codes → display glyphs.
    private static func keyName(_ code: UInt32) -> String {
        let map: [UInt32: String] = [
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
            34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O",
            35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V",
            13: "W", 7: "X", 16: "Y", 6: "Z",
            49: "Space", 36: "↩", 48: "⇥", 53: "⎋"
        ]
        return map[code] ?? "?"
    }
}

// MARK: - Controller

/// Owns the palette window: builds it, positions it at the mouse, routes raw
/// key events to the view model. The integrator retains one, calls
/// `show(model:)` when the global hotkey fires, and `close()` on select/cancel.
@MainActor
public final class PaletteController {
    private var panel: NonActivatingPanel?

    public init() {}

    /// Present the palette at the current mouse location for the given model.
    public func show(model: PaletteViewModel) {
        model.selectedIndex = 0

        let hosting = NSHostingController(rootView: PaletteView(model: model))
        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 400)
        )
        panel.contentViewController = hosting
        panel.setContentSize(hosting.view.fittingSize)

        // Route every keystroke through the view model. Returning true consumes
        // the event; navigation/filter keys are handled here, printable
        // characters extend the filter.
        panel.keyDownHandler = { [weak model] event in
            guard let model else { return false }
            switch event.keyCode {
            case 125: // Down
                model.moveDown(); return true
            case 126: // Up
                model.moveUp(); return true
            case 36, 76: // Return / keypad Enter
                model.submit(); return true
            case 53: // Escape
                model.cancel(); return true
            case 51: // Delete / Backspace
                model.deleteBackward(); return true
            default:
                if let characters = event.characters,
                   !characters.isEmpty,
                   characters.allSatisfy({ !$0.isNewline }),
                   event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                   characters.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) {
                    model.appendCharacters(characters)
                    return true
                }
                return false
            }
        }

        positionAtMouse(panel)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    public func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    public var isVisible: Bool { panel?.isVisible ?? false }

    /// Place the panel's top-left just below and right of the cursor, nudged
    /// back on-screen if it would overflow the containing display.
    private func positionAtMouse(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation // screen coords, bottom-left origin
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let size = panel.frame.size

        var x = mouse.x + 8
        var y = mouse.y - size.height - 8 // panel below the cursor
        if x + size.width > visible.maxX { x = visible.maxX - size.width - 8 }
        if x < visible.minX { x = visible.minX + 8 }
        if y < visible.minY { y = mouse.y + 8 } // flip above if no room below
        if y + size.height > visible.maxY { y = visible.maxY - size.height - 8 }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
