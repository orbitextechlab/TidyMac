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

    // MARK: - Prompt-free path (installed setuid helper, resident)

    // The firmware honors manual fan control only while the controlling SMC
    // connection stays open — it reverts everything the moment the client
    // exits. So the prompt-free path keeps one helper process resident in
    // `serve` mode for as long as any fan is overridden, talking to it over
    // stdin. If this app dies, the helper sees EOF and resets every fan.
    private var serveProcess: Process?
    private var serveInput: FileHandle?

    /// Set a fan via the resident privileged helper — no password prompt.
    /// Used by the automatic fan curve engine.
    func setManualDirect(fanIndex: Int, rpm: Double) throws {
        try send("set \(fanIndex) \(Int(rpm))")
    }

    /// Return one fan to firmware control via the resident helper.
    func setAutomaticDirect(fanIndex: Int) throws {
        try send("auto \(fanIndex)")
    }

    /// Reset all fans and let the resident helper exit — nothing left to hold.
    func resetAllDirect() throws {
        if let process = serveProcess, process.isRunning {
            try? send("quit")
            process.waitUntilExit()
            serveProcess = nil
            serveInput = nil
            return
        }
        // No resident helper: a one-shot reset still works, because handing
        // control *back* to the firmware is the one write that never reverts.
        guard HelperInstaller.isInstalled else {
            throw ControlError.failed("Privileged helper not installed")
        }
        _ = try AdminRunner.run(HelperInstaller.installedPath, ["reset"])
    }

    private func send(_ command: String) throws {
        try ensureServing()
        guard let input = serveInput else {
            throw ControlError.failed("Helper connection lost")
        }
        input.write(Data((command + "\n").utf8))
    }

    private func ensureServing() throws {
        if let process = serveProcess, process.isRunning { return }
        guard HelperInstaller.isInstalled else {
            throw ControlError.failed("Privileged helper not installed")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: HelperInstaller.installedPath)
        process.arguments = ["serve"]
        let stdin = Pipe()
        process.standardInput = stdin
        // Replies are a debugging aid, not a protocol we block on.
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw ControlError.failed("Could not start the fan helper: \(error.localizedDescription)")
        }
        serveProcess = process
        serveInput = stdin.fileHandleForWriting
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
