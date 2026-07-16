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

    /// Pointer location captured at the last keyboard navigation or filter
    /// mutation. Hover-select is suppressed until the pointer actually moves
    /// away from it, so list auto-scroll under a stationary cursor cannot yank
    /// the selection back toward the row under the mouse (B2).
    private var hoverLockLocation: CGPoint?
    /// Current pointer location in screen space. Injectable so hover-vs-arrow
    /// gating is unit-testable without a real mouse.
    var currentMouseLocation: () -> CGPoint = { NSEvent.mouseLocation }

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
        lockHover()
    }

    func moveUp() {
        guard !filtered.isEmpty else { return }
        selectedIndex = max(selectedIndex - 1, 0)
        lockHover()
    }

    func appendCharacters(_ characters: String) {
        filter += characters
        // The filter reordered/shrank the list; always put the highlight on the
        // top result so Return can never run a middle row the user did not aim
        // at (B3). Lock hover so the list settling under a stationary cursor
        // cannot immediately override this (B2).
        selectedIndex = 0
        lockHover()
    }

    func deleteBackward() {
        guard !filter.isEmpty else { return }
        filter.removeLast()
        selectedIndex = 0
        lockHover()
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

    /// Honour a row hover only if the pointer actually moved since the last
    /// keyboard navigation or filter change. This stops auto-scroll from
    /// re-firing hover under a stationary cursor and fighting the arrows (B2).
    func hover(index: Int) {
        if let lock = hoverLockLocation, lock == currentMouseLocation() { return }
        hoverLockLocation = nil
        guard filtered.indices.contains(index) else { return }
        selectedIndex = index
    }

    private func lockHover() {
        hoverLockLocation = currentMouseLocation()
    }
}

// MARK: - View

public struct PaletteView: View {
    @ObservedObject private var model: PaletteViewModel
    @State private var blinkOn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: PaletteViewModel) {
        self.model = model
    }

    // Convenience for previews / the scaffold's default construction.
    public init() {
        self.init(model: PaletteViewModel())
    }

    public var body: some View {
        GlassPanel(radius: AlembicMetrics.r3, material: .popover) {
            VStack(alignment: .leading, spacing: 0) {
                searchHeader
                Rectangle()
                    .fill(Color.hairline)
                    .frame(height: AlembicMetrics.hairline)
                results
            }
        }
        .frame(width: 360)
        .tint(Alembic.accent)
    }

    private var searchHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Alembic.accentVibrant)
                .shadow(color: AlembicUnderglow.glowColor, radius: AlembicUnderglow.glowRadius)
            HStack(spacing: 2) {
                if model.filter.isEmpty {
                    Text("Filter styles")
                        .font(.alTitle)
                        .foregroundStyle(Color.mutedBase)
                } else {
                    Text(model.filter)
                        .font(.alTitle)
                        .foregroundStyle(Color.inkBase)
                }
                caret
            }
            Spacer(minLength: 8)
            Text("\(model.filtered.count) of \(model.styles.count)")
                .font(.alState)
                .tracking(0.8)
                .foregroundStyle(Color.mutedBase)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Blinking accent caret so the static filter reads as a live input (F8).
    private var caret: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(Alembic.accentVibrant)
            .frame(width: 1.5, height: 16)
            .opacity(blinkOn ? 1 : 0)
            .onAppear {
                guard !reduceMotion else { blinkOn = true; return }
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    blinkOn = true
                }
            }
    }

    @ViewBuilder
    private var results: some View {
        let items = model.filtered
        if model.styles.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("No styles yet")
                    .font(.alBody)
                    .foregroundStyle(Color.inkBase)
                Text("Open Settings from the menu bar to add one.")
                    .font(.alState)
                    .tracking(0.6)
                    .foregroundStyle(Color.mutedBase)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        } else if items.isEmpty {
            Text("No matching styles")
                .font(.alBody)
                .foregroundStyle(Color.mutedBase)
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
                            .onTapGesture { model.choose(style) }
                            .onHover { hovering in
                                if hovering { model.hover(index: index) }
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
        GlassListRow(selected: isSelected) {
            HStack(spacing: 10) {
                Text(providerGlyph)
                    .font(.alButton)
                    .foregroundStyle(isSelected ? Color.white : Color.accentText)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(style.name)
                        .font(.alBody)
                        .foregroundStyle(isSelected ? Color.white : Color.inkBase)
                    Text(style.model)
                        .font(.alState)
                        .tracking(0.6)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.mutedBase)
                }
                Spacer()
                HotkeyGlyph(style.hotkey, color: isSelected ? Color.white.opacity(0.9) : Color.mutedBase)
            }
        }
    }

    private var providerGlyph: String {
        switch style.provider {
        case .anthropic: return "A"
        case .openai: return "O"
        }
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

        // Click-away dismissal: if the user clicks back into their app without
        // pressing Esc, the palette resigns key and cancels itself instead of
        // floating on top forever (B1). Detached in `close()` so our own
        // programmatic dismissals never re-fire cancel.
        panel.onResignKey = { [weak model] in model?.cancel() }

        positionAtMouse(panel)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    public func close() {
        panel?.onResignKey = nil
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
