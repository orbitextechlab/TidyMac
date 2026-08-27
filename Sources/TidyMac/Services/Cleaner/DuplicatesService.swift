import Foundation
import CryptoKit

/// Finds duplicate files: candidates are grouped by exact size first (cheap),
/// then confirmed with a streaming SHA-256 hash so only same-size files are
/// ever read. Nothing is pre-selected across a whole group — one copy always
/// stays unchecked so a careless "select all" cannot delete every copy.
final class DuplicatesService {

    struct File: Identifiable {
        var id: String { url.path }
        let url: URL
        let sizeBytes: Int64
        let modified: Date?
        var isSelected: Bool
    }

    struct Group: Identifiable {
        let id: String            // content hash
        var files: [File]
        var sizeBytes: Int64 { files.first?.sizeBytes ?? 0 }
        /// Space reclaimed if all but one copy are removed.
        var wastedBytes: Int64 { sizeBytes * Int64(max(0, files.count - 1)) }
    }

    /// Folders scanned by default: the places duplicates actually accumulate.
    static let defaultRoots: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Downloads", "Documents", "Desktop", "Pictures", "Movies", "Music"]
            .map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }()

    private let fileManager = FileManager.default
    private let minSizeBytes: Int64 = 1_048_576   // ignore files under 1 MB

    /// Synchronous scan; run off the main thread.
    func scan(roots: [URL] = DuplicatesService.defaultRoots,
              progress: @escaping (String) -> Void = { _ in },
              isCancelled: @escaping () -> Bool = { false }) -> [Group] {

        // Pass 1: collect files by size.
        progress("Listing files…")
        var bySize: [Int64: [(URL, Date?)]] = [:]
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
                                         .fileSizeKey, .contentModificationDateKey]
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                if isCancelled() { return [] }
                guard let values = try? url.resourceValues(forKeys: keys) else { continue }
                if values.isPackage == true { enumerator.skipDescendants(); continue }
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, Int64(size) >= minSizeBytes else { continue }
                bySize[Int64(size), default: []].append((url, values.contentModificationDate))
            }
        }

        // Pass 2: hash only same-size candidates.
        let candidates = bySize.filter { $0.value.count > 1 }
        var groups: [String: [File]] = [:]
        var hashed = 0
        let totalToHash = candidates.values.reduce(0) { $0 + $1.count }
        for (size, entries) in candidates {
            for (url, modified) in entries {
                if isCancelled() { return [] }
                hashed += 1
                if hashed % 20 == 0 { progress("Comparing \(hashed)/\(totalToHash) candidates…") }
                guard let hash = sha256(url, isCancelled: isCancelled) else { continue }
                groups[hash, default: []].append(
                    File(url: url, sizeBytes: size, modified: modified, isSelected: false))
            }
        }

        // Keep only confirmed duplicate groups; pre-select every copy except
        // the most recently modified one (the likely "current" file).
        return groups.compactMap { hash, files -> Group? in
            guard files.count > 1 else { return nil }
            var sorted = files.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            for i in sorted.indices.dropFirst() { sorted[i].isSelected = true }
            return Group(id: hash, files: sorted)
        }
        .sorted { $0.wastedBytes > $1.wastedBytes }
    }

    private func sha256(_ url: URL, isCancelled: @escaping () -> Bool) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if isCancelled() { return nil }
            guard let chunk = try? handle.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Move the selected copies to the Trash. Refuses to remove a whole group.
    func trashSelected(_ groups: [Group]) -> (count: Int, bytes: Int64, failed: [String]) {
        var count = 0
        var bytes: Int64 = 0
        var failed: [String] = []
        for group in groups {
            var toRemove = group.files.filter(\.isSelected)
            // Safety net: always leave at least one copy on disk.
            if toRemove.count == group.files.count { toRemove.removeFirst() }
            for file in toRemove {
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
        }
        return (count, bytes, failed)
    }
}
