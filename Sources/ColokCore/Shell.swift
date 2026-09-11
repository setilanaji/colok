import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public var ok: Bool { status == 0 }
    public var trimmedOut: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
}

public enum ShellError: Error, LocalizedError {
    case notFound(String)
    case failed(String, CommandResult)

    public var errorDescription: String? {
        switch self {
        case .notFound(let bin): return "Executable not found: \(bin)"
        case .failed(let bin, let r):
            let msg = r.stderr.isEmpty ? r.stdout : r.stderr
            return "\(bin) exited \(r.status): \(msg.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// Thread-safe holder so the two pipe readers can hand their bytes back
/// without tripping Swift 6 concurrency checking.
final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func set(_ data: Data) { lock.lock(); storage = data; lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return storage }
}

public enum Shell {
    /// Runs a process to completion, capturing stdout and stderr without deadlocking on full pipes.
    @discardableResult
    public static func run(_ path: String,
                           _ args: [String] = [],
                           timeout: TimeInterval = 25,
                           environment: [String: String]? = nil,
                           currentDirectory: URL? = nil) throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: path) else { throw ShellError.notFound(path) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        if let environment { proc.environment = environment }
        if let currentDirectory { proc.currentDirectoryURL = currentDirectory }
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = FileHandle.nullDevice
        try proc.run()

        let outBox = DataBox(), errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        group.enter()
        DispatchQueue.global().async { errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile()); group.leave() }

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline { usleep(40_000) }
        // terminate() throws an ObjC exception if the process is already gone,
        // and an uncaught ObjC exception kills the app outright. Signal the pid
        // directly instead - it just returns ESRCH when there is nothing there.
        if proc.isRunning {
            let pid = proc.processIdentifier
            if pid > 0 {
                kill(pid, SIGTERM)
                usleep(200_000)
                if proc.isRunning { kill(pid, SIGKILL) }
            }
        }
        proc.waitUntilExit()
        group.wait()

        // Foundation closes these when the Pipe deallocates, but under a burst of
        // polling that is far too late - the app hits its file-descriptor limit
        // and the process dies. Close them now.
        try? outPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()

        return CommandResult(status: proc.terminationStatus,
                             stdout: String(decoding: outBox.value, as: UTF8.self),
                             stderr: String(decoding: errBox.value, as: UTF8.self))
    }

    @discardableResult
    public static func require(_ path: String,
                               _ args: [String] = [],
                               timeout: TimeInterval = 25,
                               environment: [String: String]? = nil,
                               currentDirectory: URL? = nil) throws -> CommandResult {
        let r = try run(path, args, timeout: timeout, environment: environment, currentDirectory: currentDirectory)
        guard r.ok else { throw ShellError.failed((path as NSString).lastPathComponent, r) }
        return r
    }

    /// Locates a binary on PATH plus any extra candidate directories.
    public static func locate(_ name: String, extraDirectories: [String] = []) -> String? {
        let fm = FileManager.default
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":").map(String.init)
        let fallback = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin", "/opt/homebrew/bin"]
        for dir in extraDirectories + pathDirs + fallback {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Long-running child process, used for the gnirehtet relay.
    public static func spawn(_ path: String,
                             _ args: [String],
                             logURL: URL? = nil,
                             environment: [String: String]? = nil,
                             currentDirectory: URL? = nil) throws -> Process {
        guard FileManager.default.isExecutableFile(atPath: path) else { throw ShellError.notFound(path) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        if let environment { proc.environment = environment }
        if let currentDirectory { proc.currentDirectoryURL = currentDirectory }
        if let logURL {
            _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: logURL) {
                proc.standardOutput = handle
                proc.standardError = handle
            }
        } else {
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
        }
        proc.standardInput = FileHandle.nullDevice
        try proc.run()
        return proc
    }
}
