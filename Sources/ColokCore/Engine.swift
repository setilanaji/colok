import Foundation

/// Single place the UI and the CLI both read from.
public final class Engine {
    public static let shared = Engine()
    private init() {}

    public func snapshot() -> ColokStatus {
        ColokStatus(uplink: Uplink.describe(),
                    privileged: Privilege.isUsable,
                    ios: IOSLane.status(),
                    android: AndroidLane.shared.status(),
                    sharing: SharingLane.status())
    }

    // MARK: - Actions

    public func setIOS(enabled: Bool) throws {
        enabled ? try IOSLane.enable() : try IOSLane.disable()
    }

    public func setSharing(enabled: Bool, output: NetworkService? = nil, ssid: String? = nil) throws {
        if enabled {
            guard let target = output ?? SharingLane.outputCandidates().first else {
                throw ColokError.noDevice("no output interface available")
            }
            try SharingLane.enable(output: target, ssid: ssid)
        } else {
            try SharingLane.disable()
        }
    }

    public func setAndroid(serial: String, enabled: Bool, mode: AndroidMode = .proxy) throws {
        if enabled {
            try AndroidLane.shared.start(serial: serial, mode: mode)
        } else {
            // Tear down whichever mode is actually live.
            AndroidLane.shared.stop(serial: serial)
            AndroidLane.shared.stopProxy(serial: serial)
        }
    }

    /// Best effort: get everything currently plugged in online.
    public func connectEverything() -> [String] {
        var problems: [String] = []
        do { try IOSLane.enable() } catch { problems.append("iOS: \(error.localizedDescription)") }
        let lane = AndroidLane.shared
        for device in lane.attachedDevices() where !device.online {
            guard !device.detail.hasPrefix("unauthorized") else {
                problems.append("\(device.name): \(device.detail)")
                continue
            }
            do { try lane.start(serial: device.id, mode: .proxy) }
            catch { problems.append("\(device.name): \(error.localizedDescription)") }
        }
        return problems
    }

    public func disconnectEverything() {
        try? IOSLane.disable()
        AndroidLane.shared.stopAll()
        try? SharingLane.disable()
    }
}
