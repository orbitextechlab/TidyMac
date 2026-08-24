import AppKit
import Foundation

/// Finds support files whose owning application is no longer installed —
/// `AppUninstaller` run backwards. Where the uninstaller asks "what belongs to
/// this app", this asks "what belongs to no app at all".
///
/// The whole design problem here is false positives. A file wrongly called an
/// orphan is a user's data offered up for deletion, so the scan is deliberately
/// narrow rather than thorough.
///
/// **Only `Library/Containers` and `Library/Saved Application State` are
/// searched.** An earlier version walked all eight folders `AppUninstaller`
/// uses and produced 73 findings on a test machine, of which almost none were
/// real: `Application Support`, `Caches`, `Preferences`, `Logs`, `WebKit` and
/// `HTTPStorages` hold state for command-line tools, daemons, frameworks and
/// system services — Homebrew, CocoaPods, pnpm, GeoServices, PassKit — none of
/// which is an application bundle, so none can be found in any index of
/// installed apps. Those folders cannot be judged this way at all. Containers
/// and saved state are created only by applications, which is what makes the
/// question answerable there.
///
/// The remaining rules:
///
///  - The installed-app index spans far more than /Applications. Apps live in
///    `~/Applications`, Setapp's folder, project build directories, anywhere.
///    Spotlight is asked for every application bundle on the machine, and its
///    answers are unioned with a direct scan of the standard folders.
///  - **If that index cannot be built, the scan returns nothing.** An empty or
///    implausibly small index would mark every container as orphaned; that
///    failure mode must be impossible, so it is checked explicitly.
///  - Running processes count as installed, whatever the index says.
///  - Apple's own bundle identifiers are never reported.
///  - Only reverse-DNS names are judged; nothing is ever pre-selected.
final class OrphanScanner {

    struct Orphan: Identifiable {
        let id = UUID()
        let url: URL
        let sizeBytes: Int64
        /// The bundle identifier the file appears to belong to.
        let claimedOwner: String
        var isSelected: Bool = false
    }

    enum ScanError: Error, CustomStringConvertible {
        case indexUnavailable
        var description: String {
            switch self {
            case .indexUnavailable:
                return "Could not build a reliable list of installed apps, so nothing is reported. "
                     + "Spotlight indexing may be off for this volume."
            }
        }
    }

    private let fileManager = FileManager.default

    /// The only two Library folders created exclusively by applications, and
    /// therefore the only two where "no installed app claims this" is a
    /// meaningful statement. See the type comment for why the rest are not
    /// searched.
    static func searchDirs(home: URL) -> [URL] {
        ["Library/Containers", "Library/Saved Application State"]
            .map { home.appendingPathComponent($0) }
    }

    /// Below this, the index is not credible — every Mac has more applications
    /// than this — and reporting orphans from it would be reckless.
    private static let minimumCredibleIndexSize = 20

    // MARK: - Scan

    func scan(isCancelled: () -> Bool = { false }) throws -> [Orphan] {
        let index = installedIdentifiers()
        guard index.count >= Self.minimumCredibleIndexSize else {
            throw ScanError.indexUnavailable
        }

        let home = fileManager.homeDirectoryForCurrentUser
        var found: [Orphan] = []

        for dir in Self.searchDirs(home: home) {
            guard !isCancelled() else { return [] }
            guard let children = try? fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }

            for child in children {
                guard !isCancelled() else { return [] }
                guard let orphan = classify(child, against: index) else { continue }
                found.append(orphan)
            }
        }
        return found.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    // MARK: - Classification

    private func classify(_ url: URL, against index: Set<String>) -> Orphan? {
        let name = url.lastPathComponent
        // Strip a trailing file extension that is not part of an identifier,
        // so "com.foo.bar.plist" is judged as "com.foo.bar".
        let stem = Self.identifierStem(of: name)
        let lower = stem.lowercased()

        // Apple's own state is never a useful orphan, and removing it breaks
        // system behavior in ways the user cannot connect back to this app.
        guard !lower.hasPrefix("com.apple.") else { return nil }

        // Anything that is not a reverse-DNS identifier cannot be attributed
        // to an app with confidence, so it is not judged at all.
        guard Self.looksLikeBundleID(lower) else { return nil }
        guard !index.contains(lower) else { return nil }
        // A prefix match covers helper identifiers: "com.foo.app.helper"
        // belongs to "com.foo.app" and is not orphaned while it is around.
        guard !index.contains(where: { lower.hasPrefix($0 + ".") }) else { return nil }
        return Orphan(url: url, sizeBytes: size(of: url), claimedOwner: stem)
    }

    /// Reverse-DNS shape: at least three dot-separated, non-empty components
    /// made of identifier characters.
    private static func looksLikeBundleID(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }

    /// "com.foo.bar.plist" and "com.foo.bar.savedState" both describe
    /// com.foo.bar; drop a trailing component that is a known wrapper suffix.
    private static func identifierStem(of name: String) -> String {
        let wrappers = ["plist", "savedstate", "binarycookies", "sfl2", "sfl3"]
        for wrapper in wrappers where name.lowercased().hasSuffix("." + wrapper) {
            return String(name.dropLast(wrapper.count + 1))
        }
        return name
    }

    // MARK: - Installed-app index

    /// Every bundle identifier this Mac can be said to have installed.
    private func installedIdentifiers() -> Set<String> {
        var ids = Set<String>()

        for url in applicationBundleURLs() {
            guard let bundle = Bundle(url: url) else { continue }
            if let id = bundle.bundleIdentifier?.lowercased(), !id.isEmpty {
                ids.insert(id)
            }
        }

        // A running process is installed by definition, whatever Spotlight
        // thinks — this is the backstop for anything the index missed.
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier?.lowercased() { ids.insert(id) }
        }
        return ids
    }

    /// Application bundles anywhere on the machine: Spotlight first, then the
    /// conventional folders so a disabled index cannot silently shrink the
    /// picture.
    private func applicationBundleURLs() -> [URL] {
        var urls = spotlightApplicationBundles()

        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Setapp"),
        ]
        for root in roots {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil) else { continue }
            urls.append(contentsOf: entries.filter { $0.pathExtension == "app" })
        }
        return urls
    }

    /// Ask Spotlight for every application bundle. This is what catches apps in
    /// project folders, Setapp, disk images the user runs in place, and other
    /// locations no fixed list would predict.
    private func spotlightApplicationBundles() -> [URL] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["kMDItemContentType == 'com.apple.application-bundle'"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }

    // MARK: - Sizing

    private func size(of url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        // Hidden files are counted here, unlike elsewhere: a sandbox container
        // keeps its metadata and often its payload behind dot-files, and
        // skipping them reports a real container as Zero KB.
        guard let e = fileManager.enumerator(at: url,
                                             includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                                             options: []) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in e {
            let values = try? child.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }
}
