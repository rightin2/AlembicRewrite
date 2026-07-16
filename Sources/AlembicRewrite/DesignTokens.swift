//
//  DesignTokens.swift
//  AlembicRewrite
//
//  The Alembic design language, ported from the web app's globals.css /
//  glass.css into SwiftUI primitives. Colours, spacing, corner radius, and font
//  helpers live here so every view reads from one palette.
//
//  Fonts are NOT bundled: display type asks for the serif design (SwiftUI falls
//  back to the system serif, standing in for Source Serif 4) and body type uses
//  the system sans (standing in for DM Sans). No @font-face, no shipped files.
//
//  Colour sources (globals.css):
//    --accent          #4a6741  (light)   #6B9464 (dark)
//    vibrant accent    #86b37e
//    --text-primary    #1a1a1a  (light)   #EBEBEA (dark)
//    warm ink          #1f1e1b
//    --surface-0       #f7f5f2  (light)   #1A1917 (dark)
//    gold accent       rgb(0.85, 0.72, 0.35)  (used sparingly)
//

import SwiftUI

// MARK: - Palette

/// Alembic colours as light/dark dynamic `Color`s. Each token resolves to the
/// right hue for the current appearance via `NSColor(name:dynamicProvider:)`.
enum Alembic {

    // Brand green family.
    /// Base brand green. Primary accent on buttons and selection.
    static let accent = dynamic(light: 0x4a6741, dark: 0x6B9464)
    /// Vibrant green, used for highlights that want a touch more life.
    static let accentVibrant = dynamic(light: 0x6B9464, dark: 0x86b37e)
    /// Soft green tint for selection backgrounds on light surfaces.
    static let accentSoft = dynamic(light: 0xc8d9c3, dark: 0x2f3d2b)

    /// Gold accent, used sparingly (e.g. the Accept affordance). Matches
    /// Color(red: 0.85, green: 0.72, blue: 0.35) from the brief.
    static let gold = Color(red: 0.85, green: 0.72, blue: 0.35)

    // Ink / text. Warm ink (#1f1e1b) on light, near-white on dark.
    static let ink = dynamic(light: 0x1f1e1b, dark: 0xEBEBEA)
    static let inkSecondary = dynamic(light: 0x2c3930, dark: 0xB8BCB4)
    static let inkMuted = dynamic(light: 0x6E6B65, dark: 0x8C8F88)

    // Surfaces.
    static let surface = dynamic(light: 0xf7f5f2, dark: 0x1A1917)
    static let surfaceRaised = dynamic(light: 0xffffff, dark: 0x24231F)

    // Hairline border.
    static let border = dynamic(light: 0xd8d3cc, dark: 0x3a3d38)

    /// Text colour to place on top of the green accent fill.
    static let onAccent = Color(red: 0.94, green: 0.93, blue: 0.90)

    // MARK: dynamic helper

    /// Build an appearance-adaptive Color from two packed 0xRRGGBB ints.
    static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return nsColor(hex: isDark ? dark : light)
        })
    }

    private static func nsColor(hex: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Metrics

/// Corner radius, spacing scale, and hairline width, mirroring the web tokens
/// (radius 12 on chrome, 8 on inner controls).
enum AlembicMetrics {
    static let radius: CGFloat = 12
    static let radiusInner: CGFloat = 8

    // Spacing scale (px-equivalent points).
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space5: CGFloat = 20

    static let hairline: CGFloat = 1
}

// MARK: - Fonts

/// Font helpers. Display = serif design (Source Serif 4 stand-in), body = system
/// sans (DM Sans stand-in). No bundled font files.
extension Font {
    /// Serif display heading. Pass the size and weight.
    static func alembicDisplay(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

extension View {
    /// Serif treatment for headline text.
    func alembicSerif() -> some View { self.fontDesign(.serif) }
}
