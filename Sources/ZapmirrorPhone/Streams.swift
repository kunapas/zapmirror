import Foundation
import ZapmirrorADB

/// The phone, as its component describes it at the start of the video channel.
public struct PhoneInfo: Decodable, Equatable, Sendable {
    public var name: String
    public var manufacturer: String
    public var android: String
}

/// What arrives on the video channel after the info.
public enum VideoPacket: Equatable, Sendable {
    /// The video's new size in pixels: before the first frame and after every rotation.
    case size(width: Int, height: Int)
    /// H.264 SPS and PPS, Annex B. Follows every size.
    case config(Data)
    /// One H.264 access unit, Annex B. `pts` is in microseconds.
    case frame(Data, pts: UInt64, keyFrame: Bool)
}

/// Reads the video channel, from one thread at a time.
public final class VideoStreamReader: @unchecked Sendable {
    private let reader: ByteReader
    /// Plausible video sides in pixels; anything else is refused before it reaches window maths.
    static let sides = 16...8_192

    public init(reader: ByteReader) { self.reader = reader }

    public func readInfo() throws -> PhoneInfo {
        let frame = try nextKnown()
        guard frame.type == UInt8(ascii: "I") else { throw PhoneError.badFrame("video began with '\(frame.type)'") }
        do {
            return try JSONDecoder().decode(PhoneInfo.self, from: frame.payload)
        } catch {
            throw PhoneError.badFrame("phone info: \(frame.text)")
        }
    }

    public func next() throws -> VideoPacket {
        while true {
            let frame = try nextKnown()
            let p = frame.payload
            switch frame.type {
            case UInt8(ascii: "D"):
                guard p.count >= 8 else { throw PhoneError.badFrame("short size") }
                let width = Int(p.bigEndianUInt32(at: 0)), height = Int(p.bigEndianUInt32(at: 4))
                guard Self.sides.contains(width), Self.sides.contains(height) else {
                    throw PhoneError.badFrame("video size \(width)×\(height)")
                }
                return .size(width: width, height: height)
            case UInt8(ascii: "C"):
                return .config(p)
            case UInt8(ascii: "F"):
                guard p.count > 9 else { throw PhoneError.badFrame("short video frame") }
                return .frame(Data(p.dropFirst(9)), pts: p.bigEndianUInt64(at: 0), keyFrame: p[p.startIndex + 8] & 1 != 0)
            default:
                continue // from a newer phone component
            }
        }
    }

    /// The next frame, turning the component's 'E' into an error.
    private func nextKnown() throws -> Frame {
        let frame = try Frame.read(from: reader)
        if frame.type == UInt8(ascii: "E") { throw PhoneError.phone(frame.text) }
        return frame
    }
}

/// Reads the audio channel.
public final class AudioStreamReader {
    /// 16-bit little-endian PCM, interleaved.
    public struct Format: Decodable, Equatable, Sendable {
        public var encoding: String
        public var rate: Double
        public var channels: Int
    }

    public enum Header: Equatable, Sendable {
        case format(Format)
        /// The phone can't share its sound, and why. Video carries on.
        case unavailable(String)
    }

    private let reader: ByteReader

    public init(reader: ByteReader) { self.reader = reader }

    public func readHeader() throws -> Header {
        let frame = try Frame.read(from: reader)
        switch frame.type {
        case UInt8(ascii: "E"):
            return .unavailable(frame.text)
        case UInt8(ascii: "I"):
            guard let format = try? JSONDecoder().decode(Format.self, from: frame.payload) else {
                throw PhoneError.badFrame("audio format: \(frame.text)")
            }
            guard format.encoding == "pcm16le" else { throw PhoneError.unsupported("\(format.encoding) sound") }
            guard (8_000...192_000).contains(format.rate), format.channels == 2 else {
                throw PhoneError.badFrame("audio format: \(frame.text)")
            }
            return .format(format)
        default:
            throw PhoneError.badFrame("audio began with '\(frame.type)'")
        }
    }

    /// The next block of samples.
    public func next() throws -> Data {
        while true {
            let frame = try Frame.read(from: reader)
            if frame.type == UInt8(ascii: "S") { return frame.payload }
        }
    }
}

/// Messages from the phone on the control channel.
public enum PhoneMessage: Equatable, Sendable {
    /// What the phone copied after the Mac asked it to (⌘C or ⌘X).
    case clipboard(String)

    static let maxClipboardBytes = 1 << 20

    public static func read(from reader: ByteReader) throws -> PhoneMessage {
        while true {
            let frame = try Frame.read(from: reader)
            // Larger clipboards are dropped: nobody copies a megabyte of text on purpose.
            if frame.type == UInt8(ascii: "c"), frame.payload.count <= maxClipboardBytes { return .clipboard(frame.text) }
        }
    }
}
