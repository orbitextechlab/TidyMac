import SwiftUI

/// Startup entries manager: login items plus launchd agents/daemons, grouped
/// by scope, with a disable/enable switch per plist item.
struct StartupItemsView: View {
    @State private var items: [StartupItemsService.Item] = []
    @State private var isLoading = false
    @State private var busyID: String?
    @State private var errorMessage: String?
    @State private var pendingLoginItemRemoval: StartupItemsService.Item?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { if items.isEmpty { reload() } }
        .confirmationDialog(
            "Remove \"\(pendingLoginItemRemoval?.name ?? "")\" from Login Items?",
            isPresented: Binding(get: { pendingLoginItemRemoval != nil },
                                 set: { if !$0 { pendingLoginItemRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let item = pendingLoginItemRemoval { toggle(item, disable: true) }
                pendingLoginItemRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingLoginItemRemoval = nil }
        } message: {
            Text("Login items can't be disabled, only removed. Add it back later from System Settings › General › Login Items.")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Startup Items").font(.pageTitle)
                Text(errorMessage ?? "Control what launches automatically when your Mac starts")
                    .font(.caption)
                    .foregroundStyle(errorMessage == nil ? AnyShapeStyle(.secondary)
                                                         : AnyShapeStyle(Theme.critical))
            }
            Spacer()
            Button { reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(isLoading)
                .keyboardShortcut("r", modifiers: .command)
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Reading startup items…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            ContentUnavailableView("No startup items found", systemImage: "power")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(StartupItemsService.Scope.allCases, id: \.self) { scope in
                    let scopeItems = items.filter { $0.scope == scope }
                    if !scopeItems.isEmpty {
                        SwiftUI.Section {
                            ForEach(scopeItems) { item in row(item) }
                        } header: {
                            HStack {
                                Text(scope.rawValue)
                                if scope.needsAdmin {
                                    Image(systemName: "lock").font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Text("\(scopeItems.count)").foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ item: StartupItemsService.Item) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.scope == .loginItem ? "person.crop.circle" : "gearshape.2")
                .foregroundStyle(item.isDisabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.accent))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .lineLimit(1)
                    .foregroundStyle(item.isDisabled ? .secondary : .primary)
                if let program = item.programPath {
                    Text(program)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if busyID == item.id {
                ProgressView().controlSize(.small)
            } else if item.scope == .loginItem {
                Button("Remove…") { pendingLoginItemRemoval = item }
                    .controlSize(.small)
            } else {
                Toggle("", isOn: Binding(
                    get: { !item.isDisabled },
                    set: { enabled in toggle(item, disable: !enabled) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }
        }
        .help(item.plistURL?.path ?? item.name)
        .contextMenu {
            if let url = item.plistURL {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }

    // MARK: - Actions

    private func reload() {
        isLoading = true
        errorMessage = nil
        Task.detached(priority: .userInitiated) {
            let found = StartupItemsService.list()
            await MainActor.run {
                items = found
                isLoading = false
            }
        }
    }

    private func toggle(_ item: StartupItemsService.Item, disable: Bool) {
        busyID = item.id
        errorMessage = nil
        Task.detached(priority: .userInitiated) {
            var failure: String?
            do {
                try StartupItemsService.setDisabled(item, disable)
            } catch {
                failure = "\(error)".contains("-128") ? nil
                    : "Couldn't change \(item.name) — it may be protected by macOS"
            }
            let refreshed = StartupItemsService.list()
            await MainActor.run {
                items = refreshed
                busyID = nil
                errorMessage = failure
            }
        }
    }
}
