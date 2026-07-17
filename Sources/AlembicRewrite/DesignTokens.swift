//
//  DesignTokens.swift
//  AlembicRewrite
//
//  The Alembic design language, ported from the ratified liquid-glass theme
//  (app/alembic-light-glass.html, 2026-07-16) plus glass.css / materials.css /
//  globals.css / fonts.css into SwiftUI primitives. Colours, radii, spacing,
//  shadows, motion, type ramp, the two-layer focus ring, and the three glass
//  recipes live here so every view reads from one catalogue.
//
//  See docs/design/2026-07-16-ui-audit-redesign.md sections 4 and 6.10.
//
//  Governing rule: glass is for chrome, solid is for reading. Warm, not cool.
//
//  Fonts are NOT bundled: display type asks for the serif design (SwiftUI falls
//  back to the system serif, standing in for Source Serif 4) and body type uses
//  the system sans (standing in for DM Sans). No @font-face, no shipped files.
//

import SwiftUI
import AppKit

// MARK: - Palette

/// Alembic colours as light/dark dynamic `Color`s. Each token resolves to the
/// right hue for the current appearance via `NSColor(name:dynamicProvider:)`.
///
/// This enum is the single source of truth for the palette; the `Color`
/// extension below re-exports the same values under the short names the
/// component library (section 6) reads (`Color.accentVibrant`, `Color.inkBase`,
/// `Color.glassRim`, and so on).
enum Alembic {

    // MARK: Green family (the default Alembic Green pack)

    /// Base brand green. Flat fills: buttons, bars, selection. Never bare on glass.
    static let accent = dynamic(light: 0x4a6741, dark: 0x6B9464)
    /// Glowing green used ONLY for text/marks on translucent glass, always with
    /// a white underglow plate (section 4.7). #5d8a50 / #86b37e.
    static let accentVibrant = dynamic(light: 0x5d8a50, dark: 0x86b37e)
    /// Pale selection background / soft chips. #c8d9c3 / #3D5A36.
    static let accentSoft = dynamic(light: 0xc8d9c3, dark: 0x3D5A36)
    /// Darkened green for small accent text on light opaque surfaces. #3F5A35 / #86B07E.
    static let accentText = dynamic(light: 0x3F5A35, dark: 0x86B07E)
    /// Warm off-white label placed ON the accent fill (never pure white). #f0ece6 / #111111.
    static let onAccent = dynamic(light: 0xf0ece6, dark: 0x111111)

    // MARK: Gold is warning-only

    /// Gold / amber. Warning and caregiving semantic ONLY (cost near budget,
    /// unsaved state, unpriced model, the review-panel Accept). There is no gold
    /// as a general accent in the green pack. #b67a2a / #D9A85F.
    static let gold = dynamic(light: 0xb67a2a, dark: 0xD9A85F)
    /// Alias of `gold`, named for its semantic role.
    static let warning = gold
    /// Warning text tone. #8F5F1E / #D9A85F.
    static let warningText = dynamic(light: 0x8F5F1E, dark: 0xD9A85F)
    /// Soft warning background (warm-smoke chips). #f4e9d2 / #453a20.
    static let warningSoft = dynamic(light: 0xf4e9d2, dark: 0x453a20)

    // MARK: Danger

    /// Danger tone for text/marks. #c8392f / #E06B63.
    static let danger = dynamic(light: 0xc8392f, dark: 0xE06B63)
    /// Danger button fill (darker so a white label clears 4.5:1). #B3332A / #A63E36.
    static let dangerBtnBg = dynamic(light: 0xB3332A, dark: 0xA63E36)
    /// Label ON danger fills. Pure white both appearances.
    static let onDanger = Color.white

    // MARK: Ink / text

