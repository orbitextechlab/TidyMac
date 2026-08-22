import SwiftUI
import AppKit

/// Interactive storage map: a squarified treemap of the scanned folder.
/// Click a folder tile to drill in, use the breadcrumb to climb back out.
struct SpaceLensView: View {
    private static let maxTiles = 30

    @State private var service = SpaceLensService()
    @State private var isScanning = false
    @State private var cancelFlag = CancelFlag()
    @State private var progressText = ""
    @State private var rootURL = FileManager.default.homeDirectoryForCurrentUser
    @State private var pathStack: [URL] = []
    @State private var nodes: [SpaceLensService.Node] = []
    @State private var hasScanned = false
    @State private var statusMessage: String?
    @State private var hoveredID: String?

    private var currentFolder: URL { pathStack.last ?? rootURL }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if hasScanned { breadcrumb }
            Divider()
            content
        }
        .onDisappear { cancelFlag.cancel() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Space Lens").font(.pageTitle)
                if isScanning {
                    Text(progressText.isEmpty ? "Indexing…" : progressText)
                        .font(.caption).foregroundStyle(.secondary)
                } else if let statusMessage {
                    Text(statusMessage).font(.caption).foregroundStyle(Theme.ok)
                } else {
                    Text("See what fills \(rootURL.path) — click folders to drill in")
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
                Button { chooseFolder() } label: { Label("Choose Folder…", systemImage: "folder") }
                Button { scan() } label: { Label(hasScanned ? "Rescan" : "Scan", systemImage: "magnifyingglass") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
        .padding(20)
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                crumb(rootURL, label: rootURL.lastPathComponent)
                ForEach(Array(pathStack.enumerated()), id: \.offset) { _, url in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8)).foregroundStyle(.tertiary)
                    crumb(url, label: url.lastPathComponent)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
    }

    private func crumb(_ url: URL, label: String) -> some View {
        Button {
            if url == rootURL { pathStack = [] }
            else if let idx = pathStack.firstIndex(of: url) { pathStack = Array(pathStack.prefix(through: idx)) }
            reloadNodes()
        } label: {
            Text(label).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .neuRaised(6)
    }

    // MARK: - Treemap

    @ViewBuilder
    private var content: some View {
        if isScanning {
            VStack(spacing: 16) {
                ZStack {
                    SpinnerRing(size: 74, lineWidth: 3)
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(Theme.accent)
                }
                VStack(spacing: 5) {
                    Text("Indexing \(rootURL.path)…")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 460)
                    Text(progressText.isEmpty ? "Walking the file tree…" : progressText)
                        .font(.system(size: 12.5))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                        .contentTransition(.numericText())
                }
                IndeterminateBar().frame(width: 280)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !hasScanned {
            ContentUnavailableView {
                Label("Map your storage", systemImage: "square.grid.3x3.topleft.filled")
            } description: {
                Text("Index \(rootURL.lastPathComponent) once, then explore folder sizes instantly.")
            } actions: {
                Button("Scan Now") { scan() }.buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if nodes.isEmpty {
            ContentUnavailableView("Empty folder", systemImage: "folder")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geo in
                let shown = Array(nodes.prefix(Self.maxTiles))
                let rects = Treemap.squarify(shown.map { Double($0.sizeBytes) },
                                             in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 2, dy: 2))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(zip(shown, rects)), id: \.0.id) { node, rect in
                        tile(node, rect: rect)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .padding(.top, 8)
        }
    }

    private func tile(_ node: SpaceLensService.Node, rect: CGRect) -> some View {
        let fractionOfView = Double(node.sizeBytes) / Double(max(1, nodes.first?.sizeBytes ?? 1))
        let fill = node.isDirectory
            ? Theme.accent.opacity(0.14 + 0.30 * fractionOfView)
            : Color.primary.opacity(0.10)
        let showLabel = rect.width > 64 && rect.height > 34

        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Theme.surface, lineWidth: 1.5)
            )
            .overlay(alignment: .topLeading) {
                if showLabel {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 3) {
                            Image(systemName: node.isDirectory ? "folder.fill" : "doc")
                                .font(.system(size: 8))
                            Text(node.url.lastPathComponent)
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(1)
                        }
                        Text(Format.bytes(node.sizeBytes))
                            .font(.system(size: 9)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(5)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(hoveredID == node.id ? 0.06 : 0))
            )
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .onHover { inside in hoveredID = inside ? node.id : nil }
            .onTapGesture {
                guard node.isDirectory else { return }
                pathStack.append(node.url)
                reloadNodes()
            }
            .help("\(node.url.path) — \(Format.bytes(node.sizeBytes))")
            .contextMenu {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([node.url])
                }
                Button("Move to Trash", role: .destructive) { trash(node) }
            }
    }

    // MARK: - Actions

    private func scan() {
        isScanning = true
        statusMessage = nil
        progressText = ""
        pathStack = []
        let flag = CancelFlag()
        cancelFlag = flag
        let service = self.service
        let root = rootURL
        Task.detached(priority: .userInitiated) {
            let completed = service.scan(root: root, progress: { files, bytes in
                Task { @MainActor in
                    progressText = "Indexed \(files) files — \(Format.bytes(bytes))"
                }
            }, isCancelled: flag.isCancelled)
            await MainActor.run {
                isScanning = false
                if completed {
                    hasScanned = true
                    reloadNodes()
                }
            }
        }
    }

    private func reloadNodes() {
        nodes = service.children(of: currentFolder)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = rootURL
        if panel.runModal() == .OK, let url = panel.url {
            rootURL = url
            hasScanned = false
            pathStack = []
            nodes = []
        }
    }

    private func trash(_ node: SpaceLensService.Node) {
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            nodes.removeAll { $0.id == node.id }
            statusMessage = "Moved \(node.url.lastPathComponent) (\(Format.bytes(node.sizeBytes))) to the Trash — rescan to refresh sizes"
        } catch {
            statusMessage = "Couldn't move \(node.url.lastPathComponent) to the Trash"
        }
    }
}
