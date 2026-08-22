import Foundation
import CoreGraphics

/// Storage-map backend. One full walk of the chosen root builds a size table
/// for every directory (each file credits all its ancestors), so navigating
/// the treemap afterwards is instant — no per-click rescans.
final class SpaceLensService {

    struct Node: Identifiable {
        var id: String { url.path }
        let url: URL
        let sizeBytes: Int64
        let isDirectory: Bool
    }

    private let fileManager = FileManager.default
    private var dirSizes: [String: Int64] = [:]
    private(set) var scannedRoot: URL?
    private(set) var totalBytes: Int64 = 0

    /// Walk the tree and accumulate directory sizes. Returns false when
    /// cancelled. Hidden files are included — a space map that skips ~/Library
    /// would lie about where the gigabytes went.
    func scan(root: URL,
              progress: @escaping (Int, Int64) -> Void = { _, _ in },
              isCancelled: @escaping () -> Bool = { false }) -> Bool {
        dirSizes = [:]
        totalBytes = 0
        scannedRoot = nil

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey,
                                         .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: []
        ) else { return false }

        let rootPath = root.path
        var fileCount = 0

        for case let url as URL in enumerator {
            if isCancelled() { return false }
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true { continue }
            guard values.isRegularFile == true,
                  let size64 = values.totalFileAllocatedSize ?? values.fileAllocatedSize,
                  size64 > 0 else { continue }
            let size = Int64(size64)
            fileCount += 1
            totalBytes += size
            if fileCount % 2000 == 0 { progress(fileCount, totalBytes) }

            // Credit every ancestor directory up to (and including) the root.
            var dir = url.deletingLastPathComponent()
            while dir.path.hasPrefix(rootPath) {
                dirSizes[dir.path, default: 0] += size
                if dir.path == rootPath { break }
                dir = dir.deletingLastPathComponent()
            }
        }

        progress(fileCount, totalBytes)
        scannedRoot = root
        return true
    }

    /// Immediate children of a folder with their (pre-computed) sizes,
    /// largest first. Empty until `scan` has covered this subtree.
    func children(of url: URL) -> [Node] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                                  .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        ) else { return [] }

        return entries.compactMap { child -> Node? in
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                                             .totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            if values?.isSymbolicLink == true { return nil }
            if values?.isDirectory == true {
                let size = dirSizes[child.path] ?? 0
                guard size > 0 else { return nil }
                return Node(url: child, sizeBytes: size, isDirectory: true)
            }
            guard let size = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize,
                  size > 0 else { return nil }
            return Node(url: child, sizeBytes: Int64(size), isDirectory: false)
        }
        .sorted { $0.sizeBytes > $1.sizeBytes }
    }
}

/// Squarified treemap layout (Bruls et al.): places areas as near-square tiles.
enum Treemap {

    /// Lay out `areas` (sorted descending, in any unit) inside `bounds`.
    /// Returns one rect per input area, same order.
    static func squarify(_ areas: [Double], in bounds: CGRect) -> [CGRect] {
        guard !areas.isEmpty else { return [] }
        let total = areas.reduce(0, +)
        guard total > 0, bounds.width > 1, bounds.height > 1 else {
            return Array(repeating: .zero, count: areas.count)
        }
        // Normalize so area units == points².
        let scale = Double(bounds.width * bounds.height) / total
        let scaled = areas.map { $0 * scale }

        var result = [CGRect](repeating: .zero, count: areas.count)
        var rect = bounds
        var start = 0

        while start < scaled.count {
            let side = Double(min(rect.width, rect.height))
            // Grow the row while the worst aspect ratio keeps improving.
            var end = start + 1
            var rowSum = scaled[start]
            var best = worstRatio(scaled[start..<end], rowSum, side)
            while end < scaled.count {
                let candidateSum = rowSum + scaled[end]
                let candidate = worstRatio(scaled[start..<(end + 1)], candidateSum, side)
                if candidate > best { break }
                best = candidate
                rowSum = candidateSum
                end += 1
            }

            // Lay the row along the shorter side of the remaining rect.
            let thickness = CGFloat(rowSum / side)
            if rect.width >= rect.height {
                var y = rect.minY
                for i in start..<end {
                    let h = CGFloat(scaled[i]) / thickness
                    result[i] = CGRect(x: rect.minX, y: y, width: thickness, height: h)
                    y += h
                }
                rect = CGRect(x: rect.minX + thickness, y: rect.minY,
                              width: rect.width - thickness, height: rect.height)
            } else {
                var x = rect.minX
                for i in start..<end {
                    let w = CGFloat(scaled[i]) / thickness
                    result[i] = CGRect(x: x, y: rect.minY, width: w, height: thickness)
                    x += w
                }
                rect = CGRect(x: rect.minX, y: rect.minY + thickness,
                              width: rect.width, height: rect.height - thickness)
            }
            start = end
        }
        return result
    }

    private static func worstRatio(_ row: ArraySlice<Double>, _ sum: Double, _ side: Double) -> Double {
        guard let maxArea = row.max(), let minArea = row.min(), sum > 0, side > 0 else { return .infinity }
        let s2 = sum * sum
        let w2 = side * side
        return max((w2 * maxArea) / s2, s2 / (w2 * minArea))
    }
}
