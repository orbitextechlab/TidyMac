import Foundation

/// Runs shell commands, optionally elevated. Elevation uses AppleScript's
/// "with administrator privileges", which shows the standard macOS
/// authentication dialog and runs the command as root — the same mechanism the
/// analysed reference app used for privileged deletes and fan unlocks.
///
/// This is intentionally simpler than a full SMJobBless helper: it needs no
/// separate installed daemon, at the cost of prompting each time. Callers
/// should batch privileged work into a single invocation to limit prompts.
enum AdminRunner {

    enum RunError: Error, CustomStringConvertible {
        case nonZeroExit(code: Int32, output: String)
        case launchFailed(String)

        var description: String {
            switch self {
            case .nonZeroExit(let code, let out): return "exit \(code): \(out)"
            case .launchFailed(let m): return "launch failed: \(m)"
            }
        }
    }

    /// Run a command without elevation. Returns stdout.
    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw RunError.launchFailed(error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw RunError.nonZeroExit(code: process.terminationStatus, output: output)
        }
        return output
    }

    /// Run a shell command line as root via an authentication prompt.
    /// `reason` is not shown by AppleScript but kept for logging clarity.
    @discardableResult
    static func runElevated(_ command: String, reason: String = "") throws -> String {
        // Escape embedded quotes/backslashes for the AppleScript string literal.
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return try run("/usr/bin/osascript", ["-e", script])
    }
}
