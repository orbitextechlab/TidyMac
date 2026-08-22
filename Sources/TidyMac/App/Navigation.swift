import SwiftUI

/// Which screen is showing, plus the hand-off between Home's Smart Scan and the
/// cleaner screens.
///
/// Deliberately separate from `AppState`: the metrics there change every couple
/// of seconds, and anything observing that object rebuilds and re-lays out on
/// every tick — a periodic hitch in any long scrolling list. The navigation
/// shell observes only this object, so it rebuilds when the user navigates and
/// at no other time.
@MainActor
final class Navigation: ObservableObject {
    @Published var section: RootView.Section = .home

    // MARK: - Smart Scan hand-off
    // Home's Smart Scan parks its full results here so the cleaner screens can
    // show them instantly instead of rescanning. Plain properties, not
    // @Published: they are read on arrival, and publishing them would rebuild
    // the shell for no reason.

    var smartScanItems: [CleaningEngine.Item] = []
    var smartScanAt: Date?
    /// Set when navigation comes from a "review results" action — the target
    /// cleaner starts a scan by itself if it has nothing cached to show.
    var autoScanOnArrival = false

    /// Take the cached Smart Scan items for `categories`, if still fresh.
    /// Consuming prevents re-adopting stale rows after the user cleans them.
    func takeSmartScanItems(for categories: [CleaningEngine.Category]) -> [CleaningEngine.Item]? {
        guard let at = smartScanAt, Date().timeIntervalSince(at) < 600 else { return nil }
        let wanted = Set(categories)
        let mine = smartScanItems.filter { wanted.contains($0.category) }
        guard !mine.isEmpty else { return nil }
        smartScanItems.removeAll { wanted.contains($0.category) }
        return mine
    }
}
