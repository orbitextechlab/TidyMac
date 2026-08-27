import Foundation

/// Scans well-known reclaimable locations and reports removable items grouped by
/// category.
///
/// Safety model:
///  - Only regenerable junk (caches, logs, crash reports, build products) is
///    pre-selected after a scan. User data (downloads, mail attachments,
///    device backups, archives, trash) must be opted in explicitly.
///  - Cleaning moves items to the Trash. Items the user cannot trash are
///    reported back (`needsAdmin`) so the UI can ask before any permanent,
///    privileged deletion happens.
final class CleaningEngine {

    enum Category: String, CaseIterable, Identifiable, Codable {
        case userCaches = "User Caches"
        case appLogs = "Application Logs"
        case crashReports = "Crash Reports"
        case xcodeJunk = "Xcode Junk"
        case devCaches = "Developer Caches"
        case packageCaches = "Package Caches"
        case mailDownloads = "Mail Downloads"
        case xcodeArchives = "Xcode Archives"
        case iosBackups = "iOS Backups"
        case downloads = "Old Downloads"
        case trash = "Trash"
        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .userCaches: return "shippingbox"
            case .appLogs: return "doc.text"
            case .crashReports: return "exclamationmark.triangle"
            case .xcodeJunk: return "hammer"
            case .devCaches: return "terminal"
            case .packageCaches: return "shippingbox.fill"
            case .mailDownloads: return "envelope.open"
            case .xcodeArchives: return "archivebox"
            case .iosBackups: return "iphone"
            case .downloads: return "arrow.down.circle"
            case .trash: return "trash"
            }
        }

        /// Pre-checked after a scan. Only always-regenerable junk qualifies;
        /// anything that may hold user data ships unchecked.
        var isPreselected: Bool {
            switch self {
            case .userCaches, .appLogs, .crashReports, .xcodeJunk, .devCaches, .packageCaches:
                return true
            case .mailDownloads, .xcodeArchives, .iosBackups, .downloads, .trash:
                return false
            }
        }

        /// Warning/context line shown in the category header.
        var note: String? {
            switch self {
            case .downloads: return "Files in ~/Downloads untouched for 30+ days — review before cleaning"
            case .trash: return "Removing Trash items deletes them permanently"
            case .iosBackups: return "Device backups — make sure you no longer need them"
            case .xcodeArchives: return "App archives with dSYMs, needed to symbolicate shipped builds"
            case .mailDownloads: return "Local copies of mail attachments (usually still on the mail server)"
            case .devCaches: return "npm / gradle / cocoapods caches — re-downloaded on demand"
            case .packageCaches: return "Downloaded packages — every tool re-fetches them, but a large store means a slow first build afterwards"
            default: return nil
            }
        }
    }

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        let sizeBytes: Int64
        let category: Category
        var isSelected: Bool
    }

    private let fileManager = FileManager.default

    /// Sidebar groupings: everyday junk vs. developer/Xcode junk.
    static let systemJunkCategories: [Category] = [
        .userCaches, .appLogs, .crashReports, .mailDownloads, .iosBackups, .downloads, .trash,
    ]
    static let developerJunkCategories: [Category] = [
        .xcodeJunk, .devCaches, .packageCaches, .xcodeArchives,
    ]

    // MARK: - Scanning

    /// Scan the given categories, reporting the category currently being sized
    /// so the UI can show real progress. Honors `isCancelled` between items.
    func scan(categories: [Category] = Category.allCases,
              progress: @escaping (String) -> Void = { _ in },
              isCancelled: @escaping () -> Bool = { false }) -> [Item] {
        var items: [Item] = []
        for category in categories {
            if isCancelled() { break }
            progress(category.rawValue)
            for root in roots(for: category) {
                items.append(contentsOf: scanRoot(root, category: category, isCancelled: isCancelled))
            }
        }
        return items.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private func roots(for category: Category) -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        func lib(_ p: String) -> URL { home.appendingPathComponent("Library/" + p) }
        let candidates: [URL]
        switch category {
        case .userCaches:   candidates = [lib("Caches")]
        case .appLogs:      candidates = [lib("Logs")]
        case .crashReports: candidates = [lib("Logs/DiagnosticReports"),
                                          lib("Application Support/CrashReporter")]
        case .xcodeJunk:    candidates = [lib("Developer/Xcode/DerivedData"),
                                          lib("Developer/Xcode/iOS DeviceSupport"),
                                          lib("Developer/CoreSimulator/Caches")]
        case .devCaches:    candidates = [home.appendingPathComponent(".npm"),
                                          home.appendingPathComponent(".cache"),
                                          home.appendingPathComponent(".gradle/caches"),
                                          home.appendingPathComponent(".cocoapods")]
        // Package-manager download stores. Every one of these is refetched on
        // demand by its own tool, which is what makes the category safe to
        // pre-select. Absent tools cost nothing: the filter below drops paths
        // that do not exist.
        case .packageCaches:
            candidates = [
                lib("pnpm/store"),              // pnpm content-addressable store
                lib("Caches/pip"),              // pip wheel cache
                lib("Caches/Homebrew"),         // brew downloads; `brew cleanup` does the same
                home.appendingPathComponent(".gradle/daemon"),   // daemon logs, not build output
                home.appendingPathComponent(".bun/install/cache"),
                home.appendingPathComponent(".cache/uv"),
                home.appendingPathComponent(".conda/pkgs"),
                home.appendingPathComponent(".m2/repository"),   // Maven
                home.appendingPathComponent(".ivy2/cache"),      // Ivy / sbt
                home.appendingPathComponent(".nuget/packages"),
            ]
        case .mailDownloads: candidates = [lib("Containers/com.apple.mail/Data/Library/Mail Downloads")]
        case .xcodeArchives: candidates = [lib("Developer/Xcode/Archives")]
        case .iosBackups:   candidates = [lib("Application Support/MobileSync/Backup")]
        case .downloads:    candidates = [home.appendingPathComponent("Downloads")]
        case .trash:        candidates = [home.appendingPathComponent(".Trash")]
        }
        return candidates.filter { fileManager.fileExists(atPath: $0.path) }
    }

    /// Treat each immediate child of a root as one cleanable item so the UI can
    /// show "Spotify cache — 240 MB" rather than thousands of files.
    private func scanRoot(_ root: URL, category: Category,
                          isCancelled: @escaping () -> Bool) -> [Item] {
        // The Trash listing must include dotfiles, or "select all" would clean
        // less than what the category claims to represent.
        let options: FileManager.DirectoryEnumerationOptions =
            category == .trash ? [] : [.skipsHiddenFiles]
        guard let children = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: options
        ) else { return [] }

        var items: [Item] = []
        for child in children {
            if isCancelled() { break }
            // Crash reports are listed separately; keep them out of "Logs".
            if category == .appLogs, child.lastPathComponent == "DiagnosticReports" { continue }
            if category == .downloads, !isOlderThan(child, days: 30) { continue }
            // Cloud sync state is not junk and is never removable, so it has no
            // business appearing in a pre-ticked list. `DeletionGuard` refuses
            // it regardless; filtering here as well keeps it off screen instead
            // of showing it ticked and then reporting it as skipped.
            if DeletionGuard.isProviderOwned(child) { continue }
            // A symlink's target would be sized but only the link gets removed,
            // so reporting the target size would fake reclaimed space. Skip.
            if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                continue
            }
            let size = directorySize(child, isCancelled: isCancelled)
            guard size > 0 else { continue }
            items.append(Item(url: child, sizeBytes: size, category: category,
                              isSelected: category.isPreselected))
        }
        return items
    }

    private func isOlderThan(_ url: URL, days: Int) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let modified = values.contentModificationDate else { return false }
        return modified < Date().addingTimeInterval(-Double(days) * 86_400)
    }

    private func directorySize(_ url: URL, isCancelled: @escaping () -> Bool = { false }) -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: keys) {
            for case let fileURL as URL in enumerator {
                if isCancelled() { break }
                let values = try? fileURL.resourceValues(forKeys: Set(keys))
                if let alloc = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize {
                    total += Int64(alloc)
                }
            }
        } else if let values = try? url.resourceValues(forKeys: [.fileAllocatedSizeKey]) {
            total += Int64(values.fileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: - Deletion

    struct CleanResult {
        var trashedBytes: Int64 = 0
        var trashedCount = 0
        /// Trash-category items removed for real (permanent, but user-owned).
        var deletedBytes: Int64 = 0
        var deletedCount = 0
        /// Items that failed with a genuine permission error. Deleting these
        /// requires admin rights and is permanent — the UI confirms separately.
        var needsAdmin: [Item] = []
        /// Items skipped for other reasons (vanished, no-Trash volume, TCC…).
        var skipped: [(path: String, reason: String)] = []
    }

    /// Remove the selected items. Regular categories go to the Trash; the
    /// Trash category is deleted directly (the user owns ~/.Trash — moving its
    /// contents "to the Trash" would just rename them and free nothing).
    func trashSelected(_ items: [Item]) -> CleanResult {
        var result = CleanResult()
        for item in items where item.isSelected {
            guard fileManager.fileExists(atPath: item.url.path) else {
                result.skipped.append((item.url.path, "no longer exists"))
                continue
            }
            do {
                try DeletionGuard.perform(on: item.url, scope: .systemJunk) { url in
                    if item.category == .trash {
                        try fileManager.removeItem(at: url)
                        result.deletedBytes += item.sizeBytes
                        result.deletedCount += 1
                    } else {
                        try fileManager.trashItem(at: url, resultingItemURL: nil)
                        result.trashedBytes += item.sizeBytes
                        result.trashedCount += 1
                    }
                }
            } catch let refusal as DeletionGuard.Refusal {
                // A refusal is the guard working, not a permission problem, so
                // it must never become an offer to delete with admin rights.
                result.skipped.append((item.url.path, refusal.description))
            } catch {
                // Only real permission failures justify offering a privileged
                // permanent delete; anything else must not escalate to rm -rf.
                if Self.isPermissionDenied(error) {
                    result.needsAdmin.append(item)
                } else {
                    result.skipped.append((item.url.path, error.localizedDescription))
                }
            }
        }
        return result
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           ns.code == CocoaError.fileWriteNoPermission.rawValue { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           underlying.code == Int(EACCES) || underlying.code == Int(EPERM) { return true }
        return false
    }

    /// Permanently delete items with admin rights — one authentication prompt,
    /// only ever called after the user explicitly confirmed this step.
    /// The outcome is verified on disk afterwards, so partial success (rm
    /// removing 4 of 5 items) is reported truthfully.
    func deletePermanently(_ items: [Item]) -> (deleted: [Item], failed: [Item]) {
        guard !items.isEmpty else { return ([], []) }
        // Re-validate every path against the same gate the user-level pass
        // used. This is the branch that runs `rm -rf` as root, so it re-derives
        // the answer rather than trusting that the earlier check happened.
        // Anything filtered out here simply shows up as "failed" in the on-disk
        // verification below.
        let safe = items.filter {
            guard $0.url.resolvingSymlinksInPath().path == $0.url.path else { return false }
            return (try? DeletionGuard.authorize($0.url, scope: .systemJunk)) != nil
        }
        let paths = safe.map {
            "'" + $0.url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
        // rm keeps going past per-path failures; ground truth comes from
        // re-checking the disk below, not from the exit status.
        _ = try? AdminRunner.runElevated("/bin/rm -rf -- \(paths)", reason: "Remove protected files")

        var deleted: [Item] = []
        var failed: [Item] = []
        for item in items {
            if fileManager.fileExists(atPath: item.url.path) {
                failed.append(item)
            } else {
                deleted.append(item)
            }
        }
        return (deleted, failed)
    }
}
