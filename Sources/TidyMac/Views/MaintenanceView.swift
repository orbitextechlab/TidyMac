import SwiftUI

/// One-click maintenance tasks in a single list card. Each row runs
/// independently: Run → spinner while working → check (or warning) with the
/// outcome inline. "Run All" walks the safe tasks top to bottom.
struct MaintenanceView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var runningID: String?
    @State private var isRunningAll = false
    @State private var results: [String: (message: String, isError: Bool)] = [:]
    @State private var confirmEmptyTrash = false

    /// Gentle per-task icon hues (visual grouping only — status stays semantic).
    private static let hues: [Color] = [
        Theme.accent,
        Color(red: 0.35, green: 0.64, blue: 0.93),
        Color(red: 0.30, green: 0.82, blue: 0.61),
        Color(red: 0.71, green: 0.55, blue: 0.95),
        Color(red: 0.93, green: 0.47, blue: 0.44),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                GlassCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(MaintenanceService.all.enumerated()), id: \.element.id) { index, task in
                            if index > 0 { Divider().opacity(0.5) }
                            taskRow(task, hue: Self.hues[index % Self.hues.count])
                        }
                    }
                }
                Text("Tasks run with elevated permissions — you may be asked for your password.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(28)
            .frame(maxWidth: 1080)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog("Empty the Trash permanently?",
                            isPresented: $confirmEmptyTrash, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) {
                if let task = MaintenanceService.all.first(where: { $0.id == "empty-trash" }) {
                    execute(task)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items in the Trash will be deleted permanently. This cannot be undone.")
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Maintenance").font(.pageTitle)
                Text("One-click fixes for common slowdowns")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button {
                runAll()
            } label: {
                if isRunningAll {
                    HStack(spacing: 7) {
                        SpinnerRing(size: 13, lineWidth: 2, color: .white)
                        Text("Running…")
                    }
                } else {
                    Text("Run All")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(runningID != nil || isRunningAll)
            .help("Runs every task except Empty Trash")
        }
    }

    private func taskRow(_ task: MaintenanceService.Task, hue: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: task.systemImage)
                .font(.system(size: 15))
                .foregroundStyle(hue)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(hue.opacity(0.13))
                )
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(task.title).font(.system(size: 13.5, weight: .semibold))
                    if task.needsAdmin {
                        Image(systemName: "lock")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .help("Requires administrator approval")
                    }
                }
                Text(results[task.id]?.message ?? task.description)
                    .font(.system(size: 11.5))
                    .foregroundStyle(resultColor(for: task))
                    .lineLimit(1)
            }
            Spacer()
            statusControl(task, hue: hue)
                .frame(width: 96, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private func resultColor(for task: MaintenanceService.Task) -> Color {
        guard let result = results[task.id] else { return Theme.textSecondary }
        return result.isError ? Theme.critical : Theme.textSecondary
    }

    @ViewBuilder
    private func statusControl(_ task: MaintenanceService.Task, hue: Color) -> some View {
        if runningID == task.id {
            HStack(spacing: 8) {
                SpinnerRing(size: 13, lineWidth: 2, color: hue)
                Text("Running")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .transition(.opacity)
        } else if let result = results[task.id] {
            HStack(spacing: 8) {
                Image(systemName: result.isError ? "exclamationmark.triangle" : "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(result.isError ? Theme.critical : Theme.ok)
                Button("Again") { start(task) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .disabled(runningID != nil)
            }
            .transition(.opacity)
        } else {
            Button {
                start(task)
            } label: {
                Text("Run")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(hue)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(hue.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .disabled(runningID != nil)
        }
    }

    // MARK: - Actions

    private func start(_ task: MaintenanceService.Task) {
        // Emptying the Trash is irreversible — confirm it.
        if task.id == "empty-trash" { confirmEmptyTrash = true }
        else { execute(task) }
    }

    private func execute(_ task: MaintenanceService.Task, completion: (() -> Void)? = nil) {
        withAnimation(reduceMotion ? nil : Theme.Motion.gentle) {
            runningID = task.id
            results[task.id] = nil
        }
        Task.detached(priority: .userInitiated) {
            let outcome: (String, Bool)
            do {
                outcome = (try task.run(), false)
            } catch {
                // Auth-prompt cancel is a normal action, not a failure.
                outcome = "\(error)".contains("-128")
                    ? ("Cancelled", false)
                    : ("Failed — see Console for details", true)
            }
            await MainActor.run {
                withAnimation(reduceMotion ? nil : Theme.Motion.gentle) {
                    results[task.id] = outcome
                    runningID = nil
                }
                // Physical beat only for a real completion, not for a
                // cancelled auth prompt or a failure.
                if !outcome.1, outcome.0 != "Cancelled" { Haptics.success() }
                completion?()
            }
        }
    }

    /// Run every task except Empty Trash (irreversible), one after another.
    private func runAll() {
        let queue = MaintenanceService.all.filter { $0.id != "empty-trash" }
        guard !queue.isEmpty else { return }
        isRunningAll = true
        runNext(queue, index: 0)
    }

    private func runNext(_ queue: [MaintenanceService.Task], index: Int) {
        guard index < queue.count else { isRunningAll = false; return }
        execute(queue[index]) {
            runNext(queue, index: index + 1)
        }
    }
}