    /// Primary reading ink on solid surfaces. Warm near-black. #2b2622 / #E8E2DA.
    static let inkBase = dynamic(light: 0x2b2622, dark: 0xE8E2DA)
    /// Muted / secondary ink and pinned placeholders. #6E6B65 / #9A968E.
    static let mutedBase = dynamic(light: 0x6E6B65, dark: 0x9A968E)

    // Legacy ink names (kept so existing callers keep working).
    /// Legacy primary ink. Prefer `inkBase`.
    static let ink = dynamic(light: 0x1f1e1b, dark: 0xEBEBEA)
    /// Legacy secondary ink.
    static let inkSecondary = dynamic(light: 0x2c3930, dark: 0xB8BCB4)
    /// Legacy muted ink. Prefer `mutedBase`.
    static let inkMuted = dynamic(light: 0x6E6B65, dark: 0x8C8F88)

    // MARK: Surfaces

    /// App canvas. Legacy name, kept for callers.
    static let surface = dynamic(light: 0xf7f5f2, dark: 0x1A1917)
    /// Raised opaque surface. Legacy name, kept for callers.
    static let surfaceRaised = dynamic(light: 0xffffff, dark: 0x24231F)
    /// Reduced-transparency solid backing for regular glass. #fafaf8 / #272521.
    static let surface2 = dynamic(light: 0xfafaf8, dark: 0x272521)
    /// Reduced-transparency solid backing for clear glass. #f0ece4 / #312F2B.
    static let surface3 = dynamic(light: 0xf0ece4, dark: 0x312F2B)

    /// Warm paper tint overlaid on frosted chrome to warm the cool material.
    /// Light: opaque warm grey-white; dark: a low-alpha warm veil.
    static let paperTint = dynamicA(light: 0xf4f1ea, lightAlpha: 1.0,
                                    dark: 0x1E1C19, darkAlpha: 0.55)

    // MARK: Inputs (solid, pinned; never a material)

    /// Text field / editor background. color-mix(#fff 92%, paper-tint) / #2a2c26.
    static let inputBg = dynamic(light: 0xFBFAF7, dark: 0x2A2C26)
    /// Text field / editor hairline border. rgba(0,0,0,0.18) / rgba(255,255,255,0.16).
    static let inputBorder = dynamicA(light: 0x000000, lightAlpha: 0.18,
                                      dark: 0xFFFFFF, darkAlpha: 0.16)

    // MARK: Hairlines and glass rims

    /// General hairline divider. rgba(0,0,0,0.14) / rgba(255,255,255,0.10).
    static let hairline = dynamicA(light: 0x000000, lightAlpha: 0.14,
                                   dark: 0xFFFFFF, darkAlpha: 0.10)
    /// Legacy hairline border colour, kept for callers.
    static let border = dynamic(light: 0xd8d3cc, dark: 0x3a3d38)

    /// Glass rim stroke, the brighter frosted-chrome border. White 0.55, both.
    static let glassRim = Color.white.opacity(0.55)
    /// Top specular highlight on frosted chrome. White 0.60, both.
    static let glassTop = Color.white.opacity(0.60)

    // MARK: dynamic helpers

    /// Build an appearance-adaptive opaque `Color` from two packed 0xRRGGBB ints.
    static func dynamic(light: Int, dark: Int) -> Color {
        dynamicA(light: light, lightAlpha: 1.0, dark: dark, darkAlpha: 1.0)
    }

    /// Build an appearance-adaptive `Color` with per-appearance alpha.
    static func dynamicA(light: Int, lightAlpha: Double,
                         dark: Int, darkAlpha: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return nsColor(hex: isDark ? dark : light,
                           alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    private static func nsColor(hex: Int, alpha: Double) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: CGFloat(alpha)
        )
    }
}

// MARK: - Color short names (component-library surface)

/// Short `Color.<token>` names used throughout the component library (section
/// 6). Each forwards to the corresponding `Alembic` token so there is one
/// palette, two spellings.
extension Color {
    static let accentVibrant = Alembic.accentVibrant
    static let accentSoft    = Alembic.accentSoft
    static let accentText    = Alembic.accentText
    static let onAccent      = Alembic.onAccent

