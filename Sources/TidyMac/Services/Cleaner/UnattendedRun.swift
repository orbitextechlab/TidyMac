import Foundation

/// One scan, plus an optional clean restricted to named categories, performed
/// with nobody watching.
///
/// Pure engine work — no timers, no UI — so the scheduler and the menu bar's
/// Scan Now share a single definition of what a background run does, and that
/// definition can be reasoned about on its own.
enum UnattendedRun {

    struct Result {
        /// Total size of everything the scan found, before any cleaning.
        var foundBytes: Int64 = 0
        var freedBytes: Int64 = 0
        var freedCount = 0
        /// Everything still on disk afterwards, including items the clean could
        /// not remove. Handed to the cleaner screens so opening the window
        /// shows results instead of starting another scan.
        var remaining: [CleaningEngine.Item] = []
    }

    /// - Parameter autoClean: categories to trash without review. Empty means
    ///   scan only. Callers must pass only categories the user explicitly
    ///   opted in to; `SchedulerService` is what enforces that.
    static func perform(autoClean: [CleaningEngine.Category] = [],
                        engine: CleaningEngine = CleaningEngine(),
                        isCancelled: @escaping () -> Bool = { false }) -> Result {
        let items = engine.scan(isCancelled: isCancelled)
        var result = Result()
        result.foundBytes = items.reduce(0) { $0 + $1.sizeBytes }
        result.remaining = items

        let wanted = Set(autoClean)
        guard !wanted.isEmpty, !isCancelled() else { return result }

        var selected = items.filter { wanted.contains($0.category) }
        guard !selected.isEmpty else { return result }
        for index in selected.indices { selected[index].isSelected = true }

        let cleaned = engine.trashSelected(selected)
        result.freedBytes = cleaned.trashedBytes + cleaned.deletedBytes
        result.freedCount = cleaned.trashedCount + cleaned.deletedCount

        // Whatever the clean could not handle stays in the results so the
        // window still shows it. Permission failures are reported, never
        // escalated to a privileged delete: that step always needs a human.
        let unresolved = Set(cleaned.needsAdmin.map(\.id))
        let skipped = Set(cleaned.skipped.map(\.path))
        result.remaining = items.filter { item in
            guard wanted.contains(item.category) else { return true }
            return unresolved.contains(item.id) || skipped.contains(item.url.path)
        }
        return result
    }
}
