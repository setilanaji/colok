import Foundation

/// Android has no tetherator equivalent, so Colok drives gnirehtet: a VpnService
/// on the phone pipes all IPv4 TCP/UDP over an `adb reverse` channel into a relay
/// running here. No root on either side; the phone sees a real VPN network, so
/// apps behave normally instead of refusing to fire on an "offline" device.
/// How a given Android device is being served.
public enum AndroidMode: String, Sendable {
    /// gnirehtet: full IPv4 tunnel, but a VpnService takes the whole phone over.
    case tunnel
    /// adb reverse + a loopback proxy: only proxy-aware traffic, but the phone
    /// keeps its own mobile data and Wi-Fi, and one setting undoes it.
    case proxy
}

public final class AndroidLane {
    public static let shared = AndroidLane()
    private init() {}

    private var relay: Process?
    private var started = Set<String>()
    private var proxied = Set<String>()
    private let lock = NSLock()
    private let proxy = HTTPProxy(port: 8899)

    public var proxyPort: UInt16 { proxy.port }

    public var supportDirectory: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".colok", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    public var relayLogURL: URL { supportDirectory.appendingPathComponent("relay.log") }

    // MARK: - Tool discovery

    public var adbPath: String? {
        if let override = UserDefaults.standard.string(forKey: "adbPath"),
           FileManager.default.isExecutableFile(atPath: override) { return override }
        let home = NSHomeDirectory()
        return Shell.locate("adb", extraDirectories: [
            "\(home)/Library/Android/sdk/platform-tools",
            "\(home)/Android/Sdk/platform-tools",
            "\(home)/Library/Android/platform-tools",
            "/opt/homebrew/share/android-commandlinetools/platform-tools",
            "/usr/local/share/android-sdk/platform-tools",
        ])
    }

    public var gnirehtetPath: String? {
        if let override = UserDefaults.standard.string(forKey: "gnirehtetPath"),
           FileManager.default.isExecutableFile(atPath: override) { return override }
        return Shell.locate("gnirehtet", extraDirectories: [supportDirectory.path])
    }

    /// gnirehtet resolves "gnirehtet.apk" against its *working directory*, which is
    /// `/` when the app is launched from Finder. We pin it two ways: GNIREHTET_APK
    /// with an absolute path, and a working directory next to the binary.
    public var apkURL: URL? {
        guard let g = gnirehtetPath else { return nil }
        let dir = (g as NSString).deletingLastPathComponent
        let candidate = URL(fileURLWithPath: dir).appendingPathComponent("gnirehtet.apk")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    public var apkPresent: Bool { apkURL != nil }

    /// Working directory for every gnirehtet invocation.
    private var workingDirectory: URL {
        guard let g = gnirehtetPath else { return supportDirectory }
        return URL(fileURLWithPath: (g as NSString).deletingLastPathComponent)
    }

    /// gnirehtet shells out to adb itself, so it needs both the APK path and an
    /// adb it can actually find - a Finder-launched app inherits a bare PATH.
    private var gnirehtetEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let apk = apkURL { env["GNIREHTET_APK"] = apk.path }
        if let adb = adbPath {
            env["ADB"] = adb
            let adbDir = (adb as NSString).deletingLastPathComponent
            let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            if !path.split(separator: ":").contains(Substring(adbDir)) {
                env["PATH"] = adbDir + ":" + path
            }
        }
        return env
    }

    // MARK: - Devices

