import Foundation

/// A phone as the adb server lists it.
public struct AdbDevice: Equatable, Sendable, Identifiable {
    public enum State: Equatable, Sendable {
        /// Ready to use.
        case device
        /// USB debugging is on, but the phone hasn't tapped "Allow" for this Mac yet.
        case unauthorized
        case offline
        case other(String)

        init(_ text: String) {
            switch text {
            case "device": self = .device
            case "unauthorized": self = .unauthorized
            case "offline": self = .offline
            default: self = .other(text)
            }
        }
    }

    public var serial: String
    public var state: State
    /// "Pixel 9 Pro XL", from the `model:Pixel_9_Pro_XL` field, when the server knows it.
    public var model: String?

    public var id: String { serial }
    public var name: String { model ?? serial }

    /// Parses `host:devices-l` output: "SERIAL   state usb:… product:… model:Pixel_9_Pro_XL device:… transport_id:1".
    public static func parseList(_ text: String) -> [AdbDevice] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2 else { return nil }
            let model = fields.dropFirst(2).first { $0.hasPrefix("model:") }
                .map { String($0.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ") }
            return AdbDevice(serial: fields[0], state: State(fields[1]), model: model)
        }
    }
}

/// Talks to the adb server's host protocol on localhost:5037, the same way the `adb` command does:
/// "<4 hex digits length><request>", answered by "OKAY" or "FAIL<4 hex length><message>".
public struct AdbClient: Sendable {
    public static let defaultPort: UInt16 = 5037
    public let port: UInt16

    public init(port: UInt16 = AdbClient.defaultPort) { self.port = port }

    /// The adb server's protocol version, e.g. 41. Throws `serverNotRunning` if there's none.
    public func serverVersion() throws -> Int {
        let socket = try request("host:version")
        defer { socket.close() }
        guard let version = Int(try Self.readLengthPrefixedString(socket), radix: 16) else {
            throw AdbError.protocolError("bad version")
        }
        return version
    }

    public func devices() throws -> [AdbDevice] {
        let socket = try request("host:devices-l")
        defer { socket.close() }
        return AdbDevice.parseList(try Self.readLengthPrefixedString(socket))
    }

    /// Calls `update` with the device list now and after every change, until the socket closes or `update` returns
    /// false. Blocks: run it on its own thread.
    public func trackDevices(_ update: ([AdbDevice]) -> Bool) throws {
        let socket = try request("host:track-devices-l")
        defer { socket.close() }
        while update(AdbDevice.parseList(try Self.readLengthPrefixedString(socket))) {}
    }

    /// Opens `service` on the phone ("shell:…", "sync:", "localabstract:…") and returns the raw stream.
    public func open(_ service: String, on serial: String) throws -> AdbSocket {
        let socket = try request("host:transport:\(serial)")
        do {
            try Self.send(service, on: socket)
            try Self.readStatus(socket)
            return socket
        } catch {
            socket.close()
            throw error
        }
    }

    /// Runs a shell command on the phone and returns what it printed.
    public func shell(_ command: String, on serial: String) throws -> String {
        let socket = try open("shell:\(command)", on: serial)
        defer { socket.close() }
        return String(decoding: try socket.readToEnd(), as: UTF8.self)
    }

    /// Copies `data` to `path` on the phone with the sync protocol.
    public func push(_ data: Data, to path: String, mode: Int = 0o644, on serial: String) throws {
        let socket = try open("sync:", on: serial)
        defer { socket.close() }
        try socket.write(SyncProtocol.send(path: path, mode: mode))
        var offset = 0
        repeat {
            let chunk = data[data.startIndex + offset ..< data.startIndex + min(offset + SyncProtocol.maxChunk, data.count)]
            try socket.write(SyncProtocol.data(Data(chunk)))
            offset += chunk.count
        } while offset < data.count
        try socket.write(SyncProtocol.done(modified: UInt32(Date().timeIntervalSince1970)))
        try SyncProtocol.readResult(socket)
        try? socket.write(SyncProtocol.quit())
    }

    // MARK: - Host protocol

    /// Sends a host request on a fresh connection and checks the status.
    func request(_ text: String) throws -> AdbSocket {
        let socket = try AdbSocket(port: port)
        do {
            try Self.send(text, on: socket)
            try Self.readStatus(socket)
            return socket
        } catch {
            socket.close()
            throw error
        }
    }

    static func encodeRequest(_ text: String) -> Data {
        let body = Data(text.utf8)
        return Data(String(format: "%04x", body.count).utf8) + body
    }

    static func send(_ text: String, on socket: AdbSocket) throws {
        try socket.write(encodeRequest(text))
    }

    static func readStatus(_ reader: ByteReader) throws {
        let status = String(decoding: try reader.read(exactly: 4), as: UTF8.self)
        switch status {
        case "OKAY": return
        case "FAIL": throw AdbError.failed(try readLengthPrefixedString(reader))
        default: throw AdbError.protocolError("status \(status)")
        }
    }

    static func readLengthPrefixedString(_ reader: ByteReader) throws -> String {
        let hex = String(decoding: try reader.read(exactly: 4), as: UTF8.self)
        guard let length = Int(hex, radix: 16) else { throw AdbError.protocolError("length \(hex)") }
        return length == 0 ? "" : String(decoding: try reader.read(exactly: length), as: UTF8.self)
    }
}

/// The file-transfer protocol behind "sync:": 4-letter commands with little-endian lengths.
enum SyncProtocol {
    static let maxChunk = 64 * 1024

    static func packet(_ id: String, _ value: UInt32, _ payload: Data = Data()) -> Data {
        var data = Data(id.utf8)
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        return data + payload
    }

    static func send(path: String, mode: Int) -> Data {
        let target = Data("\(path),\(0o100000 | mode)".utf8) // regular file
        return packet("SEND", UInt32(target.count), target)
    }

    static func data(_ chunk: Data) -> Data { packet("DATA", UInt32(chunk.count), chunk) }
    static func done(modified: UInt32) -> Data { packet("DONE", modified) }
    static func quit() -> Data { packet("QUIT", 0) }

    static func readResult(_ reader: ByteReader) throws {
        let id = String(decoding: try reader.read(exactly: 4), as: UTF8.self)
        let length = try reader.read(exactly: 4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        switch id {
        case "OKAY": return
        case "FAIL":
            guard length <= 4_096 else { throw AdbError.protocolError("sync failure of \(length) bytes") }
            throw AdbError.failed(String(decoding: try reader.read(exactly: Int(length)), as: UTF8.self))
        default: throw AdbError.protocolError("sync \(id)")
        }
    }
}
