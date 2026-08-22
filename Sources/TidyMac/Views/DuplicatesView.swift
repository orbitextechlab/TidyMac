import SwiftUI

/// Duplicate file finder: same-size candidates are hash-verified, then shown
/// in groups with all-but-newest pre-selected. Full paths always visible.
struct DuplicatesView: View {
    private let service = DuplicatesService()

    @State private var groups: [DuplicatesService.Group] = []
    @State private var isScanning = false
    @State private var isTrashing = false
    @State private var cancelFlag = CancelFlag()
    @State private var progressText = ""
    @State private var resultMessage: String?
    @State private var failedPaths: [String] = []
    @State private var confirmTrash = false
    @State private var hasScanned = false

    private var selectedCount: Int {
        groups.reduce(0) { $0 + $1.files.filter(\.isSelected).count }
    }
    private var selectedBytes: Int64 {
        groups.reduce(0) { $0 + $1.files.filter(\.isSelected).reduce(0) { $0 + $1.sizeBytes } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .confirmationDialog(
            "Move \(selectedCount) duplicate copies (\(Format.bytes(selectedBytes))) to the Trash?",
            isPresented: $confirmTrash, titleVisibility: .visible
        ) {
            Button("Move to Trash") { trashSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("At least one copy of every file stays on disk. You can restore from the Trash.")
        }
        .onDisappear { cancelFlag.cancel() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Duplicates").font(.pageTitle)
                if isScanning {
                    Text(progressText.isEmpty ? "Scanning…" : progressText)
                        .font(.caption).foregroundStyle(.secondary)
                } else if let resultMessage {
                    Text(resultMessage).font(.caption).foregroundStyle(Theme.ok)
                } else {
                    Text("Find identical files in Documents, Downloads, Desktop and media folders")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isScanning {
                Button(role: .cancel) { cancelFlag.cancel() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            } else {
                Button { scan() } label: { Label("Scan", systemImage: "magnifyingglass") }
                    .disabled(isTrashing)
                    .keyboardShortcut("r", modifiers: .command)
            }
            Button { confirmTrash = true } label: {
                Label(selectedBytes > 0 ? "Trash \(Format.bytes(selectedBytes))" : "Trash",
                      systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isScanning || isTrashing || selectedCount == 0)
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        if isScanning {
            ScrollView {
                VStack(spacing: 12) {
                    ScanBanner(title: "Hashing candidate files…",
                               status: progressText.isEmpty ? "Collecting candidates…" : progressText)
                    SkeletonList(rows: 6)
                }
                .padding(20)
            }
        } else if groups.isEmpty {
            ContentUnavailableView {
                Label(hasScanned ? "No duplicates found" : "Ready to scan",
                      systemImage: "doc.on.doc")
            } description: {
                Text(hasScanned
                     ? "Your common folders contain no identical files over 1 MB."
                     : "Compare files by content to find wasted space.")
            } actions: {
                if !hasScanned {
                    Button("Scan Now") { scan() }.buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !failedPaths.isEmpty {
                    SwiftUI.Section {
                        ForEach(failedPaths, id: \.self) { path in
                            Label(path, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(Theme.critical)
                        }
                    } header: { Text("Could not be moved to Trash") }
                }
                ForEach(groups) { group in
                    SwiftUI.Section {
                        ForEach(group.files) { file in
                            HStack(spacing: 8) {
                                Toggle("", isOn: binding(group: group.id, file: file.id))
                                    .labelsHidden()
                                FileRow(url: file.url, sizeBytes: file.sizeBytes,
                                        detail: file.isSelected ? nil : "keeping this copy")
                            }
                        }
                    } header: {
                        HStack {
                            Text("\(group.files.count)× · \(Format.bytes(group.sizeBytes)) each")
                            Spacer()
                            Text("wastes \(Format.bytes(group.wastedBytes))")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .disabled(isTrashing)
        }
    }

    private func binding(group groupID: String, file fileID: String) -> Binding<Bool> {
        Binding(
            get: {
                groups.first { $0.id == groupID }?.files.first { $0.id == fileID }?.isSelected ?? false
            },
            set: { newValue in
                guard let g = groups.firstIndex(where: { $0.id == groupID }),
                      let f = groups[g].files.firstIndex(where: { $0.id == fileID }) else { return }
                groups[g].files[f].isSelected = newValue
            }
        )
    }

    private func scan() {
        isScanning = true
        resultMessage = nil
        failedPaths = []
        progressText = ""
        let flag = CancelFlag()
        cancelFlag = flag
        let service = self.service
        Task.detached(priority: .userInitiated) {
            let found = service.scan(progress: { text in
                Task { @MainActor in progressText = text }
            }, isCancelled: flag.isCancelled)
            await MainActor.run {
                groups = found
                isScanning = false
                hasScanned = true
            }
        }
    }

    private func trashSelected() {
        isTrashing = true
        let service = self.service
        let snapshot = groups
        Task.detached(priority: .userInitiated) {
            let result = service.trashSelected(snapshot)
            await MainActor.run {
                isTrashing = false
                failedPaths = result.failed
                resultMessage = "Moved \(result.count) copies (\(Format.bytes(result.bytes))) to the Trash"
                // Drop removed files; drop groups that no longer have duplicates.
                let failedSet = Set(result.failed)
                groups = groups.compactMap { group -> DuplicatesService.Group? in
                    var g = group
                    g.files.removeAll { $0.isSelected && !failedSet.contains($0.url.path) }
                    return g.files.count > 1 ? g : nil
                }
            }
        }
    }
}
