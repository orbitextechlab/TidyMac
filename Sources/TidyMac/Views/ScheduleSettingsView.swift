import SwiftUI

/// The Schedule tab in Settings.
///
/// Written to make the trade-offs impossible to miss rather than to look tidy:
/// the app has to be running, unattended cleaning is off until it is ticked one
/// category at a time, and everything else still waits for review.
struct ScheduleSettingsView: View {
    @EnvironmentObject private var state: AppState

    // The schedule lives on AppState but publishes its own changes, so the
    // content observes it directly — reading it through AppState alone would
    // leave the toggles a beat behind the value they are bound to.
    var body: some View {
        ScheduleSettingsContent(scheduler: state.scheduler)
    }
}

private struct ScheduleSettingsContent: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var scheduler: SchedulerService

    private var config: ScheduleConfig { scheduler.config }

    private var cadence: Binding<ScheduleConfig.Cadence> {
        Binding(get: { config.cadence },
                set: { value in scheduler.update { $0.cadence = value } })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                cadenceSection
                if config.cadence != .off {
                    statusSection
                    Divider()
                    autoCleanSection
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Cadence

    private var cadenceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Run maintenance", selection: cadence) {
                ForEach(ScheduleConfig.Cadence.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)

            Text("Schedules run only while TidyMac is open. A run missed while "
                 + "the app was closed happens once the next time you open it — "
                 + "never several times over to catch up.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Auto-clean

    private var autoCleanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Clean without asking")
                .font(.callout.weight(.semibold))

            Text(config.autoCleanCategories.isEmpty
                 ? "Nothing selected — scheduled runs only scan and report."
                 : "Selected categories are moved to the Trash automatically.")
                .font(.caption).foregroundStyle(.secondary)

            // Two columns, so the note underneath stays above the fold: it is
            // the part that explains what is deliberately missing from this
            // list, and a reader who has to scroll for it will not find it.
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                ForEach(SchedulerService.eligibleCategories) { category in
                    Toggle(isOn: binding(for: category)) {
                        Label(category.rawValue, systemImage: category.systemImage)
                            .font(.callout)
                            .lineLimit(1)
                    }
                }
            }

            Text("Only categories that always regenerate can be listed here. "
                 + "Downloads, Trash, device backups and Xcode archives can hold "
                 + "something you still want, so they always wait for you.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func binding(for category: CleaningEngine.Category) -> Binding<Bool> {
        Binding(
            get: { config.autoCleanCategories.contains(category) },
            set: { isOn in
                scheduler.update { config in
                    if isOn {
                        if !config.autoCleanCategories.contains(category) {
                            config.autoCleanCategories.append(category)
                        }
                    } else {
                        config.autoCleanCategories.removeAll { $0 == category }
                    }
                }
            }
        )
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow("Next run", value: Self.absolute(config.nextRunDate))
            statusRow("Last run", value: Self.absolute(config.lastRunDate))

            Button {
                state.runBackgroundScan()
            } label: {
                Label(state.isBackgroundScanning ? "Scanning…" : "Scan Now",
                      systemImage: "sparkle.magnifyingglass")
            }
            .disabled(state.isBackgroundScanning)
            .help("Scan straight away without cleaning anything")
        }
    }

    private func statusRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout.monospacedDigit())
        }
    }

    private static func absolute(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
