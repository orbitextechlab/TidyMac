import Foundation

/// Lists and toggles startup entries: launchd agents/daemons (plists) and the
/// classic System Events login items.
///
/// Disabling a plist item renames it to `<name>.plist.disabled` and boots the
/// job out of launchd, so the change survives reboots and is trivially
/// reversible. System locations go through the admin prompt.
enum StartupItemsService {

    enum Scope: String, CaseIterable {
        case loginItem = "Login Items"
        case userAgent = "Your Launch Agents"
        case globalAgent = "System Launch Agents"
        case daemon = "Launch Daemons"

        var needsAdmin: Bool { self == .globalAgent || self == .daemon }
        var directory: String? {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            switch self {
            case .loginItem: return nil
            case .userAgent: return home + "/Library/LaunchAgents"
            case .globalAgent: return "/Library/LaunchAgents"
            case .daemon: return "/Library/LaunchDaemons"
            }
        }
    }

    struct Item: Identifiable {
        var id: String { (plistURL?.path ?? "loginitem:" + name) }
        let name: String            // label or login-item name
        let programPath: String?
        let plistURL: URL?          // nil for login items
        let scope: Scope
        var isDisabled: Bool
    }

    private static let disabledSuffix = ".plist.disabled"

    // MARK: - Listing

    static func list() -> [Item] {
        var items: [Item] = []
        for scope in Scope.allCases {
            switch scope {
            case .loginItem:
                items.append(contentsOf: loginItems())
            default:
                items.append(contentsOf: plistItems(in: scope))
            }
        }
        return items
    }

    private static func plistItems(in scope: Scope) -> [Item] {
        guard let dir = scope.directory else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { url in
            let name = url.lastPathComponent
            let isDisabled = name.hasSuffix(disabledSuffix)
            guard name.hasSuffix(".plist") || isDisabled else { return nil }
            let plist = NSDictionary(contentsOf: url)
            let label = plist?["Label"] as? String
                ?? name.replacingOccurrences(of: disabledSuffix, with: "")
                       .replacingOccurrences(of: ".plist", with: "")
            let program = plist?["Program"] as? String
                ?? (plist?["ProgramArguments"] as? [String])?.first
            return Item(name: label, programPath: program, plistURL: url,
                        scope: scope, isDisabled: isDisabled)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func loginItems() -> [Item] {
        let script = "tell application \"System Events\" to get the name of every login item"
        guard let out = try? AdminRunner.run("/usr/bin/osascript", ["-e", script]),
              !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: ", ")
            .filter { !$0.isEmpty }
            .map { Item(name: $0, programPath: nil, plistURL: nil, scope: .loginItem, isDisabled: false) }
    }

    // MARK: - Toggling

    /// Enable/disable a plist-based item, or remove a login item entirely
    /// (login items have no disabled state — removal is the only toggle).
    static func setDisabled(_ item: Item, _ disable: Bool) throws {
        switch item.scope {
        case .loginItem:
            let script = "tell application \"System Events\" to delete login item \"\(item.name)\""
            _ = try AdminRunner.run("/usr/bin/osascript", ["-e", script])

        case .userAgent:
            guard let url = item.plistURL else { return }
            let target = toggledURL(url, disable: disable)
            if disable {
                _ = try? AdminRunner.run("/bin/launchctl",
                                         ["bootout", "gui/\(getuid())", url.path])
                try FileManager.default.moveItem(at: url, to: target)
            } else {
                try FileManager.default.moveItem(at: url, to: target)
                _ = try? AdminRunner.run("/bin/launchctl",
                                         ["bootstrap", "gui/\(getuid())", target.path])
            }

        case .globalAgent, .daemon:
            guard let url = item.plistURL else { return }
            let target = toggledURL(url, disable: disable)
            let domain = item.scope == .daemon ? "system" : "gui/\(getuid())"
            let quotedFrom = shellQuote(url.path)
            let quotedTo = shellQuote(target.path)
            let command = disable
                ? "/bin/launchctl bootout \(domain) \(quotedFrom) >/dev/null 2>&1; /bin/mv \(quotedFrom) \(quotedTo)"
                : "/bin/mv \(quotedFrom) \(quotedTo) && /bin/launchctl bootstrap \(domain) \(quotedTo) >/dev/null 2>&1 || true"
            _ = try AdminRunner.runElevated(command, reason: "Toggle startup item")
        }
    }

    private static func toggledURL(_ url: URL, disable: Bool) -> URL {
        let dir = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        return disable
            ? dir.appendingPathComponent(name.replacingOccurrences(of: ".plist", with: disabledSuffix))
            : dir.appendingPathComponent(name.replacingOccurrences(of: disabledSuffix, with: ".plist"))
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
