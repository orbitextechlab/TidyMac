import Foundation
import AppKit

/// Reads which apps hold privacy permissions (TCC) and revokes them on
/// request via `tccutil reset`.
///
/// The user-level TCC database (~/Library/Application Support/com.apple.TCC)
/// is only readable with Full Disk Access; without it we surface a clear
/// explanation instead of an empty list. System-scoped services (Screen
/// Recording, Accessibility, Full Disk Access itself) live in the root-owned
/// database and can be loaded with one admin prompt.
enum PermissionsService {

    struct Grant: Identifiable {
        var id: String { service + "|" + client }
        let service: String        // raw kTCCService identifier
        let client: String         // bundle id (or binary path)
        let allowed: Bool
        let isSystemScope: Bool

        var serviceName: String { PermissionsService.friendlyNames[service] ?? shortService }
        var shortService: String { service.replacingOccurrences(of: "kTCCService", with: "") }
        /// Name tccutil expects (the identifier without the kTCCService prefix).
        var tccutilName: String { shortService }
    }

    static let friendlyNames: [String: String] = [
        "kTCCServiceCamera": "Camera",
        "kTCCServiceMicrophone": "Microphone",
        "kTCCServiceScreenCapture": "Screen Recording",
        "kTCCServiceAccessibility": "Accessibility",
        "kTCCServiceSystemPolicyAllFiles": "Full Disk Access",
        "kTCCServiceSystemPolicyDesktopFolder": "Desktop Folder",
        "kTCCServiceSystemPolicyDocumentsFolder": "Documents Folder",
        "kTCCServiceSystemPolicyDownloadsFolder": "Downloads Folder",
        "kTCCServiceSystemPolicyNetworkVolumes": "Network Volumes",
        "kTCCServiceSystemPolicyRemovableVolumes": "Removable Volumes",
        "kTCCServiceSystemPolicyDeveloperFiles": "Developer Files",
        "kTCCServiceAppleEvents": "Automation (Apple Events)",
        "kTCCServiceListenEvent": "Input Monitoring",
        "kTCCServicePostEvent": "Send Keystrokes",
        "kTCCServicePhotos": "Photos",
        "kTCCServiceAddressBook": "Contacts",
        "kTCCServiceCalendar": "Calendar",
        "kTCCServiceReminders": "Reminders",
        "kTCCServiceLocation": "Location",
        "kTCCServiceBluetoothAlways": "Bluetooth",
        "kTCCServiceSpeechRecognition": "Speech Recognition",
        "kTCCServiceMediaLibrary": "Media Library",
        "kTCCServiceFileProviderDomain": "File Provider",
        "kTCCServiceUbiquity": "iCloud",
    ]

    enum FetchError: Error {
        case needsFullDiskAccess
        case queryFailed(String)
    }

    private static let userDB = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
    private static let systemDB = "/Library/Application Support/com.apple.TCC/TCC.db"
    private static let query =
        "SELECT service, client, auth_value FROM access WHERE client_type = 0;"

    // MARK: - Fetch

    /// User-scope grants (camera, mic, folders, automation…).
    static func fetchUserGrants() -> Result<[Grant], FetchError> {
        do {
            let out = try AdminRunner.run("/usr/bin/sqlite3",
                                          ["-separator", "|", userDB, query])
            return .success(parse(out, systemScope: false))
        } catch {
            let message = "\(error)"
            if message.contains("unable to open") || message.contains("authorization denied")
                || message.contains("not authorized") {
                return .failure(.needsFullDiskAccess)
            }
            return .failure(.queryFailed(message))
        }
    }

    /// System-scope grants (Screen Recording, Accessibility, Full Disk Access).
    /// Requires one admin prompt.
    static func fetchSystemGrants() throws -> [Grant] {
        let out = try AdminRunner.runElevated(
            "/usr/bin/sqlite3 -separator '|' '\(systemDB)' \"\(query)\"",
            reason: "Read system permission list")
        return parse(out, systemScope: true)
    }

    private static func parse(_ output: String, systemScope: Bool) -> [Grant] {
        output.split(separator: "\n").compactMap { line -> Grant? in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count >= 3, let auth = Int(parts[2]) else { return nil }
            let service = String(parts[0])
            // Skip internal/uninteresting service rows.
            guard service.hasPrefix("kTCCService") else { return nil }
            return Grant(service: service,
                         client: String(parts[1]),
                         allowed: auth == 2 || auth == 3,   // 2 allowed, 3 limited
                         isSystemScope: systemScope)
        }
    }

    // MARK: - Revoke

    /// Reset one app's permission for a service. The app will re-prompt the
    /// next time it needs the permission.
    static func revoke(_ grant: Grant) throws {
        do {
            _ = try AdminRunner.run("/usr/bin/tccutil", ["reset", grant.tccutilName, grant.client])
        } catch {
            // Some services only reset with admin rights.
            _ = try AdminRunner.runElevated(
                "/usr/bin/tccutil reset \(grant.tccutilName) '\(grant.client)'",
                reason: "Revoke permission")
        }
    }

    // MARK: - App metadata

    static func appInfo(for bundleID: String) -> (name: String, icon: NSImage?) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName
                ?? url.deletingPathExtension().lastPathComponent
            return (name, NSWorkspace.shared.icon(forFile: url.path))
        }
        // Client may be a raw binary path rather than a bundle id.
        if bundleID.hasPrefix("/") {
            return (URL(fileURLWithPath: bundleID).lastPathComponent, nil)
        }
        return (bundleID, nil)
    }

    static func openPrivacySettings(pane: String = "Privacy_AllFiles") {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        NSWorkspace.shared.open(url)
    }
}
