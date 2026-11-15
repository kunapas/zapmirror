import Foundation
import Testing
@testable import ZapmirrorADB
@testable import ZapmirrorPhone

/// A ByteReader over bytes in memory.
private final class MemoryReader: ByteReader {
    private var data: Data
    init(_ bytes: [UInt8]) { data = Data(bytes) }
    init(_ data: Data) { self.data = data }

    func read(exactly count: Int) throws -> Data {
        guard data.count >= count else { throw AdbError.closed }
        let chunk = data.prefix(count)
        data = data.dropFirst(count)
        return Data(chunk)
    }
}

private func frame(_ type: Character, _ payload: [UInt8]) -> [UInt8] {
    [type.asciiValue!] + withUnsafeBytes(of: UInt32(payload.count).bigEndian, Array.init) + payload
}

private func bytes(_ control: PhoneControl) -> [UInt8] { [UInt8](control.frame.encoded()) }

/// docs/PHONE-PROTOCOL.md, byte for byte.
@Suite struct ControlFrames {
    @Test func hello() {
        #expect([UInt8](Frame.hello(.control).encoded()) == frame("h", Array("control".utf8)))
    }

    @Test func key() {
        #expect(bytes(.key(.down, .del, meta: [.ctrl], repeat: 2)) == frame("k", [0, 0, 0, 0, 0x43, 0, 0, 0x10, 0, 0, 0, 0, 2]))
    }

    @Test func text() {
        #expect(bytes(.text("Hi")) == frame("t", Array("Hi".utf8)))
    }

    @Test func longTextIsCutWithoutSplittingACharacter() {
        #expect(bytes(.text(String(repeating: "z", count: 5_000))).count == 5 + 4_096)
        #expect(bytes(.text(String(repeating: "z", count: 4_095) + "⚡")).count == 5 + 4_095)
    }

    @Test func touchUsesFractionsOfTheScreen() {
        #expect(bytes(.touch(.move, finger: 1, x: 0.5, y: 0.25)) == frame("p", [
            1, 1,
            0x3f, 0x00, 0, 0, // 0.5
            0x3e, 0x80, 0, 0, // 0.25
            0x3f, 0x80, 0, 0, // pressure 1
        ]))
    }

    @Test func scroll() {
        #expect(bytes(.scroll(x: 0, y: 1, horizontal: -1, vertical: 2)) == frame("w", [
            0, 0, 0, 0, 0x3f, 0x80, 0, 0, 0xbf, 0x80, 0, 0, 0x40, 0, 0, 0,
        ]))
    }

    @Test func shortMessages() {
        #expect(bytes(.backOrWake) == frame("b", []))
        #expect(bytes(.panel(.quickSettings)) == frame("n", [1]))
        #expect(bytes(.copy(cut: true)) == frame("g", [1]))
        #expect(bytes(.setClipboard("ok", paste: false)) == frame("s", [0] + Array("ok".utf8)))
        #expect(bytes(.screenPower(on: false)) == frame("d", [0]))
        #expect(bytes(.rotate) == frame("r", []))
        #expect(bytes(.keyFrame) == frame("v", []))
    }

    @Test func keycodesForLettersAndDigits() {
        #expect(AndroidKeycode.letter("a")?.rawValue == 29)
        #expect(AndroidKeycode.letter("Z")?.rawValue == 54)
        #expect(AndroidKeycode.digit("0")?.rawValue == 7)
        #expect(AndroidKeycode.letter("é") == nil)
    }
}

