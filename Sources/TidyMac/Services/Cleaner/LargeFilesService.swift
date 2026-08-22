import Foundation

/// Whole-tree scanner for large and old files, CleanMyMac "Large & Old Files"
/// style. Walks a root folder (default: the user's home), skipping hidden
/// files and ~/Library (that junk belongs to the Cleaner), and returns files
/// matching the size/age filters sorted by size.
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

    /// Cap on returned results so a full-disk scan cannot flood the UI.
    static let resultLimit = 500

    private let fileManager = FileManager.default

    /// Synchronous scan; run it off the main thread. `progress` receives
    /// (files scanned, matched bytes so far) roughly every 500 files.
    func scan(root: URL,
              filters: Filters,
              progress: @escaping (Int, Int64) -> Void = { _, _ in },
              isCancelled: @escaping () -> Bool = { false }) -> [FoundFile] {

        let home = fileManager.homeDirectoryForCurrentUser
        let cutoff = filters.olderThanDays.map {
            Date().addingTimeInterval(-Double($0) * 86_400)
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isPackageKey, .isSymbolicLinkKey,
                                         .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                         .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [FoundFile] = []
        var scanned = 0
        var matchedBytes: Int64 = 0

        for case let url as URL in enumerator {
            if isCancelled() { break }
            scanned += 1
            if scanned % 500 == 0 { progress(scanned, matchedBytes) }

            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true { continue }

            // Library holds app junk handled by the Cleaner — skip the subtree.
            if url.deletingLastPathComponent() == home, url.lastPathComponent == "Library" {
                enumerator.skipDescendants()
                continue
            }

            let modified = values.contentModificationDate
            if values.isPackage == true {
                // Treat the bundle as one unit and don't descend into it.
                enumerator.skipDescendants()
                let size = directorySize(url, isCancelled: isCancelled)
                if size >= filters.minSizeBytes, passesAge(modified, cutoff: cutoff) {
                    found.append(FoundFile(url: url, sizeBytes: size, modified: modified, isPackage: true))
                    matchedBytes += size
                }
                continue
            }

            guard values.isRegularFile == true,
                  let size64 = values.totalFileAllocatedSize ?? values.fileAllocatedSize
            else { continue }
            let size = Int64(size64)
            guard size >= filters.minSizeBytes, passesAge(modified, cutoff: cutoff) else { continue }
            found.append(FoundFile(url: url, sizeBytes: size, modified: modified, isPackage: false))
            matchedBytes += size
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
                try fileManager.trashItem(at: file.url, resultingItemURL: nil)
                count += 1
                bytes += file.sizeBytes
            } catch {
                failed.append(file.url.path)
            }
        }
        return (count, bytes, failed)
    }
}
