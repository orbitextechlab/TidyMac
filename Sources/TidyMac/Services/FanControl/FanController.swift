import Foundation

/// High-level fan control used by the UI. Delegates every SMC *write* to the
/// bundled `smc-helper`, invoked with administrator rights. Reading current fan
/// state stays in `SensorService`, which needs no privileges.
final class FanController {

    enum ControlError: Error, CustomStringConvertible {
        case helperMissing
        case failed(String)
        var description: String {
            switch self {
            case .helperMissing: return "smc-helper not found in app bundle"
            case .failed(let m): return m
            }
        }
    }

    /// Location of the helper copied into the app bundle at build time.
    private var helperURL: URL? {
        // Embedded next to the main executable in Contents/MacOS.
        if let exec = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("smc-helper"),
           FileManager.default.isExecutableFile(atPath: exec.path) {
            return exec
        }
        // Fallback: Resources.
        return Bundle.main.url(forResource: "smc-helper", withExtension: nil)
    }

    /// Force a fan to a fixed RPM. Prompts for admin authentication.
    func setManual(fanIndex: Int, rpm: Double) throws {
        try runHelper(["set", "\(fanIndex)", "1", "\(Int(rpm))"])
    }

    // MARK: - Prompt-free path (installed setuid helper)

    /// Set a fan via the installed privileged helper — no password prompt.
    /// Used by the automatic fan curve engine.
    func setManualDirect(fanIndex: Int, rpm: Double) throws {
        try runInstalledHelper(["set", "\(fanIndex)", "1", "\(Int(rpm))"])
    }

    /// Return one fan to firmware control via the installed helper.
    func setAutomaticDirect(fanIndex: Int) throws {
        try runInstalledHelper(["set", "\(fanIndex)", "0"])
    }

    /// Reset all fans via the installed helper — no password prompt.
    func resetAllDirect() throws {
        try runInstalledHelper(["reset"])
    }

    private func runInstalledHelper(_ args: [String]) throws {
        guard HelperInstaller.isInstalled else {
            throw ControlError.failed("Privileged helper not installed")
        }
        _ = try AdminRunner.run(HelperInstaller.installedPath, args)
    }

    /// Return a single fan to firmware-managed automatic control.
    func setAutomatic(fanIndex: Int) throws {
        try runHelper(["set", "\(fanIndex)", "0"])
    }

    /// Return every fan to automatic control.
    func resetAll() throws {
        try runHelper(["reset"])
    }

    private func runHelper(_ args: [String]) throws {
        guard let helper = helperURL else { throw ControlError.helperMissing }
        // Build a single shell command so the whole operation needs one prompt.
        let quoted = ([helper.path] + args)
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        do {
            _ = try AdminRunner.runElevated(quoted, reason: "Adjust fan speed")
        } catch {
            throw ControlError.failed("\(error)")
        }
    }
}
