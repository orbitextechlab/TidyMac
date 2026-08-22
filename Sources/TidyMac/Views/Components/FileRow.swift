import SwiftUI
import AppKit

/// Process-wide file-icon cache. NSWorkspace icon lookups hit Launch Services
/// synchronously, which stutters a scrolling list — resolve each path once,
/// off the main thread, and reuse the image afterwards.
private enum FileIconCache {
    static let images = NSCache<NSString, NSImage>()

    static func cached(_ path: String) -> NSImage? {
        images.object(forKey: path as NSString)
    }

    static func store(_ image: NSImage, for path: String) {
        images.setObject(image, forKey: path as NSString)
    }
}

/// File icon backed by that cache. A cached path renders in the very first
/// frame (no async hop); an unseen one shows a placeholder for a beat while the
/// real icon is fetched off the main thread.
struct FileIconView: View {
    let url: URL
    @State private var icon: NSImage?

    init(url: URL) {
        self.url = url
        _icon = State(initialValue: FileIconCache.cached(url.path))
    }

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: url.hasDirectoryPath ? "folder.fill" : "doc.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.quaternary)
            }
        }
        .frame(width: 22, height: 22)
        .task(id: url.path) {
            guard icon == nil else { return }
            let path = url.path
            let resolved = await Task.detached(priority: .utility) {
                NSWorkspace.shared.icon(forFile: path)
            }.value
            FileIconCache.store(resolved, for: path)
            icon = resolved
        }
    }
}

/// Standard row for anything deletable: file icon, name, the FULL path (always
/// visible, Revo-Uninstaller style, so the user knows exactly what a checkbox
/// refers to), and the size. Right-click offers Reveal in Finder / Copy Path.
///
/// Deliberately free of `.help` and `.textSelection`: both add per-row tracking
/// machinery that makes a long list stutter while scrolling, and the path is
/// already on screen with Copy Path a right-click away.
struct FileRow: View {
    let url: URL
    let sizeBytes: Int64?
    var detail: String? = nil   // optional extra caption (e.g. modified date)

    var body: some View {
        HStack(spacing: 8) {
            FileIconView(url: url)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(url.lastPathComponent).lineLimit(1)
                    if let detail {
                        Text(detail).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Text(url.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if let sizeBytes {
                Text(Format.bytes(sizeBytes))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            }
        }
    }
}