    static let warning       = Alembic.warning
    static let warningText   = Alembic.warningText
    static let warningSoft   = Alembic.warningSoft

    static let danger        = Alembic.danger
    static let dangerBtnBg   = Alembic.dangerBtnBg
    static let onDanger      = Alembic.onDanger

    static let inkBase       = Alembic.inkBase
    static let mutedBase     = Alembic.mutedBase

    static let surface2      = Alembic.surface2
    static let surface3      = Alembic.surface3
    static let paperTint     = Alembic.paperTint

    static let inputBg       = Alembic.inputBg
    static let inputBorder   = Alembic.inputBorder

    static let hairline      = Alembic.hairline
    static let glassRim      = Alembic.glassRim
    static let glassTop      = Alembic.glassTop
}

// MARK: - Metrics: radii, spacing, hairline

/// Corner radii, spacing scale, and hairline width. Radii are three tiers, all
/// drawn `.continuous` (squircle, native macOS feel).
///
///   r1 = 6   small controls: buttons, menu rows, chips
///   r2 = 8   inputs, chips, pills, clear-glass overlays, HUD pill
///   r3 = 12  cards, modal frames, regular-glass chrome, panels
enum AlembicMetrics {
    // Radius tiers.
    static let r1: CGFloat = 6
    static let r2: CGFloat = 8
    static let r3: CGFloat = 12

    // Legacy radius names (kept for callers): radius == r3, radiusInner == r2.
    static let radius: CGFloat = r3
    static let radiusInner: CGFloat = r2

    // Spacing scale (px-equivalent points).
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space5: CGFloat = 20
    static let space6: CGFloat = 24

    static let hairline: CGFloat = 1
}

// MARK: - Motion

/// Motion durations and curves. Hover/press is fast, view/modal show-hide is
/// base, large surface slides are slow; `spring` is the settle-without-overshoot
/// curve `cubic-bezier(0.32,0.72,0,1)`.
enum AlembicMotion {
    static let durFast: Double = 0.12
    static let durBase: Double = 0.18
    static let durSlow: Double = 0.28

    /// 120ms ease-out. Hover and press feedback.
    static let hover = Animation.easeOut(duration: durFast)
    /// 180ms ease-out. View and modal show / hide.
    static let base = Animation.easeOut(duration: durBase)
    /// 280ms ease-out. Large surface slides.
    static let slow = Animation.easeOut(duration: durSlow)
    /// Settle-without-overshoot spring, 280ms.
    static let spring = Animation.timingCurve(0.32, 0.72, 0, 1, duration: durSlow)
}

// MARK: - Shadows (three elevation tiers, dark goes deeper)

/// The three elevation tiers. Cards separate from the canvas by shadow + rim,
/// never z-index. Dark mode goes deeper and softer (higher alpha, larger blur)
/// because shadows read weaker on dark surfaces.
///
///   tier1  resting card
///   tier2  raised chrome, dropdown, HUD pill
///   tier3  modal / review panel, deepest
enum AlembicShadow {
    case tier1, tier2, tier3

    /// Light-appearance shadow parameters.
    var light: (color: Color, radius: CGFloat, y: CGFloat) {
        switch self {
        case .tier1: return (.black.opacity(0.04), 4,  1)
        case .tier2: return (.black.opacity(0.12), 16, 4)
        case .tier3: return (.black.opacity(0.18), 48, 12)
        }
    }

    /// Dark-appearance shadow parameters (deeper, softer).
    var dark: (color: Color, radius: CGFloat, y: CGFloat) {
        switch self {
        case .tier1: return (.black.opacity(0.35), 8,  2)
        case .tier2: return (.black.opacity(0.45), 24, 6)
        case .tier3: return (.black.opacity(0.55), 56, 16)
        }
    }
}

