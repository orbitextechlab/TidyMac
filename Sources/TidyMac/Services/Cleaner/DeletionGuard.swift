import Foundation

/// The single gate every deletion in the app passes through.
///
/// The scanners decide what to *offer*; this decides what may actually be
/// removed, and the two are deliberately independent. A scanner is a heuristic
/// and heuristics are wrong sometimes — `LargeFilesService` once offered every
/// application in `/Applications` as a "large old file" because an `.app` is a
/// package and packages were reported as single items. Nothing downstream
/// questioned it, because nothing downstream existed. A scanner bug should cost
/// the user a confusing list, never their data.
///
/// So each call site declares the `Scope` it is entitled to, and a target is
/// removable only when it sits **strictly inside** one of that scope's roots.
/// Equal-to-the-root is refused as well: every scanner in this app lists the
/// children of a root, so a target that *is* a root means something went wrong.
///
/// *(Two-layer model and the cloud-provider denylist follow PureMac's
/// CleaningEngine, MIT — see NOTICE.)*
enum DeletionGuard {

    /// What a particular call site is allowed to touch.
    enum Scope {
        /// `CleaningEngine` — regenerable junk under Library and the dotfile
        /// caches, plus Downloads and the Trash.
        case systemJunk
        /// `LargeFilesService` and `DuplicatesService` — the user's own
        /// documents, one file at a time.
        case userFiles
        /// `AppUninstaller` — an application bundle and the support files that
        /// belong to it. The only scope that may reach `/Applications`.
        case appUninstall
    }

    enum Refusal: Error, CustomStringConvertible {
        case providerOwned
        case outsideScope
        case resolutionChanged

        var description: String {
            switch self {
            case .providerOwned:
                return "cloud sync state — never removable"
            case .outsideScope:
                return "outside the folders this screen may clean"
            case .resolutionChanged:
                return "path changed while it was being removed"
            }
        }
    }

    // MARK: - Cloud provider denylist

    /// State owned by iCloud Drive and the other File Provider extensions.
    ///
    /// These directories are the providers' own bookkeeping. Removing a file
    /// underneath one with `unlink` tells the provider nothing, so its snapshot
    /// and the filesystem drift apart: sync reports broken invariants and reads
    /// out of iCloud Drive slow to a crawl while it reconciles. They live in
    /// `Caches` and `Application Support` and look exactly like junk, which is
    /// why the check has to be explicit and has to run before anything else.
    ///
    /// Denied in every scope. No amount of reclaimed space is worth corrupting
    /// somebody's cloud sync.
    static func providerDeniedRoots(home: URL) -> [String] {
        [
            "Library/Mobile Documents",              // iCloud Drive
            "Library/CloudStorage",                  // Dropbox, OneDrive, Google Drive…
            "Library/Application Support/FileProvider",
            "Library/Application Support/CloudDocs",
            "Library/Daemon Containers",             // provider extension containers
            // Live databases despite sitting in Caches.
            "Library/Caches/CloudKit",
        ].map { home.appendingPathComponent($0).path }
    }

    /// Bundle-identifier prefixes owned by the sync daemons.
    ///
    /// Matched as a prefix of a whole path component, not as a root, because
    /// these arrive as families rather than single directories: alongside
    /// `com.apple.FileProviderDaemon` there is
    /// `com.apple.FileProviderDaemon.AppStoreService`, and more appear with each
    /// macOS release. Listing the parent directory does not cover the siblings —
    /// they are neighbours, not children — so the name itself has to be the key.
    static let providerIdentifierPrefixes = [
        "com.apple.bird",
        "com.apple.cloudd",
        "com.apple.cloudkit",
        "com.apple.fileprovider",
        "com.apple.itunescloudd",
        "com.apple.icloud",
    ]

