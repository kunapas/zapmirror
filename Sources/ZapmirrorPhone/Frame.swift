import Foundation
import ZapmirrorADB

/// One message between the Mac and the phone component: a type letter, a big-endian UInt32 length, the payload.
public struct Frame: Equatable, Sendable {
    public var type: UInt8
    public var payload: Data

    /// Generous, so a corrupt length can't make us allocate gigabytes.
    public static let maxPayload = 32 << 20

    public init(_ type: Character, _ payload: Data = Data()) {
        self.type = type.asciiValue!
        self.payload = payload
    }

    public init(type: UInt8, payload: Data) {
        self.type = type
        self.payload = payload
    }

    /// The first frame on every connection: which channel it is.
    public static func hello(_ channel: PhoneChannel) -> Frame {
        Frame("h", Data(channel.rawValue.utf8))
    }

    public static func read(from reader: ByteReader) throws -> Frame {
        let header = try reader.read(exactly: 5)
        let length = Int(header.bigEndianUInt32(at: 1))
        guard length <= maxPayload else { throw PhoneError.badFrame("frame of \(length) bytes") }
        return Frame(type: header[header.startIndex], payload: length == 0 ? Data() : try reader.read(exactly: length))
    }

    public func encoded() -> Data {
        var out = PayloadWriter()
        out.u8(type)
        out.u32(UInt32(payload.count))
        out.data.append(payload)
        return out.data
    }

    var text: String { String(decoding: payload, as: UTF8.self) }
}

public enum PhoneError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// The phone component said why it stopped.
    case phone(String)
    case badFrame(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .phone(let message): "The phone reported: \(message)"
        case .badFrame(let detail): "Unexpected data from the phone: \(detail)"
        case .unsupported(let what): "Zapmirror can't use \(what) yet."
        }
    }

    public var errorDescription: String? { description }
}

/// Builds big-endian payloads.
struct PayloadWriter {
    var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }

    /// UTF-8, cut at a character boundary to at most `maxBytes`.
    mutating func text(_ s: String, maxBytes: Int) {
        var bytes = Array(s.utf8)
        if bytes.count > maxBytes {
            var cut = maxBytes
            while cut > 0, bytes[cut] & 0xC0 == 0x80 { cut -= 1 } // don't split a multi-byte character
            bytes = Array(bytes[..<cut])
        }
        data.append(contentsOf: bytes)
    }
}

extension Data {
    func bigEndianUInt32(at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(self[startIndex + offset + $1]) }
    }

    func bigEndianUInt64(at offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(self[startIndex + offset + $1]) }
    }
}
