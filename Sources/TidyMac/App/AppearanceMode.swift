import AppKit
import SwiftUI

/// User-selectable appearance that overrides the system setting.
///
/// Applied through `NSApplication.shared.appearance` rather than SwiftUI's
/// `.preferredColorScheme` on purpose: resetting preferredColorScheme back to
/// nil ("System") inside a live window only re-themes the titlebar — the
/// content's colorScheme environment is not re-evaluated until the window
/// resigns key. The AppKit route applies instantly and also themes windows
/// outside the main scene: Settings, menus, popovers, the menu bar extra.
/// (Approach documented by PureMac, MIT — see NOTICE.)
///
/// `Theme.dynamic(dark:light:)` colors resolve through `NSColor(name:)`
/// dynamic providers, which follow the effective appearance automatically, so
/// the whole Sweep palette flips with no further work.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    /// Defaults key backing the Settings picker.
    static let storageKey = "TidyMac.Appearance"

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    private var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// Applies this mode to every window the app owns, now and future.
    func apply() {
        NSApplication.shared.appearance = nsAppearance
    }

    /// Reads the stored preference and applies it — called once at launch.
    static func applyStored() {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        (AppearanceMode(rawValue: raw) ?? .system).apply()
    }
}
