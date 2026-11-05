import Foundation

/// Process-local, thread-safe shutdown state used by launchd signal sources
/// and the async service loop. It deliberately carries no product data.
public final class DistributedMeshShutdownLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    public init() {}

    public func request() {
        lock.lock()
        requested = true
        lock.unlock()
    }

    public func isRequested() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }
}
