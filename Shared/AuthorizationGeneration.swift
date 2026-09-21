import Foundation

/// Serializes revocation against input already queued off the main thread.
final class AuthorizationGeneration {
    static let shared = AuthorizationGeneration()
    private let lock = NSRecursiveLock()
    private var generation = UUID()

    var token: UUID {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        generation = UUID()
    }

    @discardableResult
    func perform(ifCurrent token: UUID, _ work: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard token == generation else { return false }
        work()
        return true
    }

    /// Queue the hop BEFORE acquiring the gate. Holding this lock while
    /// synchronously waiting for main can deadlock a main-thread revocation
    /// or packet callback. Revalidate on main so queued work cannot survive
    /// revocation while it waits.
    func onMain<Result>(ifCurrent token: UUID, _ work: () -> Result) -> Result? {
        MainQueueExecutor.sync {
            lock.lock(); defer { lock.unlock() }
            guard token == generation else { return nil }
            return work()
        }
    }
}