extension View {
    /// Apply an Alembic elevation tier, picking the light or dark parameters for
    /// the current appearance.
    func alShadow(_ tier: AlembicShadow) -> some View {
        modifier(AlembicShadowModifier(tier: tier))
    }
}

private struct AlembicShadowModifier: ViewModifier {
    let tier: AlembicShadow
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let p = scheme == .dark ? tier.dark : tier.light
        return content.shadow(color: p.color, radius: p.radius, x: 0, y: p.y)
    }
}

// MARK: - Focus ring (two-layer)

/// Parameters for the two-layer focus ring (rule C2): an inner accent-vibrant
/// stroke wrapped by a near-white outer stroke, so the ring survives any
/// material or busy wallpaper. Components draw both strokes with
/// `.focusEffectDisabled()` set (see section 6.9).
enum AlembicFocusRing {
    /// Inner stroke colour.
    static let innerColor = Alembic.accentVibrant
    /// Inner stroke width, points.
    static let innerWidth: CGFloat = 2
    /// Outer stroke colour (near-white, guarantees visibility).
    static let outerColor = Color.white.opacity(0.9)
    /// Outer stroke width, points.
    static let outerWidth: CGFloat = 2
    /// Inset (points) the inner accent stroke sits inside the outer white
    /// stroke. The whole ring is drawn WITHIN the control's bounds so the
    /// near-white outer stroke can never bleed outward as a pale halo box.
    static let outerInset: CGFloat = 2
    /// Default corner radius the ring is drawn at (r1).
    static let radius: CGFloat = AlembicMetrics.r1
}

/// Accent-title underglow plate (section 4.7): accent display text on glass
/// never sits bare; it wears a white glow plus a 1px white bottom-plate. Only on
/// glass; removed on opaque panels.
enum AlembicUnderglow {
    static let glowColor = Color.white.opacity(0.65)
    static let glowRadius: CGFloat = 5
    static let plateColor = Color.white.opacity(0.45)
    static let plateY: CGFloat = 1
}

// MARK: - Glass recipes (three frosted surfaces)

/// A reusable frosted-surface definition: the `NSVisualEffectView` material to
/// blur behind the window, the warm tint overlaid on top, the rim + top
/// specular strokes, the corner radius, and the elevation tier. The three
/// ratified recipes are `.regular`, `.clear`, and `.smoke` (section 4.4).
///
/// Consumers (GlassPanel, section 6.1) read these fields; the recipe carries no
/// view of its own so the concrete `NSViewRepresentable` lives with the
/// component.
struct GlassRecipe {
    /// Behind-window material. `nil` for the smoke card, which is a warm solid
    /// tint rather than a live blur.
    let material: NSVisualEffectView.Material?
    /// Warm tint overlaid on the material (already appearance-adaptive).
    let tint: Color
    /// Opacity the tint is drawn at.
    let tintOpacity: Double
    /// Rim border colour (the brighter frosted edge).
    let rim: Color
    /// Rim border width, points.
    let rimWidth: CGFloat
    /// Top specular highlight colour (fades top -> centre).
    let topSpecular: Color
    /// Corner radius, drawn `.continuous`.
    let radius: CGFloat
    /// Elevation tier for the drop shadow.
    let shadow: AlembicShadow
    /// Advisory blur radius (points) matching the CSS recipe; the material bakes
    /// its own blur, so this documents intent for reduced-transparency fallbacks.
    let blurHint: CGFloat
    /// Advisory saturation lift matching the CSS recipe.
    let saturationHint: Double

    /// Regular glass: chrome (sidebars, top bar, modal frames). 24px blur,
    /// warm, `.25` rim, tier-2 depth.
    static let regular = GlassRecipe(
        material: .hudWindow,
        tint: Alembic.paperTint,
        tintOpacity: 0.42,
        rim: Color.white.opacity(0.25),
        rimWidth: 1,
        topSpecular: Alembic.glassTop,
        radius: AlembicMetrics.r3,
        shadow: .tier2,
        blurHint: 24,
        saturationHint: 1.3
    )

