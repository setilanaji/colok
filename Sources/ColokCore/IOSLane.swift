import Foundation

/// iOS / iPadOS devices get internet over USB through macOS "tethered caching",
/// the same mechanism device carts and Apple Configurator rely on.
///
/// Three things must all be true, and they fail independently:
///   1. Content Caching is *activated* (registers with Apple; can be refused)
///   2. the tetherator is *enabled*   (AssetCacheTetheratorUtil isEnabled)
///   3. the tetherator is *active*    (it has a primary interface to bridge onto)
public enum IOSLane {
    static let manager = "/usr/bin/AssetCacheManagerUtil"
    static let tetherator = "/usr/bin/AssetCacheTetheratorUtil"

    public static var toolsPresent: Bool {
        FileManager.default.isExecutableFile(atPath: manager)
            && FileManager.default.isExecutableFile(atPath: tetherator)
    }

    // MARK: - Content Caching

    private static let managerMemo = Memo<[String: Any]?>(ttl: 2.0)
    private static let tetherMemo = Memo<[String: Any]?>(ttl: 2.0)

    static func managerStatus() -> [String: Any]? {
        managerMemo.get {
            guard let r = try? Shell.run(manager, ["-j", "status"], timeout: 12) else { return nil }
            return JSONDig.payload(r.stdout + "\n" + r.stderr)
        }
    }

    /// Call after any state change so the next read is not stale.
    static func invalidate() {
        managerMemo.invalidate()
        tetherMemo.invalidate()
    }

    /// Reads `Activated` out of the status payload. The older approach of
    /// interpreting `isActivated`'s exit code lied: it reports success even when
    /// caching is off, which silently skipped activation entirely.
    public static func cachingActive() -> Bool {
        guard let status = managerStatus() else { return false }
        return JSONDig.bool(status, ["Activated"]) ?? false
    }

    /// Why activation is failing, when it is. RegistrationResponseCode 403 means
    /// Apple refused the registration - usually the network, not the Mac.
    public static func registrationProblem() -> String? {
        guard let status = managerStatus() else { return nil }
        let error = JSONDig.string(status, ["RegistrationError"]) ?? ""
        let code = JSONDig.string(status, ["RegistrationResponseCode"]) ?? ""
        guard !error.isEmpty, error != "NONE", error != "NOT_ACTIVATED" else { return nil }
        return code.isEmpty ? error : "\(error) (HTTP \(code))"
    }

    /// Space available to the cache. This bounds how much *Apple* content can be
    /// stored and re-served; it has no bearing on the throughput of general
    /// traffic bridged to a tethered device.
    public static func cacheFreeBytes() -> Int64? {
        guard let status = managerStatus() else { return nil }
        return JSONDig.int64(status, ["CacheFree"])
    }

