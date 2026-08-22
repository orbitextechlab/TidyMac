import SwiftUI

/// Mini task manager: live top processes by CPU or memory, with quit and
/// force-quit. Refreshes on its own timer while visible.
struct ProcessesView: View {
    private enum SortKey: String, CaseIterable {
        case cpu = "CPU"
        case memory = "Memory"
    }

    @State private var processes: [ProcessService.ProcessInfo] = []
    @State private var sortKey: SortKey = .cpu
    @State private var status: String?
    @State private var timer: Timer?

    private var sorted: [ProcessService.ProcessInfo] {
        switch sortKey {
        case .cpu: return processes
        case .memory: return processes.sorted { $0.rssBytes > $1.rssBytes }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            list
        }
        .onAppear { startSampling() }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Processes").font(.pageTitle)
                Text(status ?? "Top consumers, refreshed every 3 seconds")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $sortKey) {
                ForEach(SortKey.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            .labelsHidden()
        }
        .padding(20)
    }

    private var list: some View {
        List(sorted.prefix(30)) { proc in
            HStack(spacing: 10) {
                if let icon = proc.icon {
                    Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                } else {
                    Image(systemName: "gearshape")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                }
                Text(proc.name).lineLimit(1)
                if !proc.isApp {
                    Text("background").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Text(String(format: "%.1f%%", proc.cpuPercent))
                    .monospacedDigit()
                    .foregroundStyle(proc.cpuPercent > 80 ? Theme.warning : .secondary)
                    .frame(width: 56, alignment: .trailing)
                Text(Format.bytes(proc.rssBytes))
                    .monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .trailing)
                Menu {
                    Button("Quit") { terminate(proc, force: false) }
                    Button("Force Quit", role: .destructive) { terminate(proc, force: true) }
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 34)
                .disabled(proc.id == ProcessInfo.processInfo.processIdentifier)
            }
            .font(.system(size: 12))
        }
        .listStyle(.inset)
    }

    // MARK: - Actions

    private func startSampling() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in refresh() }
    }

    private func refresh() {
        Task.detached(priority: .utility) {
            let sample = ProcessService.sample()
            await MainActor.run { processes = sample }
        }
    }

    private func terminate(_ proc: ProcessService.ProcessInfo, force: Bool) {
        let ok = ProcessService.terminate(proc, force: force)
        status = ok
            ? "\(proc.name) was asked to \(force ? "force quit" : "quit")"
            : "Couldn't quit \(proc.name) — it may belong to another user or the system"
        refresh()
    }
}
