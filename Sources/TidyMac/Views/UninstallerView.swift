import SwiftUI

/// Uninstall applications together with their scattered support files.
struct UninstallerView: View {
    private let uninstaller = AppUninstaller()
    private let orphanScanner = OrphanScanner()

    /// Orphans live here rather than in their own sidebar section: it is the
    /// same job — tidying up after removing an app — and on a machine where
    /// nothing has been uninstalled the list is empty, which would make a
    /// top-level screen look broken.
    private enum Mode: String, CaseIterable, Identifiable {
        case apps = "Applications"
        case orphans = "Leftovers"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .apps
    @State private var orphans: [OrphanScanner.Orphan] = []
    @State private var orphanError: String?
    @State private var isScanningOrphans = false
    @State private var didScanOrphans = false

    @State private var apps: [AppUninstaller.InstalledApp] = []
    @State private var selected: AppUninstaller.InstalledApp?
    @State private var leftovers: [AppUninstaller.Leftover] = []
    @State private var searchText = ""
    @State private var status: String?
    @State private var isLoadingLeftovers = false
    @State private var confirmUninstall = false

    private var filteredApps: [AppUninstaller.InstalledApp] {
        guard !searchText.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().opacity(0.5)

            switch mode {
            case .apps:
                HSplitView {
                    appList
                        .frame(minWidth: 240, idealWidth: 280, maxHeight: .infinity)
                    detail
                        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .orphans:
                orphansPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard apps.isEmpty else { return }
            // Bundle parsing + icon loads for a big /Applications folder are
            // slow enough to beachball the first open — do it off-main.
            let uninstaller = self.uninstaller
            Task.detached(priority: .userInitiated) {
                let found = uninstaller.installedApps()
                await MainActor.run { apps = found }
            }
        }
    }

    // MARK: - Leftovers from removed apps

    @ViewBuilder
    private var orphansPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Leftovers from removed apps").font(.headline)
                    Text("Sandbox containers and saved window state whose app is no longer installed anywhere on this Mac. Only these two folders can be judged reliably — caches and preferences elsewhere also hold data for command-line tools and system services, which no list of installed apps can account for.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if isScanningOrphans {
                    HStack(spacing: 8) {
                        SpinnerRing(size: 14, lineWidth: 2)
                        Text("Checking every installed application…")
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else if let orphanError {
                    Label(orphanError, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else if orphans.isEmpty && didScanOrphans {
                    ContentUnavailableView("No leftovers found", systemImage: "checkmark.seal",
                        description: Text("Every container on this Mac belongs to an app you still have."))
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if !orphans.isEmpty {
                    Text("Nothing here is pre-selected. An app installed somewhere unusual can still be missed, so check a name you do not recognise before removing it.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textMuted)
                    GlassCard {
                        VStack(spacing: 8) {
                            ForEach(orphans) { item in
                                HStack(spacing: 8) {
                                    Toggle("", isOn: orphanBinding(item)).labelsHidden()
                                    FileRow(url: item.url, sizeBytes: item.sizeBytes,
                                            detail: "no installed app claims this")
                                }
                            }
                        }
                    }
                    Button("Move \(orphans.filter(\.isSelected).count) items to the Trash") {
                        trashSelectedOrphans()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!orphans.contains(where: { $0.isSelected }))
                }

                if let status { Text(status).font(.system(size: 12)).foregroundStyle(Theme.textSecondary) }
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .onAppear { if !didScanOrphans { scanOrphans() } }
    }

    private func orphanBinding(_ item: OrphanScanner.Orphan) -> Binding<Bool> {
        Binding(
            get: { orphans.first { $0.id == item.id }?.isSelected ?? false },
            set: { value in
                guard let i = orphans.firstIndex(where: { $0.id == item.id }) else { return }
                orphans[i].isSelected = value
            })
    }

    private func scanOrphans() {
        isScanningOrphans = true
        orphanError = nil
        let scanner = orphanScanner
        Task.detached(priority: .userInitiated) {
            do {
                let found = try scanner.scan()
                await MainActor.run {
                    orphans = found
                    isScanningOrphans = false
                    didScanOrphans = true
                }
            } catch {
                await MainActor.run {
                    orphanError = "\(error)"
                    isScanningOrphans = false
                    didScanOrphans = true
                }
            }
        }
    }

    private func trashSelectedOrphans() {
        let targets = orphans.filter(\.isSelected)
        guard !targets.isEmpty else { return }
        let fm = FileManager.default
        var moved = 0
        var failed = 0
        for item in targets {
            do { try fm.trashItem(at: item.url, resultingItemURL: nil); moved += 1 }
            catch { failed += 1 }
        }
        let movedIDs = Set(targets.map(\.id))
        orphans.removeAll { movedIDs.contains($0.id) && fm.fileExists(atPath: $0.url.path) == false }
        // Sandbox containers sit behind TCC, so removing them needs Full Disk
        // Access — naming the actual fix beats a generic failure message.
        status = failed == 0
            ? "Moved \(moved) items to the Trash"
            : "Moved \(moved) items; \(failed) could not be removed. macOS protects sandbox containers — grant TidyMac Full Disk Access in Permissions and try again."
        if moved > 0 { Haptics.success() }
    }

    private var appList: some View {
        VStack(spacing: 0) {
            TextField("Search apps", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            List(filteredApps, selection: Binding(
                get: { selected?.id },
                set: { id in select(id) }
            )) { app in
                HStack {
                    Image(nsImage: app.icon).resizable().frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name).lineLimit(1)
                        Text(app.bundleID).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .tag(app.id)
            }
            .listStyle(.inset)
        }
    }

    private var detail: some View {
        Group {
            if let app = selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            Image(nsImage: app.icon).resizable().frame(width: 56, height: 56)
                            VStack(alignment: .leading) {
                                Text(app.name).font(.title2.weight(.bold))
                                Text(app.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }

                        Text("Related files").font(.headline)
                        if isLoadingLeftovers {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Looking for related files…").foregroundStyle(.secondary)
                            }
                        } else if leftovers.isEmpty {
                            Text("No leftover files found.").foregroundStyle(.secondary)
                        } else {
                            GlassCard {
                                VStack(spacing: 8) {
                                    ForEach(leftovers) { item in
                                        HStack(spacing: 8) {
                                            Toggle("", isOn: leftoverBinding(item)).labelsHidden()
                                            FileRow(url: item.url, sizeBytes: item.sizeBytes,
                                                    detail: item.matchedByBundleID ? nil : "possible match — verify")
                                        }
                                    }
                                }
                            }
                        }

                        Button(role: .destructive) { confirmUninstall = true } label: {
                            Label("Uninstall \(app.name)", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(isLoadingLeftovers)
                        .confirmationDialog(
                            "Uninstall \(app.name)?",
                            isPresented: $confirmUninstall, titleVisibility: .visible
                        ) {
                            Button("Move to Trash", role: .destructive) { performUninstall(app) }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            let count = leftovers.filter(\.isSelected).count
                            let bytes = leftovers.filter(\.isSelected).reduce(0) { $0 + $1.sizeBytes }
                            Text("The app and \(count) related files (\(Format.bytes(bytes))) will be moved to the Trash.")
                        }

                        if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
                    }
                    .padding(20)
                }
            } else {
                ContentUnavailableView("Select an app",
                    systemImage: "app.dashed",
                    description: Text("Choose an application to see what will be removed."))
            }
        }
    }

    private func select(_ id: UUID?) {
        selected = apps.first { $0.id == id }
        status = nil
        leftovers = []
        guard let app = selected else { return }
        // Sizing leftovers walks directories recursively — keep it off the
        // main thread so clicking through the list stays responsive.
        isLoadingLeftovers = true
        let uninstaller = self.uninstaller
        Task.detached(priority: .userInitiated) {
            let found = uninstaller.leftovers(for: app)
            await MainActor.run {
                // Ignore stale results if the user already clicked elsewhere —
                // but never leave the loading flag stuck on.
                guard selected?.id == app.id else {
                    if selected == nil { isLoadingLeftovers = false }
                    return
                }
                leftovers = found
                isLoadingLeftovers = false
            }
        }
    }

    private func leftoverBinding(_ item: AppUninstaller.Leftover) -> Binding<Bool> {
        Binding(
            get: { leftovers.first { $0.id == item.id }?.isSelected ?? false },
            set: { v in if let i = leftovers.firstIndex(where: { $0.id == item.id }) { leftovers[i].isSelected = v } }
        )
    }

    private func performUninstall(_ app: AppUninstaller.InstalledApp) {
        let failed = uninstaller.uninstall(app, leftovers: leftovers)
        if failed.isEmpty {
            status = "\(app.name) removed."
            apps.removeAll { $0.id == app.id }
            selected = nil
            leftovers = []
        } else {
            status = "Could not remove \(failed.count) item(s). They may require admin rights."
        }
    }
}
