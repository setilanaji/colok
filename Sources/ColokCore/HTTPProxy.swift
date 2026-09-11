import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A minimal HTTP/HTTPS forward proxy bound to loopback.
///
/// This is the non-invasive alternative to gnirehtet: the phone reaches it over
/// `adb reverse`, so it never joins a VPN, never loses its own mobile data or
/// Wi-Fi, and clearing one setting undoes it. It handles CONNECT (all HTTPS) and
/// absolute-URI requests (plain HTTP). Loopback-only by design - nothing on the
/// network can reach it.
public final class HTTPProxy: @unchecked Sendable {
    public let port: UInt16
    /// Loopback for adb-reverse (Android). A bridge address for tethered iOS
    /// devices, which reach the Mac over the network rather than through adb.
    public let bindAddress: String
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "id.ketok.colok.proxy", attributes: .concurrent)
    private let lock = NSLock()
    private var _running = false
    private var _served = 0

    public init(port: UInt16 = 8899, bindAddress: String = "127.0.0.1") {
        self.port = port
        self.bindAddress = bindAddress
    }

    /// The IPv4 macOS gave the Internet Sharing / tetherator bridge. This is the
    /// address a tethered iPhone must be pointed at.
    public static func bridgeAddress() -> String? {
        guard let r = try? Shell.run("/sbin/ifconfig", ["bridge100"], timeout: 8), r.ok else { return nil }
        for line in r.stdout.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
            if parts.first == "inet", parts.count > 1 { return String(parts[1]) }
        }
        return nil
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return _running }
    public var servedConnections: Int { lock.lock(); defer { lock.unlock() }; return _served }

    // MARK: - Lifecycle

    public func start() throws {
        guard !isRunning else { return }
        let fd = socket(AF_INET, sockStreamType, 0)
        guard fd >= 0 else { throw ProxyError.socketFailed(errno) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, bindAddress, &addr.sin_addr) == 1 else {
            close(fd)
            throw ProxyError.badAddress(bindAddress)
        }

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(fd); throw ProxyError.bindFailed(port, errno) }
        guard listen(fd, 32) == 0 else { close(fd); throw ProxyError.listenFailed(errno) }

        listenFD = fd
        lock.lock(); _running = true; lock.unlock()

        queue.async { [weak self] in self?.acceptLoop(fd) }
    }

    public func stop() {
        lock.lock(); _running = false; lock.unlock()
        if listenFD >= 0 { shutdown(listenFD, shutdownBoth); close(listenFD); listenFD = -1 }
    }

    private func acceptLoop(_ fd: Int32) {
        while isRunning {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            lock.lock(); _served += 1; lock.unlock()
            queue.async { [weak self] in self?.serve(client) }
        }
    }

    // MARK: - One connection

    private func serve(_ client: Int32) {
        defer { close(client) }
        guard let (header, leftover) = readHeader(client) else { return }
        guard let request = RequestLine(header) else {
            reply(client, "HTTP/1.1 400 Bad Request\r\n\r\n")
            return
        }

        guard let upstream = dial(request.host, request.port) else {
            reply(client, "HTTP/1.1 502 Bad Gateway\r\n\r\n")
            return
        }
        defer { close(upstream) }

        if request.isConnect {
            reply(client, "HTTP/1.1 200 Connection Established\r\n\r\n")
        } else {
            // Rewrite absolute-URI to origin-form, then replay the original body bytes.
            var rebuilt = Data(request.rewrittenHeader.utf8)
            rebuilt.append(leftover)
            _ = writeAll(upstream, rebuilt)
        }
        if request.isConnect && !leftover.isEmpty { _ = writeAll(upstream, leftover) }

        // Pump both directions; either side closing ends the pair.
        let group = DispatchGroup()
        group.enter()
        queue.async { self.pump(from: client, to: upstream); shutdown(upstream, shutdownWrite); group.leave() }
        pump(from: upstream, to: client)
        shutdown(client, shutdownWrite)
        group.wait()
    }

    private func pump(from: Int32, to: Int32) {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { recv(from, $0.baseAddress, 32 * 1024, 0) }
            guard n > 0 else { return }
            guard writeAll(to, Data(buffer[0..<n])) else { return }
        }
    }

    // MARK: - Socket helpers

    private func readHeader(_ fd: Int32) -> (String, Data)? {
        var accumulated = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let terminator = Data("\r\n\r\n".utf8)
        while accumulated.count < 64 * 1024 {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, 4096, 0) }
            guard n > 0 else { return nil }
            accumulated.append(contentsOf: buffer[0..<n])
            if let range = accumulated.range(of: terminator) {
                let head = String(decoding: accumulated[..<range.lowerBound], as: UTF8.self)
                let rest = Data(accumulated[range.upperBound...])
                return (head, rest)
            }
        }
        return nil
    }

    private func dial(_ host: String, _ port: UInt16) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = sockStreamType
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let list = result else { return nil }
        defer { freeaddrinfo(list) }
        var candidate = Optional(list)
        while let info = candidate {
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
                if connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 { return fd }
                close(fd)
            }
            candidate = info.pointee.ai_next
        }
        return nil
    }

    @discardableResult
    private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            while sent < data.count {
                let n = send(fd, base.advanced(by: sent), data.count - sent, sendNoSignal)
                guard n > 0 else { return false }
                sent += n
            }
            return true
        }
    }

    private func reply(_ fd: Int32, _ text: String) {
        _ = writeAll(fd, Data(text.utf8))
    }
}

