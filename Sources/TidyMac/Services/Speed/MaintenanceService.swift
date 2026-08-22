import Foundation

/// One-shot maintenance actions, CleanMyMac "Maintenance" style. Each task
/// reports a human-readable outcome; privileged ones go through the standard
/// admin prompt.
enum MaintenanceService {

    struct Task: Identifiable {
        let id: String
        let title: String
        let description: String
        let systemImage: String
        let needsAdmin: Bool
        let run: () throws -> String
    }

    static let all: [Task] = [
        Task(id: "free-ram",
             title: "Free Up RAM",
             description: "Purge inactive memory when apps feel sluggish",
             systemImage: "memorychip",
             needsAdmin: true) {
            _ = try AdminRunner.runElevated("/usr/sbin/purge", reason: "Free up RAM")
            return "Inactive memory purged"
        },

        Task(id: "flush-dns",
             title: "Flush DNS Cache",
             description: "Reset DNS records after network changes",
             systemImage: "network",
             needsAdmin: true) {
            _ = try AdminRunner.runElevated(
                "/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder",
                reason: "Flush DNS cache")
            return "DNS cache flushed"
        },

        Task(id: "reindex-spotlight",
             title: "Reindex Spotlight",
             description: "Rebuild search index when Spotlight misbehaves",
             systemImage: "magnifyingglass",
             needsAdmin: true) {
            _ = try AdminRunner.runElevated("/usr/bin/mdutil -E /", reason: "Reindex Spotlight")
            return "Reindex started — Spotlight rebuilds in the background"
        },

        Task(id: "thin-snapshots",
             title: "Thin Time Machine Snapshots",
             description: "Reclaim disk space held by local snapshots",
             systemImage: "clock.arrow.circlepath",
             needsAdmin: true) {
            let out = try AdminRunner.runElevated(
                "/usr/bin/tmutil thinlocalsnapshots / 999999999999 4",
                reason: "Thin local snapshots")
            let thinned = out.split(separator: "\n").filter { $0.contains("Thinned") }.count
            return thinned > 0 ? "Local snapshots thinned" : "No snapshots needed thinning"
        },

        Task(id: "empty-trash",
             title: "Empty Trash",
             description: "Permanently delete everything in your Trash",
             systemImage: "trash",
             needsAdmin: false) {
            let fm = FileManager.default
            let trash = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
            let children = (try? fm.contentsOfDirectory(
                at: trash, includingPropertiesForKeys: nil)) ?? []
            var removed = 0
            for child in children where (try? fm.removeItem(at: child)) != nil { removed += 1 }
            return removed > 0 ? "Removed \(removed) items from the Trash" : "Trash is already empty"
        },
    ]
}
