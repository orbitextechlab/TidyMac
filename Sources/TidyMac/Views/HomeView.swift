import SwiftUI

/// Landing screen: greeting, the Smart Scan hero with its animated orb,
/// quick stats and shortcuts into the specialised tools.
struct HomeView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var nav: Navigation

    private let engine = CleaningEngine()

    private enum ScanPhase { case idle, scanning, done }

    @State private var phase: ScanPhase = .idle
    @State private var progressText = ""
    @State private var progressFraction: Double = 0
    @State private var cancelFlag = CancelFlag()
    @State private var systemJunkBytes: Int64?
    @State private var xcodeJunkBytes: Int64?
    @State private var appCount: Int?
    @AppStorage("lastSmartScanAt") private var lastScanAt: Double = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                greetingHeader
                heroCard
                quickStats
                SectionHeader(title: "Quick Actions")
                quickActions
            }
            .padding(28)
            .frame(maxWidth: 1080)
            .frame(maxWidth: .infinity)
        }
        .onAppear { if appCount == nil { countApps() } }
        .onDisappear { cancelFlag.cancel() }
    }

    // MARK: - Greeting

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var lastScanLabel: String {
        guard lastScanAt > 0 else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: Date(timeIntervalSince1970: lastScanAt),
                                         relativeTo: Date())
    }

    private var greetingHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text(greeting).font(.pageTitle)
                Text("macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion) · All systems normal")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            HStack(spacing: 4) {
                Text("Last scan:").foregroundStyle(Theme.textSecondary)
                Text(lastScanLabel).fontWeight(.medium)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .neuRaised(99)
        }
    }

    // MARK: - Smart Scan hero

    private var totalJunk: Int64? {
        guard let s = systemJunkBytes, let x = xcodeJunkBytes else { return nil }
        return s + x
    }

    private var heroTitle: String {
        switch phase {
        case .idle: return "Your Mac deserves a sweep"
        case .scanning: return "Looking through caches and junk…"
        case .done:
            if let total = totalJunk, total > 0 { return "\(Format.bytes(total)) can be cleaned" }
            return "Nothing to clean — all tidy"
        }
    }

    private var heroSub: String {
        switch phase {
        case .idle: return "One pass sizes up caches, logs, developer junk, mail attachments and more."
        case .scanning: return progressText.isEmpty ? "Preparing…" : "Scanning \(progressText)…"
        case .done: return "Review each category before anything is removed — nothing is deleted automatically."
        }
    }

    private var heroCard: some View {
        GlassCard(padding: 0) {
            HStack(spacing: 30) {
                orb
                VStack(alignment: .leading, spacing: 5) {
                    Text("SMART SCAN")
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(1.4)
                        .foregroundStyle(Theme.accent)
                    Text(heroTitle)
                        .font(.system(size: 20, weight: .bold))
                        .contentTransition(.opacity)
                    Text(heroSub)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: 520, alignment: .leading)
                    if phase == .done {
                        foundChips.padding(.top, 6)
                    }
                    heroButtons.padding(.top, 10)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .topLeading) {
                RadialGradient(colors: [Theme.accent.opacity(0.10), .clear],
                               center: .init(x: 0.18, y: -0.3),
                               startRadius: 0, endRadius: 520)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: phase)
    }

    /// The animated scan orb: a spinning conic ring around a dark core that
    /// shows the current state — sparkle, live percentage, or the result.
    private var orb: some View {
        ZStack {
            let ring = AngularGradient(
                colors: [Theme.accent.opacity(0.05), Theme.accent.opacity(0.6),
                         Theme.accent, Theme.accent.opacity(0.05)],
                center: .center)
            // The glow never moves: it is radially soft, so rotating it would
            // look identical while forcing a blur re-render every frame.
            Circle().fill(ring)
                .frame(width: 148, height: 148)
                .blur(radius: 22)
                .opacity(0.35)
            // Only the crisp ring turns, and only during a scan — a permanent
            // spin keeps SwiftUI rasterising this view on every display cycle,
            // which costs real CPU for something nobody is watching.
            Circle().fill(ring)
                .frame(width: 148, height: 148)
                .rotationEffect(.degrees(phase == .scanning ? 360 : 0))
                .animation(phase == .scanning
                           ? .linear(duration: 2.4).repeatForever(autoreverses: false)
                           : .easeOut(duration: 0.4),
                           value: phase)
            Circle()
                .fill(Theme.card)
                .overlay(Circle().strokeBorder(Theme.border, lineWidth: 1))
                .frame(width: 130, height: 130)
            orbCore
        }
        .frame(width: 148, height: 148)
    }

    @ViewBuilder
    private var orbCore: some View {
        switch phase {
        case .idle:
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.accent)
        case .scanning:
            VStack(spacing: 2) {
                Text("\(Int(progressFraction * 100))%")
                    .font(.system(size: 26, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: progressFraction)
                Text("SCANNING")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .done:
            if let total = totalJunk, total > 0 {
                VStack(spacing: 1) {
                    Text(Format.bytes(total))
                        .font(.system(size: 21, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.accent)
                    Text("OF JUNK")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Theme.ok)
            }
        }
    }

    private var foundChips: some View {
        HStack(spacing: 8) {
            foundChip("System Junk", bytes: systemJunkBytes, target: .systemJunk)
            foundChip("Xcode Junk", bytes: xcodeJunkBytes, target: .xcodeJunk)
        }
    }

    private func foundChip(_ label: String, bytes: Int64?, target: RootView.Section) -> some View {
        Button {
            nav.autoScanOnArrival = true
            nav.section = target
        } label: {
            HStack(spacing: 7) {
                Circle().fill(Theme.accent).frame(width: 7, height: 7)
                Text(label).foregroundStyle(Theme.textSecondary)
                Text(Format.bytes(bytes ?? 0)).fontWeight(.semibold).monospacedDigit()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .neuRaised(99)
        .help("Review and clean in \(label)")
    }

    @ViewBuilder
    private var heroButtons: some View {
        HStack(spacing: 10) {
            switch phase {
            case .idle:
                Button { smartScan() } label: {
                    Label("Start Smart Scan", systemImage: "magnifyingglass")
                        .padding(.horizontal, 8).padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            case .scanning:
                Button("Stop") { cancelFlag.cancel() }
            case .done:
                if let total = totalJunk, total > 0 {
                    Button {
                        nav.autoScanOnArrival = true
                        nav.section = .systemJunk
                    } label: {
                        Text("Review & Clean \(Format.bytes(total))")
                            .padding(.horizontal, 8).padding(.vertical, 2)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Scan Again") { smartScan() }
            }
        }
    }

    // MARK: - Quick stats

    private var quickStats: some View {
        HStack(spacing: 13) {
            StatTile(label: "Storage",
                     value: Format.bytes(state.disk.totalBytes - state.disk.usedBytes),
                     detail: "free of \(Format.bytes(state.disk.totalBytes))",
                     fraction: state.disk.usedFraction,
                     fillColor: Theme.usage(state.disk.usedFraction))
            StatTile(label: "Memory",
                     value: Format.bytes(state.memory.usedBytes),
                     detail: "in use",
                     fraction: state.memory.usedFraction,
                     fillColor: Theme.usage(state.memory.usedFraction))
            StatTile(label: "Junk Found",
                     value: totalJunk.map(Format.bytes) ?? "—",
                     detail: totalJunk == nil ? "run Smart Scan" : "cleanable",
                     detailColor: totalJunk == nil ? .secondary : Theme.accent)
            StatTile(label: "Apps",
                     value: appCount.map(String.init) ?? "—",
                     detail: "installed")
        }
    }

    // MARK: - Quick actions

    private var quickActions: some View {
        HStack(spacing: 12) {
            quickAction("Large Files", icon: "doc.text.magnifyingglass", target: .largeFiles)
            quickAction("Duplicates", icon: "doc.on.doc", target: .duplicates)
            quickAction("Space Lens", icon: "square.grid.2x2", target: .spaceLens)
            quickAction("Maintenance", icon: "wrench.and.screwdriver", target: .maintenance)
            quickAction("Startup Items", icon: "power", target: .startupItems)
            Spacer()
        }
    }

    private func quickAction(_ title: String, icon: String, target: RootView.Section) -> some View {
        Button {
            nav.section = target
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.accent.opacity(0.13))
                    )
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func smartScan() {
        phase = .scanning
        progressText = ""
        progressFraction = 0
        let flag = CancelFlag()
        cancelFlag = flag
        let engine = self.engine
        let allCategories = CleaningEngine.Category.allCases
        let total = allCategories.count
        var scanned = 0
        Task.detached(priority: .userInitiated) {
            let items = engine.scan(progress: { category in
                scanned += 1
                let fraction = Double(scanned) / Double(total)
                Task { @MainActor in
                    progressText = category
                    progressFraction = min(1, fraction)
                }
            }, isCancelled: flag.isCancelled)
            let devSet = Set(CleaningEngine.developerJunkCategories)
            let dev = items.filter { devSet.contains($0.category) }.reduce(Int64(0)) { $0 + $1.sizeBytes }
            let system = items.reduce(Int64(0)) { $0 + $1.sizeBytes } - dev
            await MainActor.run {
                guard !flag.isCancelled() else { phase = .idle; return }
                systemJunkBytes = system
                xcodeJunkBytes = dev
                lastScanAt = Date().timeIntervalSince1970
                // Hand the full results to the cleaner screens so navigating
                // there shows them instantly instead of rescanning.
                nav.smartScanItems = items
                nav.smartScanAt = Date()
                phase = .done
            }
        }
    }

    private func countApps() {
        Task.detached(priority: .utility) {
            let count = (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: "/Applications"), includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "app" }.count ?? 0
            await MainActor.run { appCount = count }
        }
    }
}
