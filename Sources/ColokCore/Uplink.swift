import Foundation

/// Describes the connection Colok is re-sharing. Purely informational, but it is
/// the first thing you want to see when a device says it has no internet.
public enum Uplink {
    /// BSD name of the interface holding the default route.
    public static func defaultRouteDevice() -> String? {
        guard let route = try? Shell.run("/sbin/route", ["-n", "get", "default"], timeout: 6), route.ok else {
            return nil
        }
        for line in route.stdout.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("interface:") {
                let device = t.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
                return device.isEmpty ? nil : device
            }
        }
        return nil
    }

    /// A VPN or other tunnel. This matters more than it looks: Internet Sharing
    /// and tethered caching both NAT onto a *physical* interface, so when a
    /// tunnel owns the default route their traffic is translated onto an
    /// interface that no longer carries it, and every tethered device goes dark
    /// while the Mac itself stays online.
    ///
    /// A Tailscale exit node is the usual cause - plain Tailscale only routes
    /// 100.64.0.0/10 and is harmless here; it is the exit node that installs a
    /// default route. Note the asymmetry: the Android lane is unaffected, because
    /// its relay opens ordinary sockets that follow the routing table like any
    /// other app, tunnel included.
    public static func isTunnel(_ device: String) -> Bool {
        ["utun", "ipsec", "ppp", "tun", "tap"].contains { device.hasPrefix($0) }
    }

    public static var tunnelHoldsDefaultRoute: Bool {
        guard let device = defaultRouteDevice() else { return false }
        return isTunnel(device)
    }

    public static func describe() -> String {
        guard let route = try? Shell.run("/sbin/route", ["-n", "get", "default"], timeout: 6), route.ok else {
            return "no default route"
        }
        var iface = ""
        for line in route.stdout.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("interface:") {
                iface = t.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        guard !iface.isEmpty else { return "no default route" }
        if isTunnel(iface) { return "\(iface) - VPN or tunnel holds the default route" }

        var label = iface
        if let services = try? Shell.run("/usr/sbin/networksetup", ["-listnetworkserviceorder"], timeout: 8), services.ok {
            // Lines look like: (Hardware Port: Wi-Fi, Device: en0)
            for line in services.stdout.split(separator: "\n") where line.contains("Device: \(iface))") {
                if let range = line.range(of: "Hardware Port: "), let comma = line.range(of: ", Device:") {
                    label = String(line[range.upperBound..<comma.lowerBound])
                }
            }
        }
        if label.lowercased().contains("wi-fi"),
           let ssid = currentSSID() {
            return "\(label) - \(ssid) (\(iface))"
        }
        return "\(label) (\(iface))"
    }

    public static func currentSSID() -> String? {
        // `airport -I` was removed in recent macOS; networksetup still reports it.
        for device in ["en0", "en1"] {
            if let r = try? Shell.run("/usr/sbin/networksetup", ["-getairportnetwork", device], timeout: 6), r.ok {
                let text = r.trimmedOut
                if let range = text.range(of: "Current Wi-Fi Network: ") {
                    return String(text[range.upperBound...])
                }
            }
        }
        return nil
    }
}
