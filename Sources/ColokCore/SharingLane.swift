import Foundation

/// A network service as macOS records it in the SystemConfiguration preferences.
public struct NetworkService: Identifiable, Hashable, Sendable {
    public let id: String        // SCNetworkService UUID
    public let name: String      // "Wi-Fi", "USB 10/100/1000 LAN", "Thunderbolt Bridge"
    public let device: String    // BSD name: en0, en5, bridge0
    public let hardware: String  // "AirPort", "Ethernet", "Bridge"

    public var isWiFi: Bool { hardware.caseInsensitiveCompare("AirPort") == .orderedSame }

    /// Bluetooth PAN is the one output that has no physical link to check: the
    /// interface only goes "active" once a phone has already joined it.
    public var isBluetoothPAN: Bool {
        hardware.localizedCaseInsensitiveContains("bluetooth")
            || name.localizedCaseInsensitiveContains("bluetooth")
    }
}

/// Drives macOS Internet Sharing, which is the only way to get devices online
/// without a cable to each one. Two useful shapes:
///
///   Ethernet in  -> Wi-Fi out      a real hotspot from the Mac's own radio
///   Wi-Fi in     -> Ethernet out   feeds a travel router that broadcasts
///
/// Wi-Fi in -> Wi-Fi out is refused by macOS and rejected here before we bother
/// writing anything.
public enum SharingLane {
    public static let helper = "/usr/local/libexec/colok-share"
    private static let preferences = "/Library/Preferences/SystemConfiguration/preferences.plist"

    public static var helperInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: helper)
    }

    // MARK: - Discovery

    /// Reads the SystemConfiguration service list. This is the only place the
    /// service UUIDs Internet Sharing needs are actually written down.
    public static func services() -> [NetworkService] {
        guard let data = FileManager.default.contents(atPath: preferences),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let all = root["NetworkServices"] as? [String: Any] else { return [] }

        var out: [NetworkService] = []
        for (uuid, raw) in all {
            guard let service = raw as? [String: Any] else { continue }
            let interface = service["Interface"] as? [String: Any] ?? [:]
            guard let device = interface["DeviceName"] as? String else { continue }
            let hardware = interface["Hardware"] as? String ?? ""
            let name = (service["UserDefinedName"] as? String)
                ?? (interface["UserDefinedName"] as? String)
                ?? device
            out.append(NetworkService(id: uuid, name: name, device: device, hardware: hardware))
        }
        return out.sorted { $0.name < $1.name }
    }

    /// The service currently carrying the default route - what we would share.
    public static func uplinkService() -> NetworkService? {
        guard let route = try? Shell.run("/sbin/route", ["-n", "get", "default"], timeout: 6), route.ok else { return nil }
        var device = ""
        for line in route.stdout.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("interface:") {
                device = t.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        guard !device.isEmpty else { return nil }
        return services().first { $0.device == device }
    }

    /// Interfaces we could push traffic out of: anything with a live link that
    /// isn't the uplink itself.
    public static func outputCandidates() -> [NetworkService] {
        let uplink = uplinkService()
        return services().filter { candidate in
            guard candidate.id != uplink?.id else { return false }
            // A Wi-Fi output is only legal when the uplink is not Wi-Fi.
            if candidate.isWiFi { return !(uplink?.isWiFi ?? true) }
            // Bluetooth PAN has no link to test - offer it whenever it exists.
            if candidate.isBluetoothPAN { return true }
            return hasLink(candidate.device)
        }
    }

    /// `ifconfig <dev>` reports "status: active" only when something is plugged in.
    public static func hasLink(_ device: String) -> Bool {
        guard let r = try? Shell.run("/sbin/ifconfig", [device], timeout: 6), r.ok else { return false }
        return r.stdout.contains("status: active")
    }

    // MARK: - State

    public static func isRunning() -> Bool {
        guard helperInstalled else { return false }
        guard let r = try? Privilege.run(helper, ["status"], timeout: 10) else { return false }
        return r.trimmedOut == "running"
    }

    public static func status() -> LaneStatus {
        guard helperInstalled else {
            return LaneStatus(available: false,
                              message: "Helper not installed - rerun Scripts/install-sudoers.sh")
        }
        let uplink = uplinkService()
        let candidates = outputCandidates()
        let running = isRunning()

        var message: String
        if let uplink {
            if candidates.isEmpty {
                message = uplink.isWiFi
                    ? "Uplink is \(uplink.name). Plug in an Ethernet adapter to share onward."
                    : "Uplink is \(uplink.name). No output interface with a live link."
            } else {
                message = "Share \(uplink.name) to \(candidates.map(\.name).joined(separator: ", "))."
            }
        } else {
            message = "No default route."
        }
        if running { message = "Sharing is on. " + message }

        let devices = candidates.map {
            TetheredDevice(id: $0.id, name: $0.name, platform: .ios,
                           online: running && ($0.isBluetoothPAN || hasLink($0.device)),
                           detail: $0.isBluetoothPAN ? "\($0.device) - Android only, iOS cannot join a PAN" : $0.device)
        }
        return LaneStatus(available: uplink != nil && !candidates.isEmpty,
                          enabled: running, message: message, devices: devices)
    }

    // MARK: - Actions

    /// - Parameter ssid: only when the output is the Wi-Fi radio. macOS has a
    ///   long-standing bug where the WPA password set this way is ignored and the
    ///   network comes up open, so the caller should warn about that.
    public static func enable(output: NetworkService, ssid: String? = nil) throws {
        guard helperInstalled else { throw ColokError.privilegeNotInstalled }
        guard let uplink = uplinkService() else {
            throw ColokError.contentCachingUnavailable("no default route to share")
        }
        guard !(uplink.isWiFi && output.isWiFi) else {
            throw ColokError.wifiToWifi
        }
        var args = ["enable", uplink.id, output.device]
        if output.isWiFi { args.append(ssid ?? "Colok") }
        let r = try Privilege.run(helper, args, timeout: 40)
        guard r.ok else { throw ShellError.failed("colok-share enable", r) }
    }

    public static func disable() throws {
        guard helperInstalled else { return }
        let r = try Privilege.run(helper, ["disable"], timeout: 30)
        guard r.ok else { throw ShellError.failed("colok-share disable", r) }
    }
}
