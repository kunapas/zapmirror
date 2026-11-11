import Foundation
import Testing
@testable import ZapmirrorADB

/// Against the real adb server, and the first ready phone if one is plugged in. Skipped unless ZAPMIRROR_LIVE_TESTS=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ZAPMIRROR_LIVE_TESTS"] == "1"))
struct LiveAdb {
    @Test func serverAnswers() throws {
        #expect(AdbServer.ensureRunning() == .running)
        #expect(try AdbClient().serverVersion() >= 31)
        _ = try AdbClient().devices()
    }

    @Test func shellAndPushOnAPhone() throws {
        let adb = AdbClient()
        guard let phone = try adb.devices().first(where: { $0.state == .device }) else { return }
        #expect(try adb.shell("echo zapmirror", on: phone.serial).trimmingCharacters(in: .whitespacesAndNewlines) == "zapmirror")
        let payload = Data((0..<200_000).map { UInt8($0 % 251) }) // several sync chunks
        try adb.push(payload, to: "/data/local/tmp/zapmirror-test.bin", on: phone.serial)
        let size = try adb.shell("stat -c %s /data/local/tmp/zapmirror-test.bin; rm /data/local/tmp/zapmirror-test.bin", on: phone.serial)
        #expect(size.trimmingCharacters(in: .whitespacesAndNewlines) == "200000")
    }
}
