import SwiftUI
import AppKit

/// CleanMyMac-style "Large & Old Files" finder: scan a folder tree for files
/// over a size threshold (optionally untouched for months), review them with
/// full paths, and move the chosen ones to the Trash.
struct LargeFilesView: View {
    private let service = LargeFilesService()

    private static let sizeOptions: [(label: String, bytes: Int64)] = [
        ("50 MB", 50 * 1_048_576),
        ("100 MB", 100 * 1_048_576),
        ("250 MB", 250 * 1_048_576),
        ("500 MB", 500 * 1_048_576),
        ("1 GB", 1_073_741_824),
    ]
    private static let ageOptions: [(label: String, days: Int?)] = [
        ("Any age", nil),
        ("1+ month old", 30),
        ("6+ months old", 180),
        ("1+ year old", 365),
    ]

    @State private var rootURL = FileManager.default.homeDirectoryForCurrentUser
    @State private var minSizeBytes: Int64 = 100 * 1_048_576
    @State private var olderThanDays: Int? = nil

    @State private var files: [LargeFilesService.FoundFile] = []
    @State private var isScanning = false
    @State private var isTrashing = false
    @State private var cancelFlag = CancelFlag()
    @State private var progressText = ""
    @State private var matchedText = ""
    @State private var resultMessage: String?
    @State private var failedPaths: [String] = []
    @State private var confirmTrash = false
    @State private var hasScanned = false

    private var selected: [LargeFilesService.FoundFile] { files.filter(\.isSelected) }
    private var selectedBytes: Int64 { selected.reduce(0) { $0 + $1.sizeBytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            filterBar
            Divider()
            content
        }
        .confirmationDialog(
            "Move \(selected.count) files (\(Format.bytes(selectedBytes))) to the Trash?",
            isPresented: $confirmTrash, titleVisibility: .visible
        ) {
            Button("Move to Trash") { trashSelectedFiles() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These are your files — make sure you no longer need them. You can restore them from the Trash.")
        }
        .onDisappear { cancelFlag.cancel() }
    }

    // MARK: - Header + filters

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Large Files").font(.pageTitle)
                if isScanning {
                    Text(progressText.isEmpty ? "Scanning…" : progressText)
                        .font(.caption).foregroundStyle(.secondary)
                } else if let resultMessage {
                    Text(resultMessage).font(.caption).foregroundStyle(.green)
                } else {
                    Text("Find big and forgotten files in \(rootURL.path)")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if isScanning {
                Button(role: .cancel) { cancelFlag.cancel() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            } else {
                Button { scan() } label: { Label("Scan", systemImage: "magnifyingglass") }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(isTrashing)
            }
            Button { confirmTrash = true } label: {
                Label(selectedBytes > 0 ? "Trash \(Format.bytes(selectedBytes))" : "Trash",
                      systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isScanning || isTrashing || selected.isEmpty)
        }
        .padding(20)
    }

    private var filterBar: some View {
        HStack(spacing: 14) {
            Picker("Larger than", selection: $minSizeBytes) {
                ForEach(Self.sizeOptions, id: \.bytes) { option in
                    Text(option.label).tag(option.bytes)
                }
            }
            .frame(maxWidth: 200)

            Picker("Age", selection: $olderThanDays) {
                ForEach(Self.ageOptions, id: \.days) { option in
                    Text(option.label).tag(option.days)
                }
            }
            .frame(maxWidth: 220)

            Button {
                chooseFolder()
            } label: { Label("Choose Folder…", systemImage: "folder") }

            Spacer()
            if files.count == LargeFilesService.resultLimit {
                Text("Showing top \(LargeFilesService.resultLimit) results")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .disabled(isScanning)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isScanning {
            ScrollView {
                VStack(spacing: 12) {
                    ScanBanner(title: "Sizing files over \(Format.bytes(minSizeBytes))…",
                               status: progressText.isEmpty ? "Walking \(rootURL.lastPathComponent)…" : progressText,
                               found: matchedText.isEmpty ? nil : matchedText)
                    SkeletonList(rows: 6)
                }
                .padding(20)
            }
        } else if files.isEmpty {
            ContentUnavailableView {
                Label(hasScanned ? "No files matched" : "Ready to scan",
                      systemImage: "doc.text.magnifyingglass")
            } description: {
                Text(hasScanned
                     ? "Nothing in \(rootURL.lastPathComponent) matches the current size and age filters."
                     : "Scan \(rootURL.lastPathComponent) for files over \(Format.bytes(minSizeBytes)).")
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
                                .font(.caption).foregroundStyle(.red)
                        }
                    } header: { Text("Could not be moved to Trash") }
                }
                // Binding straight to the element keeps selection O(1) per row
                // instead of searching the array on every redraw.
                ForEach($files) { $file in
                    HStack(spacing: 8) {
                        Toggle("", isOn: $file.isSelected).labelsHidden()
                        FileRow(url: file.url,
                                sizeBytes: file.sizeBytes,
                                detail: file.modified.map { "modified \(Self.dateFormatter.string(from: $0))" })
                    }
                }
            }
            .listStyle(.inset)
            .disabled(isTrashing)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    // MARK: - Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = rootURL
        if panel.runModal() == .OK, let url = panel.url {
            rootURL = url
        }
    }

    private func scan() {
        isScanning = true
        resultMessage = nil
        failedPaths = []
        progressText = ""
        matchedText = ""
        let flag = CancelFlag()
        cancelFlag = flag
        let service = self.service
        let root = rootURL
        let filters = LargeFilesService.Filters(minSizeBytes: minSizeBytes, olderThanDays: olderThanDays)
        Task.detached(priority: .userInitiated) {
            let found = service.scan(root: root, filters: filters, progress: { count, bytes in
                Task { @MainActor in
                    progressText = "Scanned \(count) files"
                    matchedText = Format.bytes(bytes)
                }
            }, isCancelled: flag.isCancelled)
            await MainActor.run {
                files = found
                isScanning = false
                hasScanned = true
            }
        }
    }

    private func trashSelectedFiles() {
        let service = self.service
        let snapshot = files
        isTrashing = true
        Task.detached(priority: .userInitiated) {
            let result = service.trashSelected(snapshot)
            await MainActor.run {
                isTrashing = false
                let removedIDs = Set(snapshot.filter(\.isSelected).map(\.id))
                    .subtracting(result.failed)
                withAnimation { files.removeAll { removedIDs.contains($0.id) } }
                failedPaths = result.failed
                resultMessage = "Moved \(result.count) files (\(Format.bytes(result.bytes))) to the Trash"
            }
        }
    }
}
