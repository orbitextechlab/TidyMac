import Foundation

/// Detects other fan-control software running on this Mac.
///
/// Two fan controllers cannot coexist: the rival's daemon re-asserts its own
/// fan targets continuously, so every write TidyMac makes is overwritten
/// within milliseconds. From the outside that looks like the SMC silently
/// discarding commands — the helper's write-verify fails and the fan falls
/// back to automatic, with no hint of *why*. Naming the actual culprit turns
/// an unexplainable failure into a one-line fix for the user.
///
/// Detection is a walk of the process table via libproc, matching executable
/// paths against known fan tools. Reading process paths needs no privileges,
/// and a full scan is microseconds — but this is still only called when the
/// Fans screen appears, not on every engine tick.
enum FanRivalDetector {

    /// Known fan-control daemons/apps, matched case-insensitively against the
    /// full executable path. Helper daemons matter more than the apps: they
    /// keep running (and keep fighting) even after the app itself is quit.
    private static let rivals: [(needle: String, name: String)] = [
        ("macsfancontrol", "Macs Fan Control"),
        ("tunabellysoftware.tgfanhelper", "TG Pro"),
        ("smcfancontrol", "smcFanControl"),
        ("istatmenus", "iStat Menus"),
        ("exelban.stats", "Stats"),
    ]

    /// Display name of the first rival fan controller found running, or nil.
    static func runningRival() -> String? {
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }

        // Headroom for processes spawned between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return nil }

        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is a C macro Swift cannot see.
        var buffer = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(cString: buffer).lowercased()
            if let hit = rivals.first(where: { path.contains($0.needle) }) {
                return hit.name
            }
        }
        return nil
    }
}