public enum ProxyError: Error, LocalizedError {
    case socketFailed(Int32)
    case bindFailed(UInt16, Int32)
    case listenFailed(Int32)
    case badAddress(String)

    public var errorDescription: String? {
        switch self {
        case .socketFailed(let e): return "socket() failed (errno \(e))"
        case .bindFailed(let p, let e): return "could not bind 127.0.0.1:\(p) (errno \(e)) - port in use?"
        case .listenFailed(let e): return "listen() failed (errno \(e))"
        case .badAddress(let a): return "not a valid IPv4 address to bind: \(a)"
        }
    }
}

/// Parses the request line well enough to route it.
struct RequestLine {
    let isConnect: Bool
    let host: String
    let port: UInt16
    let rewrittenHeader: String

    init?(_ header: String) {
        let lines = header.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ").map(String.init)
        guard parts.count >= 3 else { return nil }
        let method = parts[0], target = parts[1], version = parts[2]

        if method.uppercased() == "CONNECT" {
            let pieces = target.split(separator: ":")
            guard let h = pieces.first else { return nil }
            isConnect = true
            host = String(h)
            port = pieces.count > 1 ? (UInt16(pieces[1]) ?? 443) : 443
            rewrittenHeader = ""
            return
        }

        guard let url = URL(string: target), let h = url.host else { return nil }
        isConnect = false
        host = h
        port = UInt16(url.port ?? 80)

        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?" + q }
        var rebuilt = ["\(method) \(path) \(version)"]
        // Proxy-specific hop-by-hop headers must not be forwarded.
        for line in lines.dropFirst() where !line.lowercased().hasPrefix("proxy-connection:") {
            rebuilt.append(line)
        }
        rewrittenHeader = rebuilt.joined(separator: "\r\n") + "\r\n\r\n"
    }
}

// Constants that differ between Darwin and Glibc.
#if canImport(Darwin)
let sockStreamType = SOCK_STREAM
let shutdownBoth = SHUT_RDWR
let shutdownWrite = SHUT_WR
let sendNoSignal: Int32 = 0
#else
let sockStreamType = Int32(SOCK_STREAM.rawValue)
let shutdownBoth = Int32(SHUT_RDWR)
let shutdownWrite = Int32(SHUT_WR)
let sendNoSignal = Int32(MSG_NOSIGNAL)
#endif
