import SwiftUI

/// Privacy-permissions manager: which apps can use the camera, microphone,
/// disk folders and more — grouped by permission, with one-click revoke.
struct PermissionsView: View {
    @State private var grants: [PermissionsService.Grant] = []
    @State private var isLoading = false
    @State private var needsFullDiskAccess = false
    @State private var systemLoaded = false
    @State private var statusMessage: String?
    @State private var pendingRevoke: PermissionsService.Grant?

    private var services: [String] {
        var seen: Set<String> = []
        return grants.map(\.service).filter { seen.insert($0).inserted }
            .sorted {
                (PermissionsService.friendlyNames[$0] ?? $0)
                    .localizedCaseInsensitiveCompare(PermissionsService.friendlyNames[$1] ?? $1) == .orderedAscending
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { if grants.isEmpty && !needsFullDiskAccess { reload() } }
        .confirmationDialog(
            "Revoke \(pendingRevoke?.serviceName ?? "") for \(pendingRevoke.map { PermissionsService.appInfo(for: $0.client).name } ?? "")?",
            isPresented: Binding(get: { pendingRevoke != nil },
                                 set: { if !$0 { pendingRevoke = nil } }),
            titleVisibility: .visible
        ) {
            Button("Revoke", role: .destructive) {
                if let grant = pendingRevoke { revoke(grant) }
                pendingRevoke = nil
            }
            Button("Cancel", role: .cancel) { pendingRevoke = nil }
        } message: {
            Text("The app will ask for this permission again the next time it needs it.")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Permissions").font(.pageTitle)
                Text(statusMessage ?? "Review which apps can access your camera, microphone, files and more")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !systemLoaded && !needsFullDiskAccess && !grants.isEmpty {
                Button {
                    loadSystem()
                } label: { Label("Load system permissions…", systemImage: "lock.shield") }
                    .help("Screen Recording, Accessibility and Full Disk Access require one admin approval to read")
            }
            Button { reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(isLoading)
                .keyboardShortcut("r", modifiers: .command)
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Reading permission database…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if needsFullDiskAccess {
            ContentUnavailableView {
                Label("Full Disk Access needed", systemImage: "lock.shield")
            } description: {
                Text("macOS protects the permission database. Grant TidyMac Full Disk Access in System Settings, then come back and refresh.")
            } actions: {
                Button("Open Privacy Settings") {
                    PermissionsService.openPrivacySettings()
                }
                .buttonStyle(.borderedProminent)
                Button("Retry") { reload() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if grants.isEmpty {
            ContentUnavailableView("No permission grants found", systemImage: "hand.raised")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(services, id: \.self) { service in
                    let rows = grants.filter { $0.service == service }
                    SwiftUI.Section {
                        ForEach(rows) { grant in row(grant) }
                    } header: {
                        HStack {
                            Text(PermissionsService.friendlyNames[service] ?? service)
                            if rows.first?.isSystemScope == true {
                                Image(systemName: "lock").font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text("\(rows.count)").foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ grant: PermissionsService.Grant) -> some View {
        let info = PermissionsService.appInfo(for: grant.client)
        return HStack(spacing: 10) {
            if let icon = info.icon {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            } else {
                Image(systemName: "app.dashed")
                    .foregroundStyle(.secondary).frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(info.name).lineLimit(1)
                Text(grant.client)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            Text(grant.allowed ? "Allowed" : "Denied")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(grant.allowed ? Theme.ok : .secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .neuRaised(6)
            Button("Revoke…") { pendingRevoke = grant }
                .controlSize(.small)
        }
        .font(.system(size: 12))
    }

    // MARK: - Actions

    private func reload() {
        isLoading = true
        statusMessage = nil
        Task.detached(priority: .userInitiated) {
            let result = PermissionsService.fetchUserGrants()
            await MainActor.run {
                isLoading = false
                switch result {
                case .success(let found):
                    grants = found.sorted { $0.client < $1.client }
                    needsFullDiskAccess = false
                case .failure(.needsFullDiskAccess):
                    needsFullDiskAccess = true
                case .failure(.queryFailed(let message)):
                    statusMessage = "Couldn't read permissions: \(message.prefix(120))"
                }
            }
        }
    }

    private func loadSystem() {
        Task.detached(priority: .userInitiated) {
            let system = (try? PermissionsService.fetchSystemGrants()) ?? []
            await MainActor.run {
                guard !system.isEmpty else {
                    statusMessage = "System permissions not loaded (cancelled or unreadable)"
                    return
                }
                grants.append(contentsOf: system)
                systemLoaded = true
                statusMessage = "Loaded \(system.count) system-scope grants"
            }
        }
    }

    private func revoke(_ grant: PermissionsService.Grant) {
        Task.detached(priority: .userInitiated) {
            var failed = false
            do { try PermissionsService.revoke(grant) } catch { failed = true }
            await MainActor.run {
                if failed {
                    statusMessage = "Couldn't revoke — macOS may protect this entry"
                } else {
                    grants.removeAll { $0.id == grant.id }
                    statusMessage = "Revoked \(grant.serviceName) for \(PermissionsService.appInfo(for: grant.client).name)"
                }
            }
        }
    }
}
