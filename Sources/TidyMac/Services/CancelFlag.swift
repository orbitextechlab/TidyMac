import Foundation

/// Thread-safe cancellation token shared between the UI (main thread) and
/// scan/delete work running on background tasks. SwiftUI @State is not safe to
/// read off the main actor, so views hand one of these to services instead.
final class CancelFlag {
    private let lock = NSLock()
    private var value = false

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }

    func isCancelled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
