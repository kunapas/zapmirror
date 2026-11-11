import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Reads a byte stream in exact-sized pieces. Parsers take this, so tests can feed them from memory.
public protocol ByteReader: AnyObject {
    /// Exactly `count` bytes, or throws `AdbError.closed` if the stream ends first.
    func read(exactly count: Int) throws -> Data
}

public enum AdbError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// No adb server on localhost:5037.
    case serverNotRunning
    /// The adb server refused a request; `message` is its reason (e.g. "device unauthorized").
    case failed(String)
    /// The connection closed early.
    case closed
    case protocolError(String)
    case io(String)

    public var description: String {
        switch self {
        case .serverNotRunning: "The Android Debug Bridge (adb) isn't running."
        case .failed(let message): message
        case .closed: "The phone closed the connection."
        case .protocolError(let detail): "Unexpected reply from adb: \(detail)"
        case .io(let detail): detail
        }
    }

    public var errorDescription: String? { description }
}

/// A blocking TCP connection. Each phone channel gets its own, read on its own thread.
public final class AdbSocket: ByteReader, @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var isClosed = false

    /// Connects to 127.0.0.1:`port`.
    public init(port: UInt16) throws {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw AdbError.io("Couldn't create a socket (errno \(errno)).") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else {
            closeDescriptor(fd)
            throw AdbError.serverNotRunning
        }
        var one: Int32 = 1
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        self.fd = fd
    }

    deinit { close() }

    public func read(exactly count: Int) throws -> Data {
        var data = Data(count: count)
        var filled = 0
        while filled < count {
            let n = data.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + filled, count - filled, 0) }
            if n == 0 { throw AdbError.closed }
            if n < 0 {
                if errno == EINTR { continue }
                throw isClosedNow ? AdbError.closed : AdbError.io("Read failed (errno \(errno)).")
            }
            filled += n
        }
        return data
    }

    /// Whatever arrives next, up to `max` bytes; nil at the end of the stream.
    public func readSome(max: Int = 65_536) throws -> Data? {
        var data = Data(count: max)
        while true {
            let n = data.withUnsafeMutableBytes { recv(fd, $0.baseAddress!, max, 0) }
            if n == 0 { return nil }
            if n < 0 {
                if errno == EINTR { continue }
                if isClosedNow { return nil }
                throw AdbError.io("Read failed (errno \(errno)).")
            }
            return data.prefix(n)
        }
    }

    /// Everything until the other side closes.
    public func readToEnd() throws -> Data {
        var all = Data()
        while let chunk = try readSome() { all.append(chunk) }
        return all
    }

    public func write(_ data: Data) throws {
        var sent = 0
        while sent < data.count {
            #if canImport(Darwin)
            let flags: Int32 = 0
            #else
            let flags = Int32(MSG_NOSIGNAL)
            #endif
            let n = data.withUnsafeBytes { send(fd, $0.baseAddress! + sent, data.count - sent, flags) }
            if n < 0 {
                if errno == EINTR { continue }
                throw isClosedNow ? AdbError.closed : AdbError.io("Write failed (errno \(errno)).")
            }
            sent += n
        }
    }

    /// Safe to call from any thread, more than once; a blocked read on another thread returns.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        shutdown(fd, Int32(SHUT_RDWR))
        closeDescriptor(fd)
    }

    private var isClosedNow: Bool { lock.withLock { isClosed } }
}

private func closeDescriptor(_ fd: Int32) {
    #if canImport(Darwin)
    _ = Darwin.close(fd)
    #else
    _ = Glibc.close(fd)
    #endif
}