    public func attachedDevices() -> [TetheredDevice] {
        guard let adb = adbPath, let r = try? Shell.run(adb, ["devices", "-l"], timeout: 12) else { return [] }
        var out: [TetheredDevice] = []
        for line in r.stdout.split(separator: "\n").dropFirst() {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let parts = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2 else { continue }
            let serial = parts[0]
            let state = parts[1]
            var name = serial
            if let modelField = parts.first(where: { $0.hasPrefix("model:") }) {
                name = String(modelField.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ")
            }
            var live = false
            let detail: String
            switch state {
            case "device":
                if isRunning(serial: serial) {
                    live = true
                    detail = "tunnel - phone's own network is taken over"
                } else if proxyActive(serial: serial) {
                    live = true
                    detail = "proxy - phone keeps its own network"
                } else {
                    detail = "connected"
                }
            case "unauthorized": detail = "unauthorized - accept the USB debugging prompt"
            case "offline": detail = "offline - reconnect the cable"
            default: detail = state
            }
            out.append(TetheredDevice(id: serial, name: name, platform: .android,
                                      online: live, detail: detail))
        }
        return out
    }

    public func isRunning(serial: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return started.contains(serial)
    }

    public var relayRunning: Bool { relay?.isRunning ?? false }

    // MARK: - Lifecycle

    public func startRelay() throws {
        guard let g = gnirehtetPath else { throw ColokError.gnirehtetNotFound }
        guard !relayRunning else { return }
        relay = try Shell.spawn(g, ["relay"],
                                logURL: relayLogURL,
                                environment: gnirehtetEnvironment,
                                currentDirectory: workingDirectory)
        // Give the relay a moment to bind before the first `start`.
        usleep(600_000)
    }

    public func stopRelay() {
        relay?.terminate()
        relay = nil
        lock.lock(); started.removeAll(); lock.unlock()
    }

    public func start(serial: String) throws {
        guard let g = gnirehtetPath else { throw ColokError.gnirehtetNotFound }
        guard adbPath != nil else { throw ColokError.adbNotFound }
        guard apkURL != nil else { throw ColokError.gnirehtetNotFound }
        try startRelay()
        let r = try Shell.run(g, ["start", serial], timeout: 60,
                              environment: gnirehtetEnvironment,
                              currentDirectory: workingDirectory)
        guard r.ok else { throw ShellError.failed("gnirehtet start", r) }
        lock.lock(); started.insert(serial); lock.unlock()
    }

    public func stop(serial: String) {
        guard let g = gnirehtetPath else { return }
        _ = try? Shell.run(g, ["stop", serial], timeout: 30,
                           environment: gnirehtetEnvironment,
                           currentDirectory: workingDirectory)
        lock.lock(); started.remove(serial); lock.unlock()
    }

    public func stopAll() {
        lock.lock()
        let snapshot = started
        lock.unlock()
        for serial in snapshot { stop(serial: serial) }
        lock.lock()
        let proxySnapshot = proxied
        lock.unlock()
        for serial in proxySnapshot { stopProxy(serial: serial) }
        proxy.stop()
        stopRelay()
    }

    // MARK: - Proxy mode

    /// Reads the phone's own setting rather than trusting our bookkeeping, so a
    /// proxy left over from a previous run is still reported accurately.
    public func proxyActive(serial: String) -> Bool {
        guard let adb = adbPath,
              let r = try? Shell.run(adb, ["-s", serial, "shell", "settings", "get", "global", "http_proxy"], timeout: 10)
        else { return false }
        return r.trimmedOut.contains("127.0.0.1:\(proxy.port)")
    }

    public func startProxy(serial: String) throws {
        guard let adb = adbPath else { throw ColokError.adbNotFound }
        if !proxy.isRunning { try proxy.start() }
        let port = String(proxy.port)

        let reverse = try Shell.run(adb, ["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"], timeout: 20)
        guard reverse.ok else { throw ShellError.failed("adb reverse", reverse) }

        let set = try Shell.run(adb, ["-s", serial, "shell", "settings", "put", "global",
                                      "http_proxy", "127.0.0.1:\(port)"], timeout: 20)
        guard set.ok else { throw ShellError.failed("adb settings put http_proxy", set) }

        lock.lock(); proxied.insert(serial); lock.unlock()
    }

    public func stopProxy(serial: String) {
        guard let adb = adbPath else { return }
        // ":0" is the documented way to clear it; delete is belt and braces.
        _ = try? Shell.run(adb, ["-s", serial, "shell", "settings", "put", "global", "http_proxy", ":0"], timeout: 20)
        _ = try? Shell.run(adb, ["-s", serial, "shell", "settings", "delete", "global", "http_proxy"], timeout: 20)
        _ = try? Shell.run(adb, ["-s", serial, "reverse", "--remove", "tcp:\(proxy.port)"], timeout: 20)
        lock.lock(); proxied.remove(serial); lock.unlock()
    }

    public func start(serial: String, mode: AndroidMode) throws {
        switch mode {
        case .tunnel: try start(serial: serial)
        case .proxy:  try startProxy(serial: serial)
        }
    }

    public func stop(serial: String, mode: AndroidMode) {
        switch mode {
        case .tunnel: stop(serial: serial)
        case .proxy:  stopProxy(serial: serial)
        }
    }

    public func status() -> LaneStatus {
        guard adbPath != nil else {
            return LaneStatus(available: false, message: "adb not found - install platform-tools.")
        }
        guard gnirehtetPath != nil else {
            return LaneStatus(available: false, message: "gnirehtet missing - run Scripts/fetch-gnirehtet.sh")
        }
        guard apkPresent else {
            return LaneStatus(available: false, message: "gnirehtet.apk missing next to the relay binary.")
        }
        let devs = attachedDevices()
        let msg: String
        if devs.isEmpty {
            msg = "Ready - plug in a phone with USB debugging on."
        } else {
            msg = "\(devs.filter(\.online).count) of \(devs.count) relaying."
        }
        return LaneStatus(available: true, enabled: relayRunning, message: msg, devices: devs)
    }
}
