import SwiftUI

/// Scan-and-clean reclaimable disk space, grouped by category. Reused by both
/// sidebar entries: "System Junk" (everyday junk) and "Xcode Junk" (developer
/// build products and tool caches) — each passes its own category set.
///
/// Deletion is two-step: everything goes to the Trash after one confirmation;
/// items that cannot be trashed are listed in a second, explicit confirmation
/// before any permanent privileged delete.
struct CleanerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var title = "System Junk"
    var subtitle = "Reclaim space from caches, logs and app leftovers"
    var categories: [CleaningEngine.Category] = CleaningEngine.systemJunkCategories

    /// Plain reference on purpose — @EnvironmentObject would re-render this
    /// whole list whenever the object publishes. We only call methods on it.
    let nav: Navigation

    private let engine = CleaningEngine()

    @State private var items: [CleaningEngine.Item] = []
    @State private var isScanning = false
    @State private var isCleaning = false
    @State private var scanProgressText = ""
    @State private var resultMessage: String?
    @State private var confirmClean = false
    @State private var showAdminAlert = false
    @State private var adminCandidates: [CleaningEngine.Item] = []
    @State private var skippedPaths: [(path: String, reason: String)] = []
    @State private var cancelFlag = CancelFlag()

    private var selectedItems: [CleaningEngine.Item] { items.filter(\.isSelected) }
    private var totalSelectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.sizeBytes } }
    private var busy: Bool { isScanning || isCleaning }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .confirmationDialog(
            "Move \(selectedItems.count) items (\(Format.bytes(totalSelectedBytes))) to the Trash?",
            isPresented: $confirmClean, titleVisibility: .visible
        ) {
            Button("Move to Trash") { clean() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(selectionIncludesTrash
                 ? "Items already in the Trash will be deleted permanently."
                 : "You can restore items from the Trash afterwards.")
        }
        .alert("Some items need administrator rights", isPresented: $showAdminAlert) {
            Button("Delete Permanently", role: .destructive) { deleteWithAdmin() }
            Button("Skip", role: .cancel) { adminCandidates = [] }
        } message: {
            Text("These items can't be moved to the Trash and will be deleted permanently:\n\n"
                 + adminCandidates.prefix(8).map { $0.url.path }.joined(separator: "\n")
                 + (adminCandidates.count > 8 ? "\n… and \(adminCandidates.count - 8) more" : ""))
        }
        .onAppear { adoptSmartScanResults() }
        .onDisappear { cancelFlag.cancel() }
    }

    /// Arriving from Home's Smart Scan: show the already-scanned items for our
    /// categories instantly; with nothing cached, start a scan by ourselves.
    private func adoptSmartScanResults() {
        guard items.isEmpty, !isScanning else {
            nav.autoScanOnArrival = false
            return
        }
        if let cached = nav.takeSmartScanItems(for: categories) {
            nav.autoScanOnArrival = false
            withAnimation(reduceMotion ? nil : Theme.Motion.gentle) { items = cached }
        } else if nav.autoScanOnArrival {
            nav.autoScanOnArrival = false
            scan()
        }
    }

    private var selectionIncludesTrash: Bool {
        selectedItems.contains { $0.category == .trash }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.pageTitle)
                if isScanning {
                    Text("Scanning \(scanProgressText)…")
                        .font(.caption).foregroundStyle(.secondary)
                } else if isCleaning {
                    Text("Cleaning…").font(.caption).foregroundStyle(.secondary)
                } else if let resultMessage {
                    Text(resultMessage).font(.caption).foregroundStyle(Theme.ok)
                } else {
                    Text(subtitle)
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
                    .disabled(busy)
                    .keyboardShortcut("r", modifiers: .command)
            }
            Button { confirmClean = true } label: {
                Label(totalSelectedBytes > 0 ? "Clean \(Format.bytes(totalSelectedBytes))" : "Clean",
                      systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || totalSelectedBytes == 0)
        }
        .padding(20)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isScanning {
            ScrollView {
                VStack(spacing: 12) {
                    ScanBanner(title: "Scanning for junk…",
                               status: scanProgressText.isEmpty
                                   ? "Preparing…" : "Looking through \(scanProgressText)")
                    SkeletonList(rows: 6)
                }
                .padding(20)
            }
        } else if items.isEmpty {
            ContentUnavailableView {
                Label("Nothing scanned yet", systemImage: "sparkles")
            } description: {
                Text("Run a scan to find caches, logs and other reclaimable files.")
            } actions: {
                Button("Scan Now") { scan() }.buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list
        }
    }

    private var list: some View {
        // Group and index once per rebuild. Doing it inside the row loop made
        // every visible row re-scan the whole array, which is what made a
        // few-hundred-row scan crawl while scrolling.
        let grouped = Dictionary(grouping: items, by: \.category)
        let indexByID = Dictionary(items.enumerated().map { ($1.id, $0) },
                                   uniquingKeysWith: { first, _ in first })

        return List {
            if !skippedPaths.isEmpty {
                SwiftUI.Section {
                    ForEach(skippedPaths, id: \.path) { entry in
                        Label("\(entry.path) — \(entry.reason)", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } header: { Text("Skipped") }
            }
            ForEach(categories) { category in
                if let categoryItems = grouped[category], !categoryItems.isEmpty {
                    SwiftUI.Section {
                        ForEach(categoryItems) { item in
                            HStack(spacing: 8) {
                                Toggle("", isOn: binding(for: item, at: indexByID[item.id]))
                                    .labelsHidden()
                                FileRow(url: item.url, sizeBytes: item.sizeBytes)
                            }
                        }
                    } header: {
                        categoryHeader(category, items: categoryItems)
                    }
                }
            }
        }
        .listStyle(.inset)
        .disabled(isCleaning)
    }

    private func categoryHeader(_ category: CleaningEngine.Category,
                                items categoryItems: [CleaningEngine.Item]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Toggle(isOn: categoryBinding(category, items: categoryItems)) {
                    Label(category.rawValue, systemImage: category.systemImage)
                }
                .toggleStyle(.checkbox)
                Spacer()
                Text(Format.bytes(categoryItems.reduce(0) { $0 + $1.sizeBytes }))
                    .foregroundStyle(.secondary)
            }
            if let note = category.note {
                Text(note).font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Selection bindings

    /// O(1) selection binding via a precomputed index, falling back to a search
    /// if the list shifted since the index was built.
    private func binding(for item: CleaningEngine.Item, at index: Int?) -> Binding<Bool> {
        Binding(
            get: {
                if let index, index < items.count, items[index].id == item.id {
                    return items[index].isSelected
                }
                return items.first(where: { $0.id == item.id })?.isSelected ?? false
            },
            set: { newValue in
                if let index, index < items.count, items[index].id == item.id {
                    items[index].isSelected = newValue
                } else if let idx = items.firstIndex(where: { $0.id == item.id }) {
                    items[idx].isSelected = newValue
                }
            }
        )
    }

    private func categoryBinding(_ category: CleaningEngine.Category,
                                 items categoryItems: [CleaningEngine.Item]) -> Binding<Bool> {
        Binding(
            get: { categoryItems.allSatisfy(\.isSelected) && !categoryItems.isEmpty },
            set: { newValue in
                for idx in items.indices where items[idx].category == category {
                    items[idx].isSelected = newValue
                }
            }
        )
    }

    // MARK: - Actions

    private func scan() {
        isScanning = true
        resultMessage = nil
        scanProgressText = ""
        skippedPaths = []
        let flag = CancelFlag()
        cancelFlag = flag
        let engine = self.engine
        let categories = self.categories
        Task.detached(priority: .userInitiated) {
            let found = engine.scan(categories: categories, progress: { category in
                Task { @MainActor in scanProgressText = category }
            }, isCancelled: flag.isCancelled)
            await MainActor.run {
                items = found
                isScanning = false
            }
        }
    }

    private func clean() {
        isCleaning = true
        resultMessage = nil
        let engine = self.engine
        let selected = items
        Task.detached(priority: .userInitiated) {
            let result = engine.trashSelected(selected)
            await MainActor.run {
                isCleaning = false
                // Remove only rows that were actually handled: trashed/deleted
                // ones — not those pending admin or skipped with an error.
                let unhandled = Set(result.needsAdmin.map(\.id))
                let skippedSet = Set(result.skipped.map(\.path))
                let handledIDs = Set(selected.filter(\.isSelected).map(\.id))
                    .subtracting(unhandled)
                    .filter { id in
                        guard let item = selected.first(where: { $0.id == id }) else { return false }
                        return !skippedSet.contains(item.url.path)
                    }
                withAnimation(reduceMotion ? nil : Theme.Motion.gentle) { items.removeAll { handledIDs.contains($0.id) } }

                var parts: [String] = []
                if result.trashedCount > 0 {
                    parts.append("Moved \(result.trashedCount) items (\(Format.bytes(result.trashedBytes))) to the Trash")
                }
                if result.deletedCount > 0 {
                    parts.append("Deleted \(result.deletedCount) Trash items (\(Format.bytes(result.deletedBytes)))")
                }
                if !result.skipped.isEmpty {
                    parts.append("\(result.skipped.count) skipped")
                }
                resultMessage = parts.isEmpty ? "Nothing was removed" : parts.joined(separator: " · ")
                skippedPaths = result.skipped
                adminCandidates = result.needsAdmin
                showAdminAlert = !result.needsAdmin.isEmpty
            }
        }
    }

    private func deleteWithAdmin() {
        let engine = self.engine
        let candidates = adminCandidates
        adminCandidates = []
        isCleaning = true
        Task.detached(priority: .userInitiated) {
            let outcome = engine.deletePermanently(candidates)
            await MainActor.run {
                isCleaning = false
                let deletedIDs = Set(outcome.deleted.map(\.id))
                withAnimation(reduceMotion ? nil : Theme.Motion.gentle) { items.removeAll { deletedIDs.contains($0.id) } }
                let bytes = outcome.deleted.reduce(Int64(0)) { $0 + $1.sizeBytes }
                var suffix = " · Permanently deleted \(outcome.deleted.count) items (\(Format.bytes(bytes)))"
                if !outcome.failed.isEmpty {
                    suffix += " · \(outcome.failed.count) could not be deleted"
                }
                resultMessage = (resultMessage ?? "") + suffix
            }
        }
    }
}