    public static func canActivate() -> (ok: Bool, reason: String) {
        guard let r = try? Shell.run(manager, ["canActivate"], timeout: 10) else {
            return (false, "AssetCacheManagerUtil unavailable")
        }
        return (r.ok, (r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Tetherator

    static func tetheratorStatus() -> [String: Any]? {
        tetherMemo.get {
            guard let r = try? Shell.run(tetherator, ["-j", "status"], timeout: 12) else { return nil }
            return JSONDig.payload(r.stdout + "\n" + r.stderr)
        }
    }

    public static func tetheringEnabled() -> Bool {
        guard let r = try? Shell.run(tetherator, ["-j", "isEnabled"], timeout: 10) else { return false }
        return JSONDig.resultBool(r.stdout + "\n" + r.stderr) ?? false
    }

    /// Enabled but not Active means it has nothing to bridge onto yet.
    public static func tetheringActive() -> Bool {
        guard let status = tetheratorStatus() else { return false }
        return JSONDig.bool(status, ["Active"]) ?? false
    }

    /// What the tetherator picked as the uplink it will NAT onto.
    public static func primaryInterface() -> (name: String, wired: Bool, mbps: Int)? {
        guard let status = tetheratorStatus(),
              let iface = JSONDig.value(status, ["Primary Interface", "PrimaryInterface"]) as? [String: Any]
        else { return nil }
        let name = JSONDig.string(iface, ["User Readable", "BSD Name"]) ?? "Unknown"
        guard name != "Unknown" else { return nil }
        let wired = JSONDig.bool(iface, ["Wired"]) ?? false
        let mbps = Int(JSONDig.string(iface, ["Mbps"]) ?? "0") ?? 0
        return (name, wired, mbps)
    }

    /// The device list key is "Device Roster", not "Devices".
    public static func devices() -> [TetheredDevice] {
        guard let status = tetheratorStatus(),
              let rows = JSONDig.array(status, ["Device Roster", "DeviceRoster", "Devices"])
        else { return [] }
        return rows.map { row in
            let udid = JSONDig.string(row, ["UDID", "Serial Number", "SerialNumber", "serial"]) ?? UUID().uuidString
            let name = JSONDig.string(row, ["Name", "DeviceName", "Product Name"]) ?? "iOS device"
            let bridged = JSONDig.bool(row, ["Bridged", "Checked In", "CheckedIn", "Connected"]) ?? false
            let paired = JSONDig.bool(row, ["Paired"]) ?? true
            var detail = bridged ? "bridged" : "attached, not bridged"
            if !paired { detail += " - unlock the device and tap Trust" }
            return TetheredDevice(id: udid, name: name, platform: .ios, online: bridged, detail: detail)
        }
    }

    // MARK: - Aggregate

    public static func status() -> LaneStatus {
        guard toolsPresent else {
            return LaneStatus(available: false, message: "Content Caching tools missing on this macOS build.")
        }
        guard cachingActive() else {
            if let problem = registrationProblem() {
                return LaneStatus(available: false, message: "Content Caching won't activate: \(problem)")
            }
            let probe = canActivate()
            return LaneStatus(available: probe.ok, enabled: false,
                              message: probe.ok ? "Content Caching is off." : probe.reason)
        }

        let enabled = tetheringEnabled()
        let active = tetheringActive()
        let devs = devices()

        var message: String
        if !enabled {
            message = "Content Caching on, USB sharing off."
        } else if !active {
            message = "Enabled but not active - no uplink to bridge onto yet."
            if let iface = primaryInterface(), !iface.wired {
                message = "Enabled but not active. Uplink \(iface.name) is wireless; tethered caching may require a wired uplink."
            }
        } else if devs.isEmpty {
            let via = primaryInterface().map { " via \($0.name)" } ?? ""
            message = "Active\(via) - plug in an iPhone or iPad."
        } else {
            message = "\(devs.filter(\.online).count) of \(devs.count) bridged."
            if let iface = primaryInterface(), iface.mbps > 0 {
                message += " Uplink \(iface.name) at \(iface.mbps) Mbps."
            }
        }
        // The cache only accelerates Apple-delivered content (App Store, OS
        // updates). General traffic is NAT'd and never touches it, so low space
        // is worth flagging but is NOT a cause of slow browsing.
        if let free = cacheFreeBytes(), free < 10_000_000_000 {
            let gb = String(format: "%.1f", Double(free) / 1e9)
            message += " \(gb) GB free - too small to cache an OS update, but general traffic is unaffected."
        }
        return LaneStatus(available: true, enabled: enabled, message: message, devices: devs)
    }

    // MARK: - Actions

    public static func enable() throws {
        guard toolsPresent else { throw ColokError.contentCachingUnavailable("tools missing") }

        if !cachingActive() {
            let r = try Privilege.run(manager, ["activate"], timeout: 60)
            guard r.ok else { throw ShellError.failed("AssetCacheManagerUtil activate", r) }
            // Registration is asynchronous; give it a moment before judging.
            for _ in 0..<10 {
                invalidate()
                if cachingActive() { break }
                usleep(700_000)
            }
            invalidate()
            if !cachingActive() {
                throw ColokError.contentCachingUnavailable(registrationProblem() ?? "activation did not take effect")
            }
        }

        invalidate()
        let r = try Privilege.run(tetherator, ["-j", "enable"], timeout: 30)
        invalidate()
        guard r.ok else { throw ShellError.failed("AssetCacheTetheratorUtil enable", r) }
    }

    public static func disable(alsoDeactivateCaching: Bool = false) throws {
        let r = try Privilege.run(tetherator, ["-j", "disable"], timeout: 30)
        invalidate()
        guard r.ok else { throw ShellError.failed("AssetCacheTetheratorUtil disable", r) }
        if alsoDeactivateCaching {
            _ = try? Privilege.run(manager, ["deactivate"], timeout: 45)
        }
    }
}