@Suite struct PhoneStreams {
    @Test func video() throws {
        var input = frame("I", Array(#"{"name":"Pixel 9 Pro XL","manufacturer":"Google","android":"17"}"#.utf8))
        input += frame("X", [9, 9]) // something newer: skipped
        input += frame("D", [0, 0, 0x04, 0x38, 0, 0, 0x09, 0x60])
        input += frame("C", [0xAA, 0xBB])
        input += frame("F", [0, 0, 0, 0, 0, 0, 0x03, 0xe8, 1, 0x65, 0x88])
        input += frame("F", [0, 0, 0, 0, 0, 0, 0x03, 0xe9, 0, 0x41])
        let stream = VideoStreamReader(reader: MemoryReader(input))
        #expect(try stream.readInfo() == PhoneInfo(name: "Pixel 9 Pro XL", manufacturer: "Google", android: "17"))
        #expect(try stream.next() == .size(width: 1080, height: 2400))
        #expect(try stream.next() == .config(Data([0xAA, 0xBB])))
        #expect(try stream.next() == .frame(Data([0x65, 0x88]), pts: 1000, keyFrame: true))
        #expect(try stream.next() == .frame(Data([0x41]), pts: 1001, keyFrame: false))
        #expect(throws: AdbError.closed) { try stream.next() }
    }

    @Test func videoErrorFromThePhone() {
        let stream = VideoStreamReader(reader: MemoryReader(frame("E", Array("no encoder".utf8))))
        #expect(throws: PhoneError.phone("no encoder")) { try stream.readInfo() }
    }

    @Test func absurdLengthsAreRefused() {
        #expect(throws: PhoneError.self) { try Frame.read(from: MemoryReader([0x46, 0x7f, 0xff, 0xff, 0xff])) }
    }

    @Test func audio() throws {
        let input = frame("I", Array(#"{"encoding":"pcm16le","rate":48000,"channels":2}"#.utf8)) + frame("S", [1, 2, 3, 4])
        let stream = AudioStreamReader(reader: MemoryReader(input))
        #expect(try stream.readHeader() == .format(.init(encoding: "pcm16le", rate: 48_000, channels: 2)))
        #expect(try stream.next() == Data([1, 2, 3, 4]))
    }

    @Test func noSoundLetsVideoGoOn() throws {
        let stream = AudioStreamReader(reader: MemoryReader(frame("E", Array("Android 11 or later is needed".utf8))))
        #expect(try stream.readHeader() == .unavailable("Android 11 or later is needed"))
    }

    @Test func hostileValuesAreRefused() throws {
        let zero = VideoStreamReader(reader: MemoryReader(frame("D", [0, 0, 0, 0, 0, 0, 0x09, 0x60])))
        #expect(throws: PhoneError.self) { try zero.next() }
        let rate = AudioStreamReader(reader: MemoryReader(frame("I", Array(#"{"encoding":"pcm16le","rate":0,"channels":2}"#.utf8))))
        #expect(throws: PhoneError.self) { try rate.readHeader() }
        let big = MemoryReader(frame("c", [UInt8](repeating: 0x61, count: (1 << 20) + 1)) + frame("c", Array("ok".utf8)))
        #expect(try PhoneMessage.read(from: big) == .clipboard("ok")) // the oversized one is skipped
    }

    @Test func clipboardFromThePhone() throws {
        let reader = MemoryReader(frame("q", [1]) + frame("c", Array("hi".utf8)))
        #expect(try PhoneMessage.read(from: reader) == .clipboard("hi"))
    }
}

@Suite struct Launch {
    @Test func command() {
        var options = PhoneServer.Options()
        #expect(PhoneServer.command(token: "0000abcd", options: options)
            == "CLASSPATH=/data/local/tmp/zapmirror-phone.jar app_process / app.zapmirror.phone.Main 1 0000abcd --max-size 1920 --bit-rate 8000000 --fps 60")
        options.audio = false
        options.stayAwake = false
        #expect(PhoneServer.command(token: "01", options: options).hasSuffix("--fps 60 --no-audio --no-stay-awake"))
        #expect(PhoneServer.socketName(token: "0000abcd") == "zapmirror-0000abcd")
        let token = PhoneServer.newToken()
        #expect(token.count == 32 && token.allSatisfy(\.isHexDigit) && token != PhoneServer.newToken())
    }
}

@Suite struct AdbHostProtocol {
    @Test func requestsAreLengthPrefixedInHex() {
        #expect(String(decoding: AdbClient.encodeRequest("host:version"), as: UTF8.self) == "000chost:version")
    }

    @Test func failuresCarryTheMessage() {
        #expect(throws: AdbError.failed("device unauthorized")) {
            try AdbClient.readStatus(MemoryReader(Data("FAIL0013device unauthorized".utf8)))
        }
    }

    @Test func deviceList() {
        let text = """
        0A1B2C3D4E5F6G         device usb:1-1 product:komodo model:Pixel_9_Pro_XL device:komodo transport_id:3
        emulator-5554          unauthorized transport_id:4

        """
        #expect(AdbDevice.parseList(text) == [
            AdbDevice(serial: "0A1B2C3D4E5F6G", state: .device, model: "Pixel 9 Pro XL"),
            AdbDevice(serial: "emulator-5554", state: .unauthorized, model: nil),
        ])
    }

    @Test func syncPackets() {
        #expect([UInt8](SyncProtocol.send(path: "/a", mode: 0o644)) == Array("SEND".utf8) + [8, 0, 0, 0] + Array("/a,33188".utf8))
        #expect([UInt8](SyncProtocol.done(modified: 1)) == Array("DONE".utf8) + [1, 0, 0, 0])
    }
}
