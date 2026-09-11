import Foundation

/// Tethered caching bridges the iPhone transparently, so the phone's own TCP
/// stack sees the full jittery Wi-Fi path and its congestion window collapses.
/// Pointing the phone at this proxy terminates TCP on the Mac instead - the same
/// split-TCP advantage gnirehtet gives Android, which is why Android feels fast
/// on a link where the bridged iPhone crawls.
public enum IOSProxy {
    private static var instance: HTTPProxy?
    private static let lock = NSLock()

    public static var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return instance?.isRunning ?? false
    }

    /// Address to type into the iPhone: Settings > Wi-Fi/Ethernet > Configure Proxy > Manual.
    public static var endpoint: String? {
        lock.lock(); defer { lock.unlock() }
        guard let proxy = instance, proxy.isRunning else { return nil }
        return "\(proxy.bindAddress):\(proxy.port)"
    }

    @discardableResult
    public static func start(port: UInt16 = 8899) throws -> String {
        guard let bridge = HTTPProxy.bridgeAddress() else {
            throw ColokError.noDevice("bridge100 has no address - is a device bridged?")
        }
        lock.lock()
        let existing = instance
        lock.unlock()
        if let existing, existing.isRunning, existing.bindAddress == bridge {
            return "\(existing.bindAddress):\(existing.port)"
        }
        existing?.stop()

        let proxy = HTTPProxy(port: port, bindAddress: bridge)
        try proxy.start()
        lock.lock(); instance = proxy; lock.unlock()
        return "\(bridge):\(port)"
    }

    public static func stop() {
        lock.lock()
        instance?.stop()
        instance = nil
        lock.unlock()
    }
}