    /// True when the path is provider-owned and must be left alone.
    ///
    /// Checked against the literal path *and* its symlink-resolved form. That
    /// second pass is the one that matters: with "Desktop & Documents Folders"
    /// syncing turned on, `~/Desktop` resolves into
    /// `~/Library/Mobile Documents/com~apple~CloudDocs`, so an ordinary-looking
    /// root walks straight into iCloud state.
    static func isProviderOwned(_ url: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let denied = providerDeniedRoots(home: home)
        let candidates = [url.standardizedFileURL.path,
                          url.resolvingSymlinksInPath().path]
        for candidate in candidates {
            // A `com~apple~CloudDocs`-style component marks provider territory
            // wherever it appears, not only under the roots listed above.
            if candidate.contains("com~apple~") { return true }
            for root in denied where candidate == root || candidate.hasPrefix(root + "/") {
                return true
            }
            // Whole components only: a prefix test against the raw path would
            // let a directory merely *named* like a provider elsewhere match,
            // and would miss nothing that this does not already catch.
            for component in candidate.split(separator: "/") {
                let name = component.lowercased()
                if providerIdentifierPrefixes.contains(where: { name.hasPrefix($0) }) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Scope roots

    /// The folders each scope may remove things from. Kept in one place so the
    /// answer to "what can this app delete?" is readable in one screenful.
    static func roots(for scope: Scope, home: URL) -> [String] {
        func h(_ path: String) -> String { home.appendingPathComponent(path).path }

        switch scope {
        case .systemJunk:
            return [
                h("Library/Caches"),
                h("Library/Logs"),
                h("Library/Application Support/CrashReporter"),
                h("Library/Application Support/MobileSync/Backup"),
                h("Library/Developer/Xcode/DerivedData"),
                h("Library/Developer/Xcode/iOS DeviceSupport"),
                h("Library/Developer/Xcode/Archives"),
                h("Library/Developer/CoreSimulator/Caches"),
                h("Library/Containers/com.apple.mail/Data/Library/Mail Downloads"),
                h("Library/pnpm/store"),
                h(".npm"),
                h(".cache"),
                h(".gradle/caches"),
                h(".gradle/daemon"),
                h(".cocoapods"),
                h(".bun/install/cache"),
                h(".conda/pkgs"),
                h(".m2/repository"),
                h(".ivy2/cache"),
                h(".nuget/packages"),
                h("Downloads"),
                h(".Trash"),
            ]

        case .userFiles:
            return ["Downloads", "Documents", "Desktop",
                    "Pictures", "Movies", "Music"].map(h)

        case .appUninstall:
            // The app bundle itself, plus the Library folders where apps leave
            // support files. `Application Support` is broad on purpose — that is
            // where leftovers live — which is exactly why the provider denylist
            // runs first and unconditionally.
            return ["/Applications", h("Applications")] + [
                "Library/Application Support",
                "Library/Caches",
                "Library/Preferences",
                "Library/Logs",
                "Library/Containers",
                "Library/Saved Application State",
                "Library/WebKit",
                "Library/HTTPStorages",
            ].map(h)
        }
    }

    // MARK: - Authorization

    /// Approve a target and return the URL the caller must delete through.
    ///
    /// The returned URL is symlink-resolved: deleting through the path as
    /// given would let anything that can write a component swap it for a link
    /// after the check and have the delete follow it somewhere else. The
    /// resolved path is what gets range-checked, so a symlink inside
    /// `~/Library/Caches` pointing at `~/.ssh` fails the scope test.
    static func authorize(_ url: URL, scope: Scope) throws -> URL {
        guard !isProviderOwned(url) else { throw Refusal.providerOwned }

        let resolved = url.resolvingSymlinksInPath()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = resolved.path

        // Strictly inside, never equal: the scanners list a root's children, so
        // a target equal to a root means the caller lost track of what it had.
        let allowed = roots(for: scope, home: home).contains { root in
            path.hasPrefix(root + "/")
        }
        guard allowed else { throw Refusal.outsideScope }
        return resolved
    }

    /// Re-check immediately before the delete and confirm the path still
    /// resolves where it did during `authorize`. Narrows the window in which a
    /// component could be swapped between the check and the removal.
    static func confirmUnchanged(_ url: URL, resolvesTo approved: URL) throws {
        guard url.resolvingSymlinksInPath().path == approved.path else {
            throw Refusal.resolutionChanged
        }
    }

    /// `authorize` + `confirmUnchanged` + the removal itself, so no call site
    /// can accidentally perform two of the three.
    ///
    /// - Parameter remove: performs the actual deletion on the approved URL —
    ///   `trashItem` everywhere except the Trash category, which has nowhere
    ///   left to move things to.
    static func perform(on url: URL, scope: Scope,
                        remove: (URL) throws -> Void) throws {
        let approved = try authorize(url, scope: scope)
        try confirmUnchanged(url, resolvesTo: approved)
        try remove(approved)
    }
}
