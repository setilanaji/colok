import Foundation

/// Caches an expensive value for a moment. Status polling asks the same
/// command-line tool several times per refresh; without this each question
/// spawns its own process, and the file descriptors add up fast.
///
/// `produce` runs under the lock deliberately: concurrent callers wait for one
/// result rather than each launching a duplicate process.
final class Memo<T>: @unchecked Sendable {
    private let ttl: TimeInterval
    private var cached: T?
    private var stamp = Date.distantPast
    private let lock = NSLock()

    init(ttl: TimeInterval) { self.ttl = ttl }

    func get(_ produce: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        if let cached, Date().timeIntervalSince(stamp) < ttl { return cached }
        let fresh = produce()
        cached = fresh
        stamp = Date()
        return fresh
    }

    func invalidate() {
        lock.lock()
        cached = nil
        stamp = .distantPast
        lock.unlock()
    }
}
