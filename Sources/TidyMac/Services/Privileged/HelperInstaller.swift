import Foundation
import CryptoKit

/// Installs the bundled `smc-helper` as a setuid-root tool so the fan curve
/// engine can adjust fans without prompting for a password on every write.
///
/// This is the smcFanControl approach: one admin prompt copies the helper to a
/// root-owned location with the setuid bit; later invocations run it directly.
/// The helper itself only knows how to read/write fan SMC keys, which bounds
/// what the elevated binary can be used for.
enum HelperInstaller {

    static let installDir = "/Library/Application Support/TidyMac"
    static let installedPath = installDir + "/smc-helper"

    /// True when a root-owned setuid copy of the helper is in place.
    static var isInstalled: Bool {
        var st = stat()
        guard stat(installedPath, &st) == 0 else { return false }
        let isSetuid = (st.st_mode & S_ISUID) != 0
        let isRootOwned = st.st_uid == 0
        return isSetuid && isRootOwned
    }

    /// True when the installed copy is not the helper this build ships.
    ///
    /// A stale helper is worse than none: an older one wrote fan targets in the
    /// wrong SMC encoding, so it took manual control and then left the target at
    /// zero — pinning fans at minimum. The app therefore refuses to use an
    /// outdated helper for background control until it is replaced.
    static var isOutdated: Bool {
        guard isInstalled,
              let bundled = bundledHelperPath,
              let shipped = try? Data(contentsOf: URL(fileURLWithPath: bundled)),
              let installed = try? Data(contentsOf: URL(fileURLWithPath: installedPath))
        else { return false }
        return SHA256.hash(data: shipped) != SHA256.hash(data: installed)
    }

    /// Installed, current, and therefore safe to drive fans unattended.
    static var isUsable: Bool { isInstalled && !isOutdated }

    /// The bundled helper inside the app (source of the install copy).
    static var bundledHelperPath: String? {
        guard let exec = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("smc-helper").path,
            FileManager.default.isExecutableFile(atPath: exec) else { return nil }
        return exec
    }

    /// Copy the bundled helper to the privileged location. One admin prompt.
    static func install() throws {
        guard let source = bundledHelperPath else {
            throw AdminRunner.RunError.launchFailed("bundled smc-helper not found")
        }
        let quotedSource = shellQuote(source)
        let quotedDest = shellQuote(installedPath)
        let quotedDir = shellQuote(installDir)
        // Single batched command → single authentication dialog.
        let command = [
            "/bin/mkdir -p \(quotedDir)",
            "/bin/cp -f \(quotedSource) \(quotedDest)",
            "/usr/sbin/chown root:wheel \(quotedDest)",
            "/bin/chmod 4755 \(quotedDest)",
        ].joined(separator: " && ")
        _ = try AdminRunner.runElevated(command, reason: "Install fan control helper")
    }

    /// Remove the privileged helper (one admin prompt).
    static func uninstall() throws {
        _ = try AdminRunner.runElevated("/bin/rm -f \(shellQuote(installedPath))",
                                        reason: "Remove fan control helper")
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
