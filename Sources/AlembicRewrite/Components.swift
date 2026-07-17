//
//  Components.swift
//  AlembicRewrite
//
//  The shared liquid-glass component library (design doc section 6). Every
//  screen is assembled from these primitives so the Alembic recipe reaches each
//  surface once, from one place. Colours, radii, fonts, shadows, motion, and the
//  two-layer focus ring all come from DesignTokens.swift; this file only shapes
//  them into reusable views.
//
//  Governing rule: glass is for chrome, solid is for reading. GlassPanel,
//  GlassButton (chrome), GlassListRow, SectionHeader, StatusBadge, HotkeyGlyph
//  are the glass side; InputField and GlassToggle are the pinned-solid controls
//  that sit on the glass.
//
//  See docs/design/2026-07-16-ui-audit-redesign.md section 6.
//

import SwiftUI
import AppKit

// MARK: - FrostedBackground (Path A: NSVisualEffectView behind-window)

/// The behind-window blur that backs every glass surface. `.behindWindow`
/// blending blurs the desktop and whatever windows sit behind the panel, which
/// is exactly the wallpaper-show-through a menu-bar utility wants. The warm tint
/// and rim are layered on top by `GlassPanel`; this view is only the blur.
///
/// Usage:
/// ```swift
/// content.background(FrostedBackground(material: .hudWindow))
/// ```
struct FrostedBackground: NSViewRepresentable {
    /// `.hudWindow` for 24px chrome (regular glass); `.popover` for the 12px
    /// clear tier.
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
}

// MARK: - GlassPanel

/// The load-bearing chrome surface: a frosted, warm-tinted card with the
/// signature asymmetric specular rim (full top edge + hairline glass rim, lit
/// upper-left) and an appearance-scaled drop shadow. Reduce-transparency
/// flattens the blur and rim to a solid `surface2` fill while keeping the shadow
/// so elevation stays readable.
///
/// Use `.popover` for the clear tier (palette, menu dropdown) and `.hudWindow`
/// for chrome (review panel, Settings, HUD).
///
/// Usage:
/// ```swift
/// GlassPanel(radius: 12, material: .popover) {
///     VStack { ... }.padding(16)
/// }
/// .frame(width: 360)
/// ```
struct GlassPanel<Content: View>: View {
    /// The ratified surface recipe (`.regular`, `.clear`, `.smoke`) that drives
    /// material, tint, rim, top specular, radius, and shadow tier. Defaults to
    /// `.regular` (chrome).
    var recipe: GlassRecipe = .regular
    /// Optional per-call radius override. `nil` uses `recipe.radius`.
    var radiusOverride: CGFloat? = nil
    /// Optional per-call material override. `nil` uses `recipe.material`.
    var materialOverride: NSVisualEffectView.Material? = nil
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let content: () -> Content

    /// Recipe-first initialiser: pick a ratified surface and (optionally) nudge
    /// its radius or material. Preferred for new callers.
    init(recipe: GlassRecipe = .regular,
         radius: CGFloat? = nil,
         material: NSVisualEffectView.Material? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.recipe = recipe
        self.radiusOverride = radius
        self.materialOverride = material
        self.content = content
    }

    /// Effective radius: explicit override, else the recipe's.
    private var radius: CGFloat { radiusOverride ?? recipe.radius }
    /// Effective material: explicit override, else the recipe's (nil = solid
    /// smoke card with no live blur).
    private var material: NSVisualEffectView.Material? { materialOverride ?? recipe.material }