    /// Clear glass: small overlays (popovers, tooltips, inline menus). 12px blur,
    /// radius 8, contrast-floor tint, tier-1 depth.
    static let clear = GlassRecipe(
        material: .popover,
        tint: Alembic.paperTint,
        tintOpacity: 0.55,
        rim: Color.white.opacity(0.25),
        rimWidth: 1,
        topSpecular: Alembic.glassTop,
        radius: AlembicMetrics.r2,
        shadow: .tier1,
        blurHint: 12,
        saturationHint: 1.3
    )

    /// Smoke card: the ratified dashboard-card recipe (best for the review
    /// panel). Warm solid tint, brighter `.55` rim and `.6` top specular, a soft
    /// inner glow, tier-3 depth. Feels warmer and more solid than chrome glass.
    static let smoke = GlassRecipe(
        material: nil,
        tint: Alembic.dynamic(light: 0xf4f1ea, dark: 0x24221E),
        tintOpacity: 0.96,
        rim: Alembic.glassRim,
        rimWidth: 1,
        topSpecular: Color.white.opacity(0.6),
        radius: AlembicMetrics.r3,
        shadow: .tier3,
        blurHint: 22,
        saturationHint: 1.25
    )

    /// Soft inner-glow overlay for the smoke card ("lit from within"), a
    /// centre-fading white radial approximating the CSS `inset 0 0 40px`.
    static let smokeInnerGlow = Color.white.opacity(0.12)
}

// MARK: - Fonts (type ramp)

/// The Alembic type ramp. Display / titles ask for the serif design (Source
/// Serif 4 stand-in); everything else uses the system sans (DM Sans stand-in);
/// hotkeys and code use monospaced. No bundled font files: `.system(design:)`
/// picks the platform face, matching the CSS fallback chain.
///
/// The signature move is tiny, heavy, wide-tracked uppercase labels (`alLabel`,
/// `alState`) against the quiet serif for anything that names a thing. Callers
/// still apply `.tracking(...)` and `.textCase(.uppercase)` at the call site
/// (SwiftUI `Font` carries neither).
extension Font {
    /// Chrome title / rail H1. Serif 15 semibold.
    static let alTitle   = Font.system(size: 15, weight: .semibold, design: .serif)
    /// Larger serif title. Serif 17 semibold.
    static let alTitleLg = Font.system(size: 17, weight: .semibold, design: .serif)
    /// Body / note text. Sans 13.
    static let alBody    = Font.system(size: 13, weight: .regular)
    /// Input text. Sans 12.5.
    static let alInput   = Font.system(size: 12.5, weight: .regular)
    /// Button label. Sans 12.5 semibold.
    static let alButton  = Font.system(size: 12.5, weight: .semibold)
    /// Field label. Sans 11 bold.
    static let alFieldLabel = Font.system(size: 11, weight: .bold)
    /// Wide-tracked uppercase section label. Sans 10.5 heavy. Apply
    /// `.tracking(1.3)` + `.textCase(.uppercase)` at the call site.
    static let alLabel   = Font.system(size: 10.5, weight: .heavy)
    /// State caption. Sans 9.5 bold. Apply `.tracking(0.8)` + uppercase.
    static let alState   = Font.system(size: 9.5, weight: .bold)
    /// Mono for hotkeys / code / tabular. 11 regular monospaced.
    static let alMono    = Font.system(size: 11, weight: .regular, design: .monospaced)

    /// Legacy serif display helper. Prefer `alTitle` / `alTitleLg`.
    static func alembicDisplay(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

extension View {
    /// Serif treatment for headline text.
    func alembicSerif() -> some View { self.fontDesign(.serif) }
}
