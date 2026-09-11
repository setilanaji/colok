import Foundation

/// Colok needs root for exactly two things: `AssetCacheManagerUtil activate/deactivate`
/// and `AssetCacheTetheratorUtil enable/disable`. Rather than ship a signed
/// SMAppService daemon, we install a narrow sudoers drop-in that whitelists those
/// exact argument vectors and nothing else.
public enum Privilege {
    public static let sudoersPath = "/etc/sudoers.d/colok"
    private static let sudo = "/usr/bin/sudo"

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: sudoersPath)
    }

    /// True when we can actually run a privileged Colok command without a password prompt.
    public static var isUsable: Bool {
        guard isInstalled else { return false }
        guard let r = try? Shell.run(sudo, ["-n", "/usr/bin/AssetCacheTetheratorUtil", "-j", "isEnabled"], timeout: 8) else { return false }
        // A password prompt shows up as a failure mentioning "password".
        return !r.stderr.lowercased().contains("password")
    }

    /// Runs a privileged command non-interactively. Throws if the sudoers rule is missing.
    @discardableResult
    public static func run(_ path: String, _ args: [String], timeout: TimeInterval = 30) throws -> CommandResult {
        let r = try Shell.run(sudo, ["-n", path] + args, timeout: timeout)
        if !r.ok && r.stderr.lowercased().contains("password") {
            throw ColokError.privilegeNotInstalled
        }
        return r
    }

    public static var sudoersContents: String {
        let user = NSUserName()
        return """
        # Installed by Colok. Grants \(user) exactly the two privileged operations
        # Colok needs, with fixed arguments. Remove with: sudo rm \(sudoersPath)
        Cmnd_Alias COLOK_TETHER = /usr/bin/AssetCacheTetheratorUtil enable, \\
                                  /usr/bin/AssetCacheTetheratorUtil disable, \\
                                  /usr/bin/AssetCacheTetheratorUtil -j enable, \\
                                  /usr/bin/AssetCacheTetheratorUtil -j disable, \\
                                  /usr/bin/AssetCacheTetheratorUtil -j isEnabled
        Cmnd_Alias COLOK_CACHE  = /usr/bin/AssetCacheManagerUtil activate, \\
                                  /usr/bin/AssetCacheManagerUtil deactivate
        Cmnd_Alias COLOK_SHARE  = /usr/local/libexec/colok-share
        \(user) ALL=(root) NOPASSWD: COLOK_TETHER, COLOK_CACHE, COLOK_SHARE
        """
    }

    /// Shell one-liner the user pastes into Terminal to install the rule.
    public static var installCommand: String {
        "cd \"$(dirname \"$0\")\" 2>/dev/null; sudo bash Scripts/install-sudoers.sh"
    }
}

public enum ColokError: Error, LocalizedError {
    case privilegeNotInstalled
    case contentCachingUnavailable(String)
    case adbNotFound
    case gnirehtetNotFound
    case noDevice(String)
    case wifiToWifi

    public var errorDescription: String? {
        switch self {
        case .privilegeNotInstalled:
            return "Colok's sudoers rule isn't installed. Run: sudo bash Scripts/install-sudoers.sh"
        case .contentCachingUnavailable(let why):
            return "Content Caching can't be activated: \(why)"
        case .adbNotFound:
            return "adb not found. Install Android platform-tools, or set the adb path in Colok settings."
        case .gnirehtetNotFound:
            return "gnirehtet relay/APK not found. Run: bash Scripts/fetch-gnirehtet.sh"
        case .noDevice(let serial):
            return "Device \(serial) is not connected."
        case .wifiToWifi:
            return "macOS cannot share Wi-Fi over Wi-Fi - one radio can't be client and access point at once. Use an Ethernet adapter as the uplink or as the output."
        }
    }
}
