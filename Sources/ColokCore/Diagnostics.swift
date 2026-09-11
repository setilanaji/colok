import Foundation

/// Collects the numbers that distinguish "slow because throughput" from "slow
/// because latency" - they have completely different causes and fixes.
public enum Diagnostics {
    public struct Report: Sendable {
        public var lines: [String] = []
        mutating func add(_ label: String, _ value: String) {
            lines.append("\(label.padding(toLength: 22, withPad: " ", startingAt: 0))\(value)")
        }
    }

    public static func run() -> Report {
        var report = Report()

        // --- Uplink the Mac itself has
        report.add("uplink", Uplink.describe())
        if let device = Uplink.defaultRouteDevice(), Uplink.isTunnel(device) {
            report.add("WARNING", "\(device) holds the default route - tethered devices will have no connectivity")
        }
        if let iface = IOSLane.primaryInterface() {
            report.add("tetherator uplink", "\(iface.name), \(iface.mbps) Mbps, wired=\(iface.wired)")
        } else {
            report.add("tetherator uplink", "none - not active")
        }

        // --- Wi-Fi radio quality. A marginal link caps everything downstream,
        //     and the phone is contending for the same airtime.
        if let r = try? Shell.run("/usr/sbin/system_profiler", ["SPAirPortDataType"], timeout: 25), r.ok {
            for key in ["Transmit Rate", "Signal / Noise", "PHY Mode", "Channel"] {
                if let line = r.stdout.split(separator: "\n").first(where: { $0.contains(key + ":") }) {
                    report.add(key.lowercased(), line.trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: key + ": ", with: ""))
                }
            }
        }

        // --- The bridge tethered devices sit on. A wrong MTU here shows up as
        //     "big transfers stall, small ones are fine".
        if let r = try? Shell.run("/sbin/ifconfig", ["bridge100"], timeout: 8), r.ok {
            let mtu = r.stdout.split(separator: "\n").first?
                .split(separator: " ")
                .drop(while: { $0 != "mtu" }).dropFirst().first.map(String.init) ?? "?"
            report.add("bridge100 mtu", mtu)
            let members = r.stdout.split(separator: "\n")
                .filter { $0.contains("member:") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
            report.add("bridge100 members", members.isEmpty ? "none" : members.joined(separator: ", "))
        } else {
            report.add("bridge100", "absent - nothing bridged")
        }

        // --- Latency vs throughput. Slow DNS feels exactly like a slow link.
        report.add("dns lookup", time { _ = try? Shell.run("/usr/bin/dscacheutil",
                                                           ["-q", "host", "-a", "name", "apple.com"], timeout: 10) })
        if let r = try? Shell.run("/sbin/ping", ["-c", "5", "-q", "1.1.1.1"], timeout: 15), r.ok,
           let summary = r.stdout.split(separator: "\n").last(where: { $0.contains("min/avg/max") }) {
            report.add("rtt", summary.split(separator: "=").last.map {
                $0.trimmingCharacters(in: .whitespaces) } ?? "?")
        } else {
            report.add("rtt", "unreachable")
        }

        return report
    }

    private static func time(_ work: () -> Void) -> String {
        let start = Date()
        work()
        return String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000)
    }
}