    var body: some View {
        content()
            .background {
                let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                if reduceTransparency {
                    shape.fill(Color.surface2)
                } else if let material {
                    FrostedBackground(material: material)
                        .overlay(recipe.tint.opacity(recipe.tintOpacity))
                } else {
                    // Smoke: warm solid tint rather than a live blur.
                    shape.fill(recipe.tint.opacity(recipe.tintOpacity))
                }
            }
            // Asymmetric specular rim: full top specular fading to centre.
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [recipe.topSpecular, .clear],
                            startPoint: .top, endPoint: .center),
                        lineWidth: recipe.rimWidth)
                    .opacity(reduceTransparency ? 0 : 1)
            )
            // Hairline glass rim around the whole edge.
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(recipe.rim, lineWidth: recipe.rimWidth)
                    .opacity(reduceTransparency ? 0 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .alShadow(recipe.shadow)
    }
}

// MARK: - GlassButton

/// The six button variants (section 4.6). `primaryFlat` punches clearest for the
/// main action; `smoke` is the frosted secondary; `gold` is the warning-adjacent
/// affirmative (the review-panel Accept); `danger` for destructive; `quiet` for
/// low-emphasis rows inside opaque panels; `primaryLiquid` for accent-on-glass.
///
/// Hover lifts brightness, press nudges down 1pt, disabled dims to 45%. All
/// motion is suppressed under Reduce Motion. The two-layer focus ring is drawn
/// on keyboard focus with the native ring disabled.
enum GlassButtonStyle {
    case primaryFlat, primaryLiquid, smoke, gold, danger, quiet
}

/// A themed button.
///
/// Usage:
/// ```swift
/// GlassButton("Rewrite Selection", style: .primaryFlat, large: true) { rewrite() }
/// GlassButton("Accept", style: .gold) { accept() }
/// GlassButton("Clear", style: .quiet, action: history.clear)
/// ```
struct GlassButton: View {
    let title: String
    var style: GlassButtonStyle = .primaryFlat
    var large: Bool = false
    var disabled: Bool = false
    var trailingGlyph: String? = nil
    let action: () -> Void

    @State private var hovering = false
    @State private var pressed = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String,
         style: GlassButtonStyle = .primaryFlat,
         large: Bool = false,
         disabled: Bool = false,
         trailingGlyph: String? = nil,
         action: @escaping () -> Void) {
        self.title = title
        self.style = style
        self.large = large
        self.disabled = disabled
        self.trailingGlyph = trailingGlyph
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.alButton)
                if let g = trailingGlyph {
                    Text(g).font(.alMono).opacity(0.85)
                }
            }
            .foregroundStyle(labelColor)
            .shadow(color: labelShadow, radius: labelShadow == .clear ? 0 : 1,
                    x: 0, y: labelShadow == .clear ? 0 : 1)
            .padding(.vertical, large ? 12 : 10)
            .padding(.horizontal, large ? 20 : 16)
            .frame(minHeight: large ? 40 : 32)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: AlembicMetrics.r2, style: .continuous))
            .overlay(rimOverlay)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .focusable(!disabled)
        .focused($focused)
        .focusEffectDisabled()
        .alFocusRing(focused, radius: AlembicMetrics.r2)
        .opacity(disabled ? 0.45 : 1)
        .brightness(hovering && !disabled ? 0.06 : 0)
        .offset(y: pressed && !disabled ? 1 : 0)
        .animation(reduceMotion ? nil : AlembicMotion.hover, value: hovering)
        .animation(reduceMotion ? nil : AlembicMotion.hover, value: pressed)
        .onHover { hovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }

    private var labelColor: Color {
        switch style {
        case .primaryFlat:   return Color.onAccent
        case .primaryLiquid: return .white
        case .smoke:         return Color.inkBase
        // Warning-adjacent gold uses the near-black on-gold label token (#3a2e08).
        case .gold:          return Color.onGold
        case .danger:        return Color.onDanger
        case .quiet:         return Alembic.accent
        }
    }

    private var labelShadow: Color {
        style == .primaryLiquid ? .black.opacity(0.3) : .clear
    }

    @ViewBuilder private var background: some View {
        switch style {
        case .primaryFlat:
            Alembic.accent
        case .primaryLiquid:
            Alembic.accent.opacity(0.58)
        case .smoke:
            Color.surface2.overlay(Color.paperTint.opacity(0.5))
        case .gold:
            Alembic.gold
        case .danger:
            Color.dangerBtnBg
        case .quiet:
            // Quiet sits on a clear background, so brightness alone barely shifts
            // the label. Give it a real hover fill inside the r2 shape instead.
            hovering && !disabled ? Color.hoverFill : Color.clear
        }
    }

    @ViewBuilder private var rimOverlay: some View {
        let shape = RoundedRectangle(cornerRadius: AlembicMetrics.r2, style: .continuous)
        switch style {
        case .primaryLiquid:
            shape.strokeBorder(Color.white.opacity(0.45), lineWidth: 1)
        case .smoke:
            shape.strokeBorder(Color.glassRim, lineWidth: 1)
        default:
            shape.strokeBorder(Color.clear, lineWidth: 0)
        }
    }
}

