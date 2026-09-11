import Foundation

public enum Platform: String, Codable, Sendable {
    case ios, android
}

public struct TetheredDevice: Identifiable, Hashable, Sendable {
    public let id: String          // UDID or adb serial
    public let name: String
    public let platform: Platform
    public var online: Bool        // relayed traffic is flowing / bridge is up
    public var detail: String

    public init(id: String, name: String, platform: Platform, online: Bool, detail: String = "") {
        self.id = id
        self.name = name
        self.platform = platform
        self.online = online
        self.detail = detail
    }
}

public struct LaneStatus: Sendable {
    public var available: Bool
    public var enabled: Bool
    public var message: String
    public var devices: [TetheredDevice]

    public init(available: Bool = false, enabled: Bool = false, message: String = "", devices: [TetheredDevice] = []) {
        self.available = available
        self.enabled = enabled
        self.message = message
        self.devices = devices
    }
}

public struct ColokStatus: Sendable {
    public var uplink: String
    public var privileged: Bool
    public var ios: LaneStatus
    public var android: LaneStatus
    public var sharing: LaneStatus

    public init(uplink: String = "unknown", privileged: Bool = false,
                ios: LaneStatus = .init(), android: LaneStatus = .init(),
                sharing: LaneStatus = .init()) {
        self.uplink = uplink
        self.privileged = privileged
        self.ios = ios
        self.android = android
        self.sharing = sharing
    }

    public var deviceCount: Int { ios.devices.count + android.devices.count }
    public var onlineCount: Int { (ios.devices + android.devices).filter(\.online).count }
}

/// Tolerant JSON digging, because the exact key casing in Apple's -j output
/// has drifted between macOS releases.
enum JSONDig {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// These tools print a human-readable preamble before the JSON, so take the
    /// last line that parses as an object, then unwrap the
    /// {"name": ..., "result": ...} envelope they all use.
    static func payload(_ text: String) -> [String: Any]? {
        var parsed: [String: Any]?
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{") else { continue }
            if let obj = object(Data(trimmed.utf8)) { parsed = obj }
        }
        guard let parsed else { return nil }
        if let inner = parsed["result"] as? [String: Any] { return inner }
        return parsed
    }

    /// `result` is sometimes a bare Bool rather than a dictionary.
    static func resultBool(_ text: String) -> Bool? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), let obj = object(Data(trimmed.utf8)) else { continue }
            if let b = obj["result"] as? Bool { return b }
            if let n = obj["result"] as? NSNumber { return n.boolValue }
        }
        return nil
    }

    static func value(_ dict: [String: Any], _ candidates: [String]) -> Any? {
        for key in candidates {
            for (k, v) in dict where k.compare(key, options: .caseInsensitive) == .orderedSame {
                return v
            }
        }
        // one level down, e.g. {"result": {...}}
        for (_, v) in dict {
            if let nested = v as? [String: Any], let found = value(nested, candidates) { return found }
        }
        return nil
    }

    static func string(_ dict: [String: Any], _ candidates: [String]) -> String? {
        guard let v = value(dict, candidates) else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    static func bool(_ dict: [String: Any], _ candidates: [String]) -> Bool? {
        guard let v = value(dict, candidates) else { return nil }
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String { return ["true", "yes", "1"].contains(s.lowercased()) }
        return nil
    }

    static func int64(_ dict: [String: Any], _ candidates: [String]) -> Int64? {
        guard let v = value(dict, candidates) else { return nil }
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String {
            // Text form is like "5.11 GB"; JSON form is a plain byte count.
            let parts = s.split(separator: " ")
            guard let magnitude = Double(parts.first ?? "") else { return nil }
            let unit = parts.count > 1 ? parts[1].uppercased() : "B"
            let scale: Double = ["B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12][unit] ?? 1
            let bytes = magnitude * scale
            // Int64(Double) traps on NaN, infinity, or anything past Int64.max.
            guard bytes.isFinite, bytes >= 0, bytes < 9.2e18 else { return nil }
            return Int64(bytes)
        }
        return nil
    }

    static func array(_ dict: [String: Any], _ candidates: [String]) -> [[String: Any]]? {
        value(dict, candidates) as? [[String: Any]]
    }
}
