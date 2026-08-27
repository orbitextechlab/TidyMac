import Foundation

/// Scanner for large and old files, CleanMyMac "Large & Old Files" style.
///
/// Walks the three folders where forgotten downloads and stale exports pile up,
/// and returns files matching the size/age filters, sorted by size.
///
/// **The roots are fixed and not user-selectable.** They used to be, and
/// pointing the scan at `/Applications` listed every installed app as a "large
/// old file" with a delete tick beside it. The question this screen asks — "is
/// this big thing still wanted?" — only makes sense in folders the user puts
/// things in themselves. Everywhere else, size and age say nothing: an app
/// untouched for a year is a working app, and a big file under Library is the
/// Cleaner's business, not this screen's.
///
/// Bundles/packages (e.g. Photos Library) are reported as single items with
/// their aggregate size rather than thousands of internal files.
final class LargeFilesService {

    struct Filters {
        var minSizeBytes: Int64 = 100 * 1_048_576          // 100 MB
        var olderThanDays: Int? = nil                       // nil = any age
    }

    struct FoundFile: Identifiable {
        var id: String { url.path }
        let url: URL
        let sizeBytes: Int64
        let modified: Date?
        let isPackage: Bool
        var isSelected: Bool = false                        // user files: never pre-selected
    }

    /// Cap on returned results so a wide scan cannot flood the UI.
    static let resultLimit = 500

    /// The only folders this screen scans. See the type comment for why this is
    /// a constant rather than something the user picks.
    static let roots: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Downloads", "Documents", "Desktop"]
            .map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }()

    /// Bundles that hold executable code rather than a user's document.
    ///
    /// None of these belongs in a "large and old files" list. An application's
    /// modification date says nothing about whether it is still wanted — an app
    /// untouched for a year is a working app, not a forgotten download — and
    /// trashing the bundle from here would strand every support file it left in
    /// Library. Removing an app is the Uninstaller's job, which handles both.
    ///
    /// Document packages (Photos libraries, Final Cut libraries, sparse bundles)
    /// are deliberately *not* listed here: those really are large user files and
    /// remain reportable as single items.
    static let codeBundleExtensions: Set<String> = [
        "app", "appex", "framework", "bundle", "plugin", "kext", "xpc",
        "prefpane", "qlgenerator", "systemextension", "component",
        "vst", "vst3", "audiounit", "dext", "mdimporter",
    ]

    private let fileManager = FileManager.default

    /// Synchronous scan; run it off the main thread. `progress` receives
    /// (files scanned, matched bytes so far) roughly every 500 files.
    func scan(roots: [URL] = LargeFilesService.roots,
              filters: Filters,
              progress: @escaping (Int, Int64) -> Void = { _, _ in },
              isCancelled: @escaping () -> Bool = { false }) -> [FoundFile] {

        let cutoff = filters.olderThanDays.map {
            Date().addingTimeInterval(-Double($0) * 86_400)
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isPackageKey, .isSymbolicLinkKey,
                                         .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                         .contentModificationDateKey]

        var found: [FoundFile] = []
        var scanned = 0
        var matchedBytes: Int64 = 0

        for root in roots {
            if isCancelled() { break }
            // `.skipsPackageDescendants` matters as much as the explicit
            // `skipDescendants()` calls below: if the resource-value read fails
            // for a bundle, the loop would otherwise walk into it and start
            // listing the executables and frameworks inside it.
            guard let enumerator = fileManager.enumerator(
                at: root, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                if isCancelled() { break }
                scanned += 1
                if scanned % 500 == 0 { progress(scanned, matchedBytes) }

                // Executable bundles are never offered, whatever their size or
                // age. Downloads and Desktop are full of them — an app dragged
                // out of a disk image and left there is still an app, not junk.
                // Checked on the extension rather than the package flag so it
                // holds even when the resource-value read below fails.
                if Self.codeBundleExtensions.contains(url.pathExtension.lowercased()) {
                    enumerator.skipDescendants()
                    continue
                }

                guard let values = try? url.resourceValues(forKeys: keys) else { continue }
                if values.isSymbolicLink == true { continue }

                let modified = values.contentModificationDate
                if values.isPackage == true {
                    // Treat the bundle as one unit and don't descend into it.
                    enumerator.skipDescendants()
                    let size = directorySize(url, isCancelled: isCancelled)
                    if size >= filters.minSizeBytes, passesAge(modified, cutoff: cutoff) {
                        found.append(FoundFile(url: url, sizeBytes: size,
                                               modified: modified, isPackage: true))
                        matchedBytes += size
                    }
                    continue
                }

                guard values.isRegularFile == true,
                      let size64 = values.totalFileAllocatedSize ?? values.fileAllocatedSize
                else { continue }
                let size = Int64(size64)
                guard size >= filters.minSizeBytes, passesAge(modified, cutoff: cutoff) else { continue }
                found.append(FoundFile(url: url, sizeBytes: size,
                                       modified: modified, isPackage: false))
                matchedBytes += size
            }
        }

        progress(scanned, matchedBytes)
        return Array(found.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(Self.resultLimit))
    }

    private func passesAge(_ modified: Date?, cutoff: Date?) -> Bool {
        guard let cutoff else { return true }
        guard let modified else { return false }
        return modified < cutoff
    }

    private func directorySize(_ url: URL, isCancelled: @escaping () -> Bool) -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        for case let fileURL as URL in enumerator {
            if isCancelled() { break }
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            if let alloc = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize {
                total += Int64(alloc)
            }
        }
        return total
    }

    /// Move the selected files to the Trash (never permanent deletion).
    /// Returns (trashed count, trashed bytes, failed paths).
    func trashSelected(_ files: [FoundFile]) -> (count: Int, bytes: Int64, failed: [String]) {
        var count = 0
        var bytes: Int64 = 0
        var failed: [String] = []
        for file in files where file.isSelected {
            do {
                try DeletionGuard.perform(on: file.url, scope: .userFiles) { url in
                    try fileManager.trashItem(at: url, resultingItemURL: nil)
                    count += 1
                    bytes += file.sizeBytes
                }
            } catch {
                failed.append(file.url.path)
            }
        }
        return (count, bytes, failed)
    }
}
