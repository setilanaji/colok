import Foundation
import ColokCore

func printStatus() {
    let s = Engine.shared.snapshot()
    print("uplink     \(s.uplink)")
    print("privilege  \(s.privileged ? "ok" : "NOT INSTALLED - sudo bash Scripts/install-sudoers.sh")")
    print("")
    print("iOS lane   \(s.ios.enabled ? "on " : "off") \(s.ios.message)")
    for d in s.ios.devices {
        print("           \(d.online ? "*" : " ") \(d.name)  [\(d.detail)]")
    }
    print("Android    \(s.android.enabled ? "on " : "off") \(s.android.message)")
    for d in s.android.devices {
        print("           \(d.online ? "*" : " ") \(d.name)  \(d.id)  [\(d.detail)]")
    }
    print("Sharing    \(s.sharing.enabled ? "on " : "off") \(s.sharing.message)")
    for d in s.sharing.devices {
        print("           \(d.online ? "*" : " ") \(d.name)  [\(d.detail)]")
    }
}

func doctor() {
    print("adb            \(AndroidLane.shared.adbPath ?? "MISSING")")
    print("gnirehtet      \(AndroidLane.shared.gnirehtetPath ?? "MISSING")")
    print("gnirehtet.apk  \(AndroidLane.shared.apkPresent ? "present" : "MISSING")")
    print("caching tools  \(IOSLane.toolsPresent ? "present" : "MISSING")")
    print("caching active \(IOSLane.cachingActive())")
    let probe = IOSLane.canActivate()
    print("canActivate    \(probe.ok) \(probe.reason)")
    print("sudoers        \(Privilege.isInstalled ? (Privilege.isUsable ? "installed and usable" : "installed but prompting") : "missing")")
    print("relay log      \(AndroidLane.shared.relayLogURL.path)")
}

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "status"

do {
    switch command {
    case "status": printStatus()
    case "doctor": doctor()
    case "diag": Diagnostics.run().lines.forEach { print($0) }
    case "iosproxy":
        if args.count > 1 && args[1] == "off" {
            IOSProxy.stop()
            print("ios proxy stopped")
        } else {
            let endpoint = try IOSProxy.start()
            print("""
            iOS proxy listening on \(endpoint)

            NOTE: a tethered-caching link is NOT user-configurable on iOS - there
            is no Configure Proxy for it, so this will not help a USB-tethered
            iPhone. It works only where iOS exposes the interface:

              - an iPad or iPhone with a USB-C/Lightning Ethernet adapter
                (Settings > Ethernet > the interface > Configure Proxy > Manual)
              - any Wi-Fi network the device can actually join
                (Settings > Wi-Fi > (i) > Configure Proxy > Manual)

            Server \(endpoint.split(separator: ":")[0]), port \(endpoint.split(separator: ":")[1]).
            """)
        }
    case "on":
        let problems = Engine.shared.connectEverything()
        problems.forEach { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        printStatus()
    case "off":
        Engine.shared.disconnectEverything()
        printStatus()
    case "ios":
        let on = args.count > 1 && ["on", "enable", "true"].contains(args[1])
        try Engine.shared.setIOS(enabled: on)
        printStatus()
    case "android":
        guard args.count > 2 else {
            print("usage: colok android <serial> on|off")
            exit(2)
        }
        let on = ["on", "start", "true", "proxy", "tunnel"].contains(args[2])
        let mode: AndroidMode = args[2] == "tunnel" ? .tunnel : .proxy
        try Engine.shared.setAndroid(serial: args[1], enabled: on, mode: mode)
        printStatus()
    case "share":
        let verb = args.count > 1 ? args[1] : "list"
        switch verb {
        case "list":
            if let up = SharingLane.uplinkService() {
                print("uplink   \(up.name) (\(up.device))  \(up.id)")
            } else {
                print("uplink   none")
            }
            for c in SharingLane.outputCandidates() {
                print("output   \(c.name) (\(c.device))  \(c.hardware)")
            }
        case "on":
            let target = SharingLane.outputCandidates().first { $0.device == (args.count > 2 ? args[2] : "") }
                ?? SharingLane.outputCandidates().first
            guard let target else { print("no output interface available"); exit(1) }
            try Engine.shared.setSharing(enabled: true, output: target,
                                         ssid: args.count > 3 ? args[3] : nil)
            printStatus()
        case "off":
            try Engine.shared.setSharing(enabled: false)
            printStatus()
        default:
            print("usage: colok share list | on [device] [ssid] | off")
            exit(2)
        }
    case "sudoers":
        print(Privilege.sudoersContents)
    default:
        print("""
        colok - share this Mac's connection with USB-attached phones

          colok status                 what is plugged in and online
          colok doctor                 check tooling and permissions
          colok diag                   uplink, bridge, latency numbers
          colok iosproxy [off]         split-TCP proxy for a tethered iPhone
          colok on                     bring every attached device online
          colok off                    tear everything down
          colok ios on|off             toggle the iOS/iPadOS lane
          colok android <serial> proxy|tunnel|off
          colok share list            uplink and usable output interfaces
          colok share on [dev] [ssid] start Internet Sharing
          colok share off
          colok sudoers                print the sudoers rule Colok needs
        """)
    }
} catch {
    FileHandle.standardError.write(Data(("error: " + error.localizedDescription + "\n").utf8))
    exit(1)
}
