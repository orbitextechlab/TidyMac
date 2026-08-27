import Foundation
import Combine

/// A user-configured, opt-in maintenance schedule.
///
/// `autoCleanCategories` empty means scan only, which is the default and the
/// only state a fresh install can be in. Cleaning without a human present is
/// the highest-consequence thing this app does, so it has to be asked for
/// twice: once by turning the schedule on, once per category.
struct ScheduleConfig: Codable, Equatable {

    enum Cadence: String, Codable, CaseIterable, Identifiable {
        case off, weekly, monthly
        var id: String { rawValue }

        var label: String {
            switch self {
            case .off: return "Off"
            case .weekly: return "Weekly"
            case .monthly: return "Monthly"
            }
        }

        /// Nominal spacing between runs. Months vary; 30 days is close enough
        /// for housekeeping and avoids calendar arithmetic that can land on a
        /// day that does not exist.
        var interval: TimeInterval? {
            switch self {
            case .off: return nil
            case .weekly: return 7 * 86_400
            case .monthly: return 30 * 86_400
            }
        }
    }

    var cadence: Cadence = .off
    /// Categories cleaned without review. Always a subset of the categories
    /// that are safe to pre-select — see `SchedulerService.eligibleCategories`.
    var autoCleanCategories: [CleaningEngine.Category] = []
    var lastRunDate: Date?
    /// When the schedule was switched on. The clock has to start somewhere, and
    /// a schedule that has never run has no `lastRunDate` to count from.
    var scheduledSince: Date?
    /// Derived, never trusted from disk. Persisted only so the UI can show the
    /// next run without recomputing it, and recomputed on every load.
    var nextRunDate: Date?
}

/// Owns the schedule: persistence, when the next run is due, and the tick that
/// fires it. It decides *when*; `AppState` decides *what* a run does.
///
/// Deliberately an in-app timer rather than a `launchd` agent. Cleaning needs
/// the app's own engine, and a launch agent would mean a second background
/// surface running as the user for a feature that works perfectly well while
/// the app is open. The cost is stated plainly in Settings: schedules run only
/// while TidyMac is running.
@MainActor
final class SchedulerService: ObservableObject {

    private static let storageKey = "scheduleConfig"
    /// How often we check whether the next run is due. A single long-fuse
    /// timer would be simpler but does not survive sleep — this re-checks the
    /// wall clock instead of trusting elapsed timer time.
    private static let tickInterval: TimeInterval = 60

    @Published private(set) var config = ScheduleConfig()

    /// Called when a run comes due. Set by `AppState` before `start()`.
    var onFire: (([CleaningEngine.Category]) -> Void)?

    private var tick: AnyCancellable?
    /// Guards against a second run starting while the first is still going —
    /// the tick keeps firing during a long scan.
    private var isFiring = false

    /// The only categories a schedule may clean unattended. Everything else
    /// carries a warning and is unselected after a manual scan by definition:
    /// it needs review, and a schedule cannot review.
    static var eligibleCategories: [CleaningEngine.Category] {
        CleaningEngine.Category.allCases.filter(\.isPreselected)
    }

    // MARK: - Lifecycle

    func start() {
        config = Self.sanitised(load())
        evaluate(runIfDue: true)
        scheduleTick()
    }

    /// Apply an edit from Settings. Any change re-derives the next run so the
    /// UI never shows a stale date, and an edit alone never fires a run.
    func update(_ transform: (inout ScheduleConfig) -> Void) {
        var next = config
        transform(&next)
        config = Self.sanitised(next)
        evaluate(runIfDue: false)
        save()
        scheduleTick()
    }

    /// Record that a run finished, and push the next one a full interval out.
    func markRun(at date: Date = Date()) {
        config.lastRunDate = date
        config.nextRunDate = config.cadence.interval.map { date.addingTimeInterval($0) }
        isFiring = false
        save()
    }

    /// Release the guard without recording a run — for a run that could not
    /// start, so the next tick can try again.
    func abandonRun() { isFiring = false }

    // MARK: - Scheduling

    private func scheduleTick() {
        tick?.cancel()
        guard config.cadence != .off else { return }
        tick = Timer.publish(every: Self.tickInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.evaluate(runIfDue: true) }
    }

    /// Work out when the next run should be, and optionally fire an overdue one.
    ///
    /// `lastRunDate` is the only authority here. A persisted `nextRunDate` is
    /// never read back as a trigger (see `sanitised`), so the worst a tampered
    /// or corrupt preferences file can do is bring one run forward — the same
    /// thing a genuinely missed window does — rather than fire a clean on
    /// every launch.
    private func evaluate(runIfDue: Bool) {
        guard let interval = config.cadence.interval else {
            config.nextRunDate = nil
            return
        }
        let now = Date()

        // The clock runs from the last completed run, or from the moment the
        // schedule was switched on if it has never run. That anchor is written
        // down once: recomputing it from "now" on every tick would push the due
        // date away a minute at a time and the schedule would never come round.
        if config.lastRunDate == nil, config.scheduledSince == nil {
            config.scheduledSince = now
            save()
        }
        guard let anchor = config.lastRunDate ?? config.scheduledSince else { return }

        let due = anchor.addingTimeInterval(interval)
        config.nextRunDate = due
        guard now >= due, runIfDue, !isFiring else { return }

        // Overdue — including a window missed while the app was closed. Run
        // once and re-schedule from now; never replay every missed window.
        isFiring = true
        onFire?(config.autoCleanCategories)
    }

    // MARK: - Persistence

    private func load() -> ScheduleConfig {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode(ScheduleConfig.self, from: data)
        else { return ScheduleConfig() }
        return decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    /// Every rule that must hold no matter what is on disk or what a view asked
    /// for. Applied on load *and* on edit, so there is one place to read.
    private static func sanitised(_ raw: ScheduleConfig) -> ScheduleConfig {
        var config = raw
        let eligible = Set(eligibleCategories)

        // A category that needs review can never be cleaned unattended, even if
        // it reaches us through a hand-edited preferences file.
        config.autoCleanCategories = config.autoCleanCategories
            .filter { eligible.contains($0) }
            .reduce(into: []) { unique, category in
                if !unique.contains(category) { unique.append(category) }
            }

        // Discard the persisted next-run date outright: it is a display value
        // derived from `lastRunDate`, and honouring one written into the past
        // is exactly how a schedule gets fired on demand by anything that can
        // write this app's preferences.
        config.nextRunDate = nil

        // A last-run date in the future is a clock change or a tamper. Treat it
        // as "just ran" — the conservative reading, since it delays the next
        // run rather than bringing it forward.
        if let last = config.lastRunDate, last > Date() { config.lastRunDate = Date() }
        if let since = config.scheduledSince, since > Date() { config.scheduledSince = Date() }

        // Switching a schedule off retires its anchor, so switching it back on
        // starts a fresh interval instead of counting the idle time in between.
        if config.cadence == .off { config.scheduledSince = nil }

        return config
    }
}