// MARK: - SectionHeader

/// The signature micro-label: tiny, heavy, wide-tracked uppercase text in muted
/// ink, used for anything that names a region ("SPEND", "HISTORY", "ORIGINAL").
///
/// Usage:
/// ```swift
/// SectionHeader("Rewrite Styles")
/// ```
struct SectionHeader: View {
    let text: String
    var color: Color = .mutedBase

    init(_ text: String, color: Color = .mutedBase) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.alLabel)
            .tracking(1.3)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}

// MARK: - GlassListRow

/// One selectable row for the palette results, styles list, and history rows.
/// Selected rows take the accent fill with white content; unselected rows are
/// clear and pick up a faint white hover fill. Radius r1, padding 8x10.
///
/// Usage:
/// ```swift
/// GlassListRow(selected: index == model.selectedIndex) {
///     HStack { Text(style.name); Spacer(); HotkeyGlyph(style.hotkey) }
/// }
/// .onTapGesture { model.select(index) }
/// ```
struct GlassListRow<Content: View>: View {
    var selected: Bool = false
    let content: () -> Content

    @State private var hovering = false

    init(selected: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.selected = selected
        self.content = content
    }

    var body: some View {
        content()
            .foregroundStyle(selected ? Color.onAccent : Color.inkBase)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AlembicMetrics.r1, style: .continuous)
                    .fill(fill)
            )
            .contentShape(RoundedRectangle(cornerRadius: AlembicMetrics.r1, style: .continuous))
            .onHover { hovering = $0 }
    }

    private var fill: Color {
        if selected { return Alembic.accent }
        if hovering { return Color.hoverFill }
        return .clear
    }
}

// MARK: - InputField

/// A pinned-solid text field or editor: opaque `inputBg`, hairline
/// `inputBorder`, fixed `inkBase` foreground, and a pinned `mutedBase`
/// placeholder that never whitens into invisibility. Never place a text surface
/// on a material; this is the "solid is for reading" half of the system.
///
/// `multiline` switches to a `TextEditor` (used for prompt bodies with
/// `mono: true` and a `minHeight`). Single-line is a `TextField`.
///
/// Usage:
/// ```swift
/// InputField("Style name", text: $name)
/// InputField("Prompt with {{selection}}", text: $prompt,
///            multiline: true, mono: true, minHeight: 120)
/// ```
struct InputField: View {
    let placeholder: String
    @Binding var text: String
    var multiline: Bool = false
    var mono: Bool = false
    var minHeight: CGFloat = 0
    var secure: Bool = false

    @FocusState private var focused: Bool

    init(_ placeholder: String,
         text: Binding<String>,
         multiline: Bool = false,
         mono: Bool = false,
         minHeight: CGFloat = 0,
         secure: Bool = false) {
        self.placeholder = placeholder
        self._text = text
        self.multiline = multiline
        self.mono = mono
        self.minHeight = minHeight
        self.secure = secure
    }

    private var font: Font { mono ? .alMono : .alInput }

