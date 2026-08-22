import SwiftUI

/// Uninstall applications together with their scattered support files.
struct UninstallerView: View {
    private let uninstaller = AppUninstaller()

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
        HSplitView {
            appList
                .frame(minWidth: 240, idealWidth: 280)
            detail
                .frame(minWidth: 320, maxWidth: .infinity)
        }
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
