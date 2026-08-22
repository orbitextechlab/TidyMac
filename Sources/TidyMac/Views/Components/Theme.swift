import SwiftUI
import AppKit

/// Central design tokens — "Sweep" design language: warm dark charcoal
/// surfaces, flat cards with hairline borders, one orange accent, and glowing
/// gradient meters. Depth comes from subtle borders and glows, not shadows.
enum Theme {

    // MARK: - Accent & semantics

    /// Primary accent — warm orange (#ED8A3C).
    static let accent = Color(red: 0.929, green: 0.541, blue: 0.235)

    /// Status colors: mint green is reserved for "everything OK" only.
    static let ok = Color(red: 0.30, green: 0.82, blue: 0.61)
    static let warning = Color(red: 0.929, green: 0.541, blue: 0.235)
    static let critical = Color(red: 0.94, green: 0.35, blue: 0.30)

    /// Neutral meter fill for values that are simply "normal".
    static let neutralFill = Color.primary.opacity(0.28)

    // MARK: - Surfaces
    // Warm charcoal window, slightly lighter cards, hairline borders.

    /// Window background (#191715 dark / warm off-white light).
    static let surface = dynamic(dark: NSColor(red: 0.098, green: 0.090, blue: 0.082, alpha: 1),
                                 light: NSColor(red: 0.949, green: 0.937, blue: 0.918, alpha: 1))
    /// Semi-opaque surface layered over the behind-window blur — the window
    /// shell of the design (rgba(24,22,20,.86) over the wallpaper).
    static let surfaceTint = dynamic(dark: NSColor(red: 0.098, green: 0.090, blue: 0.082, alpha: 0.84),
                                     light: NSColor(red: 0.949, green: 0.937, blue: 0.918, alpha: 0.80))
    /// Card background (#201D1A dark / white light).
    static let card = dynamic(dark: NSColor(red: 0.125, green: 0.114, blue: 0.102, alpha: 1),
                              light: NSColor(white: 1, alpha: 1))
    /// Card hover tint — warms slightly toward the accent.
    static let cardHover = dynamic(dark: NSColor(red: 0.141, green: 0.125, blue: 0.098, alpha: 1),
                                   light: NSColor(red: 0.98, green: 0.965, blue: 0.94, alpha: 1))

    /// Hairline card border.
    static let border = dynamic(dark: NSColor(white: 1, alpha: 0.07),
                                light: NSColor(white: 0, alpha: 0.08))
    /// Quiet fill for chips, pills and inline badges.
    static let chipFill = dynamic(dark: NSColor(white: 1, alpha: 0.05),
                                  light: NSColor(white: 0, alpha: 0.045))
    /// Empty track behind meters.
    static let track = dynamic(dark: NSColor(white: 1, alpha: 0.045),
                               light: NSColor(white: 0, alpha: 0.06))

    /// Warm-tinted secondary text (#A8A199 dark).
    static let textSecondary = dynamic(dark: NSColor(red: 0.659, green: 0.631, blue: 0.600, alpha: 1),
                                       light: NSColor(red: 0.42, green: 0.40, blue: 0.37, alpha: 1))
    /// Muted labels — section headers, fine print (#6E6862 dark).
    static let textMuted = dynamic(dark: NSColor(red: 0.431, green: 0.408, blue: 0.384, alpha: 1),
                                   light: NSColor(red: 0.55, green: 0.53, blue: 0.50, alpha: 1))

    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    // MARK: - Value→color mapping (meaning, not decoration)

    /// Temperature: neutral until warm, orange when hot, red when critical.
    static func temperature(_ celsius: Double) -> Color {
        switch celsius {
        case ..<70: return .secondary
        case ..<85: return warning
        default: return critical
        }
    }

    /// Usage fraction (CPU/RAM/disk): neutral normally, escalate near limits.
    static func usage(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.8: return neutralFill
        case ..<0.95: return warning
        default: return critical
        }
    }
}

// MARK: - Typography scale

extension Font {
    /// Page title — 24pt bold, tight tracking.
    static let pageTitle = Font.system(size: 24, weight: .bold)
    /// Big stat value — bold, tabular digits via monospacedDigit().
    static let statValue = Font.system(size: 21, weight: .bold)
    /// Small uppercase stat label.
    static let statLabel = Font.system(size: 10.5, weight: .semibold)
    /// Section header — small uppercase tracked label.
    static let sectionHeader = Font.system(size: 11, weight: .semibold)
}
