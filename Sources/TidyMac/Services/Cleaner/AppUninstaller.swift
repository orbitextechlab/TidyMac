import Foundation
import AppKit

/// Finds installed applications and the support files they scatter across the
/// Library folders, so an uninstall removes leftovers rather than just the
/// `.app` bundle.
final class AppUninstaller {

    struct InstalledApp: Identifiable {
        let id = UUID()
        let name: String
        let bundleID: String
        let url: URL
        let sizeBytes: Int64
        let icon: NSImage
    }

    struct Leftover: Identifiable {
        let id = UUID()
        let url: URL
        let sizeBytes: Int64
        /// True when the file name matches the app's bundle identifier — the
        /// only match strong enough to pre-select. Name-based matches are shown
        /// unchecked as "possible match".
        let matchedByBundleID: Bool
        var isSelected: Bool
    }

    private let fileManager = FileManager.default

    /// Enumerate user-facing apps in /Applications and ~/Applications.
    func installedApps() -> [InstalledApp] {
        let roots = [URL(fileURLWithPath: "/Applications"),
                     fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var apps: [InstalledApp] = []
        for root in roots {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil) else { continue }
            for url in entries where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url),
                      let bundleID = bundle.bundleIdentifier else { continue }
                let name = (bundle.infoDictionary?["CFBundleName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                apps.append(InstalledApp(name: name, bundleID: bundleID, url: url,
                                         sizeBytes: 0, icon: icon))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Locate support files that belong to an app, matched by bundle identifier.
    /// The Library folders apps scatter support files across. Shared with
    /// `OrphanScanner` on purpose: leftovers and orphans must be found in
    /// exactly the same places, or the app could offer to remove something in
    /// one screen that the other cannot account for.
    static let supportSearchPaths = [
        "Library/Application Support",
        "Library/Caches",
        "Library/Preferences",
        "Library/Logs",
        "Library/Containers",
        "Library/Saved Application State",
        "Library/WebKit",
        "Library/HTTPStorages",
    ]

    static func supportSearchDirs(home: URL) -> [URL] {
        supportSearchPaths.map { home.appendingPathComponent($0) }
    }

    func leftovers(for app: InstalledApp) -> [Leftover] {
        let home = fileManager.homeDirectoryForCurrentUser
        let searchDirs = Self.supportSearchDirs(home: home)

        var found: [Leftover] = []
        let bundleNeedle = app.bundleID.lowercased()
        // Name matching is dangerous for short/generic names ("R", "Mail"):
        // require a reasonable length and whole-token equality, never substring.
        let nameNeedle = app.name.lowercased()
        let nameTokens = nameNeedle.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let nameMatchingEnabled = nameNeedle.count >= 4 && !nameTokens.isEmpty

        for dir in searchDirs {
            guard let children = try? fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for child in children {
                let lower = child.lastPathComponent.lowercased()

                // Bundle-ID match: exact, dot-extended ("com.app.helper"), or a
                // file named after it ("com.app.plist"). Reverse-DNS ids are
                // specific enough that containment is safe.
                let byBundleID = !bundleNeedle.isEmpty && lower.contains(bundleNeedle)

                // Name match: every word of the app name must appear as a whole
                // token in the file name ("Google Chrome" ⊂ "Google Chrome HW Cache").
                let byName: Bool = {
                    guard nameMatchingEnabled, !byBundleID else { return false }
                    let childTokens = Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
                    return nameTokens.allSatisfy { childTokens.contains($0) }
                }()

                if byBundleID || byName {
                    found.append(Leftover(url: child, sizeBytes: size(of: child),
                                          matchedByBundleID: byBundleID,
                                          isSelected: byBundleID))
                }
            }
        }
        return found.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Move the app bundle and selected leftovers to the Trash.
    func uninstall(_ app: InstalledApp, leftovers: [Leftover]) -> [String] {
        var failed: [String] = []
        let targets = [app.url] + leftovers.filter { $0.isSelected }.map { $0.url }
        for url in targets {
            do {
                try DeletionGuard.perform(on: url, scope: .appUninstall) { approved in
                    try fileManager.trashItem(at: approved, resultingItemURL: nil)
                }
            } catch {
                failed.append(url.path)
            }
        }
        return failed
    }

    private func size(of url: URL) -> Int64 {
        var total: Int64 = 0
        if let e = fileManager.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
            for case let f as URL in e {
                let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                total += Int64(v?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
