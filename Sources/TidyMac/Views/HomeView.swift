import SwiftUI

/// Landing screen: greeting, the Smart Scan hero with its animated orb,
/// quick stats and shortcuts into the specialised tools.
struct HomeView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var nav: Navigation

    private let engine = CleaningEngine()

    /// The hero's state machine. `review` means scan results are on screen
    /// and nothing has been removed; `cleaning`/`success` only occur for the
    /// safe-items cleanup started from Home itself — the full review flow
    /// still lives in the cleaner screens.
    private enum ScanPhase { case idle, scanning, review, cleaning, success }

    @State private var phase: ScanPhase = .idle
    @State private var freedBytes: Int64 = 0
    @State private var cleanedCount = 0
    @State private var leftoverCount = 0
    @State private var confettiBurst = 0
    @State private var progressText = ""
    @State private var progressFraction: Double = 0
    @State private var cancelFlag = CancelFlag()
    @State private var systemJunkBytes: Int64?
    @State private var xcodeJunkBytes: Int64?
    @State private var appCount: Int?

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
        guard state.lastScanAt > 0 else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: Date(timeIntervalSince1970: state.lastScanAt),
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
        case .review:
            if let total = totalJunk, total > 0 { return "\(Format.bytes(total)) can be cleaned" }
            return "Nothing to clean — all tidy"
        case .cleaning: return "Sweeping safe items…"
        case .success: return "Freed \(Format.bytes(freedBytes))"
        }
    }

    private var heroSub: String {
        switch phase {
        case .idle: return "One pass sizes up caches, logs, developer junk, mail attachments and more."
        case .scanning: return progressText.isEmpty ? "Preparing…" : "Scanning \(progressText)…"
        case .review: return "Review each category before anything is removed — nothing is deleted automatically."
        case .cleaning: return "Moving caches, logs and developer junk to the Trash — recoverable until you empty it."
        case .success:
            var text = "Moved \(cleanedCount) items to the Trash."
            if leftoverCount > 0 { text += " \(leftoverCount) needed a closer look — see the cleanup screens." }
            return text
        }
    }

    private var heroCard: some View {
        GlassCard(padding: 0) {
            HStack(spacing: 30) {
                orb
                // The orb stays mounted as the hero's anchor; only this
                // column swaps per phase, rising in and dissolving out.
                VStack(alignment: .leading, spacing: 5) {
                    Text(phase == .success ? "ALL CLEAN" : "SMART SCAN")
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(1.4)
                        .foregroundStyle(phase == .success ? Theme.ok : Theme.accent)
                    Text(heroTitle)
                        .font(.system(size: 20, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .opacity : .numericText())
                    Text(heroSub)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: 520, alignment: .leading)
                    if phase == .review {
                        foundChips.padding(.top, 6)
                            .transition(.opacity)
                    }
                    heroButtons.padding(.top, 10)
                }
                .id(phase)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 12)).combined(with: .scale(scale: 0.985)),
                    removal: .opacity))
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
        // Celebration bursts from the orb; purely decorative, so it neither
        // intercepts clicks nor renders under Reduce Motion.
        .overlay {
            ConfettiView(burst: confettiBurst, origin: UnitPoint(x: 0.12, y: 0.45))
        }
        .animation(reduceMotion ? nil : Theme.Motion.gentle, value: phase)
    }

    /// The animated scan orb: a spinning conic ring around a dark core that
    /// shows the current state — sparkle, live percentage, or the result.
    /// The ring's tint tracks the phase: accent while working, green once
    /// the sweep has succeeded.
    private var ringColor: Color { phase == .success ? Theme.ok : Theme.accent }

    private var orb: some View {
        ZStack {
            let ring = AngularGradient(
                colors: [ringColor.opacity(0.05), ringColor.opacity(0.6),
                         ringColor, ringColor.opacity(0.05)],
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
                // Under Reduce Motion the ring holds still; the percentage
                // readout in the core is the progress signal.
                .rotationEffect(.degrees((phase == .scanning || phase == .cleaning) && !reduceMotion ? 360 : 0))
                .animation(reduceMotion ? nil
                           : (phase == .scanning || phase == .cleaning) ? Theme.Motion.orbit
                           : Theme.Motion.gentle,
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
                    .animation(reduceMotion ? nil : Theme.Motion.snappy, value: progressFraction)
                Text("SCANNING")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .review:
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
        case .cleaning:
            SpinnerRing(size: 30, lineWidth: 3)
        case .success:
            Image(systemName: "checkmark")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Theme.ok)
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
            case .review:
                if let total = totalJunk, total > 0 {
                    Button {
                        nav.autoScanOnArrival = true
                        nav.section = .systemJunk
                    } label: {
                        Text("Review & Clean \(Format.bytes(total))")
                            .padding(.horizontal, 8).padding(.vertical, 2)
                    }
                    .buttonStyle(.borderedProminent)
                    if hasSafeItems {
                        Button("Sweep Safe Items") { cleanSafeItems() }
                            .help("Trash caches, logs and developer junk — the categories that never hold personal files. Recoverable from the Trash.")
                    }
                }
                Button("Scan Again") { smartScan() }
            case .cleaning:
                EmptyView()
            case .success:
                Button("Done") {
                    withAnimation(reduceMotion ? nil : Theme.Motion.gentle) { phase = .idle }
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
        .buttonStyle(PressableCardStyle())
    }

    // MARK: - Actions

    private func smartScan() {
        withAnimation(reduceMotion ? nil : Theme.Motion.gentle) { phase = .scanning }
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
                guard !flag.isCancelled() else {
                    withAnimation(reduceMotion ? nil : Theme.Motion.gentle) { phase = .idle }
                    return
                }
                systemJunkBytes = system
                xcodeJunkBytes = dev
                state.lastScanAt = Date().timeIntervalSince1970
                state.lastScanBytes = Int(system + dev)
                // Hand the full results to the cleaner screens so navigating
                // there shows them instantly instead of rescanning.
                nav.smartScanItems = items
                nav.smartScanAt = Date()
                withAnimation(reduceMotion ? nil : Theme.Motion.gentle) { phase = .review }
                // A finished scan is a boundary worth a physical beat.
                Haptics.success()
            }
        }
    }

    /// Whether the last scan found anything in the categories that are safe
    /// to remove without review (never hold personal files, recoverable).
    private var hasSafeItems: Bool {
        nav.smartScanItems.contains { $0.category.isPreselected }
    }

    /// The one cleanup Home performs itself: trash the items in preselected
    /// (safe) categories from the last scan. Everything else keeps requiring
    /// the per-category review screens — this deliberately never touches a
    /// category that can hold personal files.
    private func cleanSafeItems() {
        var safe = nav.smartScanItems.filter { $0.category.isPreselected }
        guard !safe.isEmpty else { return }
        for i in safe.indices { safe[i].isSelected = true }
        // Take the safe items out of the shared cache *before* the work starts.
        // The sidebar stays clickable during the sweep, and a cleaner screen
        // that adopts these rows mid-flight would show files being deleted
        // underneath it. Leftovers are put back when the result is known.
        nav.smartScanItems.removeAll { $0.category.isPreselected }
        withAnimation(reduceMotion ? nil : Theme.Motion.gentle) { phase = .cleaning }
        let engine = self.engine
        let items = safe
        Task.detached(priority: .userInitiated) {
            let result = engine.trashSelected(items)
            await MainActor.run {
                // Anything not handled goes back into the shared cache so the
                // cleaner screens still show it: admin-only items and skips.
                let skippedSet = Set(result.skipped.map(\.path))
                let leftovers = result.needsAdmin
                    + items.filter { skippedSet.contains($0.url.path) }
                nav.smartScanItems.append(contentsOf: leftovers)

                // Refresh the review numbers from what actually remains.
                let devSet = Set(CleaningEngine.developerJunkCategories)
                let remaining = nav.smartScanItems
                let devLeft = remaining.filter { devSet.contains($0.category) }
                    .reduce(Int64(0)) { $0 + $1.sizeBytes }
                xcodeJunkBytes = devLeft
                systemJunkBytes = remaining.reduce(Int64(0)) { $0 + $1.sizeBytes } - devLeft

                cleanedCount = result.trashedCount + result.deletedCount
                leftoverCount = leftovers.count
                freedBytes = result.trashedBytes + result.deletedBytes

                // Celebrate only when something was actually removed. All
                // items failing (no Full Disk Access, say) is not a success.
                if cleanedCount > 0 {
                    withAnimation(reduceMotion ? nil : Theme.Motion.gentle) { phase = .success }
                    confettiBurst += 1
                    Haptics.successWithSound()
                } else {
                    withAnimation(reduceMotion ? nil : Theme.Motion.gentle) { phase = .review }
                }
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
