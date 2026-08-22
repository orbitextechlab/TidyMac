import Foundation
import AppKit

/// Lightweight task-manager backend: samples `ps` for per-process CPU/memory,
/// decorates rows with app names/icons where the pid belongs to a GUI app,
/// and terminates processes on request.
enum ProcessService {

    struct ProcessInfo: Identifiable {
        let id: Int32              // pid
        let name: String
        let cpuPercent: Double
        let rssBytes: Int64
        let isApp: Bool
        let icon: NSImage?
    }

    /// Snapshot of running processes sorted by CPU. Call off the main thread.
    static func sample() -> [ProcessInfo] {
        guard let output = try? AdminRunner.run("/bin/ps", ["axo", "pid=,pcpu=,rss=,comm="]) else {
            return []
        }
        let apps = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications
            .map { ($0.processIdentifier, $0) })

        return output.split(separator: "\n").compactMap { line -> ProcessInfo? in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4,
                  let pid = Int32(parts[0]),
                  let cpu = Double(parts[1]),
                  let rssKB = Int64(parts[2]) else { return nil }
            let command = String(parts[3])
            let app = apps[pid]
            let name = app?.localizedName ?? URL(fileURLWithPath: command).lastPathComponent
            return ProcessInfo(id: pid,
                               name: name,
                               cpuPercent: cpu,
                               rssBytes: rssKB * 1024,
                               isApp: app != nil,
                               icon: app?.icon)
        }
        .sorted { $0.cpuPercent > $1.cpuPercent }
    }

    /// Ask a process to quit; `force` sends SIGKILL. Returns false when the
    /// signal could not be delivered (e.g. not our process).
    @discardableResult
    static func terminate(_ info: ProcessInfo, force: Bool) -> Bool {
        if let app = NSRunningApplication(processIdentifier: info.id) {
            return force ? app.forceTerminate() : app.terminate()
        }
        return kill(info.id, force ? SIGKILL : SIGTERM) == 0
    }
}
