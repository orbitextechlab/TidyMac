import AppKit

/// Thin wrapper around `NSHapticFeedbackManager` so call sites never reach
/// into AppKit. Only Force Touch trackpads produce a physical click; on other
/// hardware the calls are no-ops, which is the documented system behavior.
///
/// The system performer is used deliberately — the standard patterns
/// (alignment / levelChange / generic) already match what users feel in
/// Apple's own apps, and a custom engine would buy nothing.
///
/// Adapted from PureMac (https://github.com/momenbasel/PureMac),
/// © PureMac Contributors, MIT License. See NOTICE.
enum Haptics {
    /// Light tick — transient UI feedback: a toggle flipped, a chip selected.
    static func tap() {
        perform(.alignment)
    }

    /// Stronger affirmation — a user-visible state change crossed a boundary:
    /// scan finished, cleanup completed, helper installed.
    static func success() {
        perform(.levelChange)
    }

    /// Defaults key for the "Play sound effects" toggle. Defaults to on.
    static let soundEffectsKey = "TidyMac.SoundEffects"

    private static var soundEnabled: Bool {
        UserDefaults.standard.object(forKey: soundEffectsKey) as? Bool ?? true
    }

    /// Completion beat: haptic plus the system "Glass" chime in one call so
    /// the two always land together. The sound intentionally still plays under
    /// Reduce Motion — there it stands in for suppressed celebratory motion.
    static func successWithSound() {
        success()
        guard soundEnabled else { return }
        NSSound(named: "Glass")?.play()
    }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