    var body: some View {
        ZStack(alignment: .topLeading) {
            field
            if text.isEmpty {
                Text(placeholder)
                    .font(font)
                    .foregroundStyle(Color.mutedBase)
                    .padding(.horizontal, multiline ? 5 : 0)
                    .allowsHitTesting(false)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(minHeight: minHeight > 0 ? minHeight : nil,
               alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: AlembicMetrics.r2, style: .continuous)
                .fill(Color.inputBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AlembicMetrics.r2, style: .continuous)
                .strokeBorder(Color.inputBorder, lineWidth: 1)
        )
        .alFocusRing(focused, radius: AlembicMetrics.r2)
    }

    @ViewBuilder private var field: some View {
        if multiline {
            TextEditor(text: $text)
                .font(font)
                .foregroundStyle(Color.inkBase)
                .scrollContentBackground(.hidden)
                .frame(minHeight: minHeight > 0 ? minHeight : nil, alignment: .topLeading)
                .focused($focused)
                .focusEffectDisabled()
        } else if secure {
            SecureField("", text: $text)
                .textFieldStyle(.plain)
                .font(font)
                .foregroundStyle(Color.inkBase)
                .focused($focused)
                .focusEffectDisabled()
        } else {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(font)
                .foregroundStyle(Color.inkBase)
                .focused($focused)
                .focusEffectDisabled()
        }
    }
}

// MARK: - GlassToggle

/// A native `Toggle` tinted to the accent green with an `.alBody` label. A solid
/// control sitting on glass, satisfying "solid for controls".
///
/// Usage:
/// ```swift
/// GlassToggle("Launch at login", isOn: $launchAtLogin)
/// ```
struct GlassToggle: View {
    let label: String
    @Binding var isOn: Bool

    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(label).font(.alBody).foregroundStyle(Color.inkBase)
        }
        .toggleStyle(.switch)
        .tint(Alembic.accent)
    }
}

// MARK: - StatusBadge

/// The compact state pill used across the review panel and error surfaces. Four
/// kinds map to the semantic families: ready (accent), streaming (warm smoke),
/// error (danger), empty (muted, transparent). Uppercase `.alState` on a
/// capsule.
///
/// Usage:
/// ```swift
/// StatusBadge(.ready)                    // "READY"
/// StatusBadge(.error, text: "No text selected")
/// ```
struct StatusBadge: View {
    enum Kind { case ready, streaming, error, empty }

    let kind: Kind
    var text: String? = nil

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ kind: Kind, text: String? = nil) {
        self.kind = kind
        self.text = text
    }

    var body: some View {
        HStack(spacing: 5) {
            leadingMark
            Text(label)
                .font(.alState)
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(labelColor)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(
            Capsule(style: .continuous).fill(fill)
        )
    }

    private var label: String {
        if let text { return text }
        switch kind {
        case .ready:     return "Ready"
        case .streaming: return "Streaming"
        case .error:     return "Error"
        case .empty:     return "Empty"
        }
    }

    @ViewBuilder private var leadingMark: some View {
        switch kind {
        case .ready:
            Circle().fill(labelColor).frame(width: 5, height: 5)
        case .streaming:
            Circle().fill(labelColor).frame(width: 5, height: 5)
                .opacity(pulse ? 0.35 : 1)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(labelColor)
        case .empty:
            EmptyView()
        }
    }

    private var labelColor: Color {
        switch kind {
        case .ready:     return Color.accentText
        case .streaming: return Color.warningText
        case .error:     return Color.danger
        case .empty:     return Color.mutedBase
        }
    }

    private var fill: Color {
        switch kind {
        case .ready:     return Color.accentSoft
        case .streaming: return Color.warningSoft
        case .error:     return Color.danger.opacity(0.15)
        case .empty:     return .clear
        }
    }
}

// MARK: - HotkeyGlyph (single shared formatter, fixes B11)

