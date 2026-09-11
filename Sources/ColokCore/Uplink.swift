import Foundation

/// Describes the connection Colok is re-sharing. Purely informational, but it is
/// the first thing you want to see when a device says it has no internet.
public enum Uplink {
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