/// The one shared hotkey renderer, replacing the two divergent key-code maps
/// (`Palette.HotkeyFormatter.keyName` and `HotkeyCarbon.specialNames`) that
/// disagreed and rendered "?" for uncovered keys (B11). Full coverage of
/// letters, digits, punctuation, arrows, delete/forward-delete, return/enter,
/// tab, escape, space, home/end/page, and F1-F12. Monospaced `.alMono`.
///
/// Usage:
/// ```swift
/// HotkeyGlyph(style.hotkey)                    // e.g. ⌘⇧E
/// HotkeyGlyph(style.hotkey, color: .white)     // on a selected accent row
/// ```
struct HotkeyGlyph: View {
    let hotkey: Hotkey?
    var color: Color = .mutedBase

    init(_ hotkey: Hotkey?, color: Color = .mutedBase) {
        self.hotkey = hotkey
        self.color = color
    }

    var body: some View {
        Text(hotkey.map(HotkeyGlyph.string(for:)) ?? "")
            .font(.alMono)
            .foregroundStyle(color)
    }

    /// Format a `Hotkey` as a compact glyph string (⌘⇧E). Modifier order is the
    /// macOS-standard ⌃⌥⇧⌘ then the key.
    static func string(for hotkey: Hotkey) -> String {
        var out = ""
        if hotkey.modifiers & 0x1000 != 0 { out += "⌃" } // controlKey
        if hotkey.modifiers & 0x0800 != 0 { out += "⌥" } // optionKey
        if hotkey.modifiers & 0x0200 != 0 { out += "⇧" } // shiftKey
        if hotkey.modifiers & 0x0100 != 0 { out += "⌘" } // cmdKey
        out += keyName(hotkey.keyCode)
        return out
    }

    /// Virtual key code (Carbon `kVK_*`) to display glyph. Comprehensive, so no
    /// key renders as "?".
    static func keyName(_ code: UInt32) -> String {
        if let name = map[code] { return name }
        return "?"
    }

    private static let map: [UInt32: String] = [
        // Letters (ANSI virtual key codes).
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O",
        35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V",
        13: "W", 7: "X", 16: "Y", 6: "Z",
        // Digits.
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
        22: "6", 26: "7", 28: "8", 25: "9",
        // Punctuation.
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";",
        39: "'", 43: ",", 47: ".", 44: "/", 50: "`",
        // Editing / whitespace.
        49: "Space", 36: "↩", 76: "⌤", 48: "⇥", 53: "⎋",
        51: "⌫", 117: "⌦",
        // Navigation.
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        // Function keys.
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}

// MARK: - FocusRing modifier (two-layer, rule C2)

extension View {
    /// The two-layer focus ring (rule C2): an inner accent-vibrant stroke wrapped
    /// by a near-white outer stroke, so the ring survives any material or busy
    /// wallpaper. Draw this on `.focused`/armed states with the native ring
    /// disabled (`.focusEffectDisabled()`).
    ///
    /// Usage:
    /// ```swift
    /// TextField("", text: $x).focused($armed).focusEffectDisabled()
    ///     .alFocusRing(armed, radius: 8)
    /// ```
    func alFocusRing(_ on: Bool, radius: CGFloat = AlembicFocusRing.radius) -> some View {
        // Both strokes are drawn INSIDE the control's bounds (strokeBorder draws
        // inward), so the near-white outer stroke never bleeds outward as a pale
        // halo box around the button. The near-white stroke rides the edge; the
        // accent stroke sits just inside it.
        self
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(AlembicFocusRing.outerColor,
                                  lineWidth: AlembicFocusRing.outerWidth)
                    .opacity(on ? 1 : 0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(AlembicFocusRing.innerColor,
                                  lineWidth: AlembicFocusRing.innerWidth)
                    .padding(AlembicFocusRing.outerInset)
                    .opacity(on ? 1 : 0)
            )
    }
}
