import AppKit
import CryptoKit
import Foundation
import Observation
import os
import ZapmirrorADB
import ZapmirrorPhone

let mirrorLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Zapmirror", category: "mirror")

/// One mirroring session with one phone: installs and starts Zapmirror's phone component, shows its video, plays
/// its sound and sends it input (docs/PHONE-PROTOCOL.md).
@MainActor @Observable
final class MirrorSession {
    enum State: Equatable {
        case idle
        case connecting(String)
        /// `width`×`height` is the current video frame, which every input position refers to.
        case mirroring(width: Int, height: Int)
        case failed(String)
    }

    private(set) var state = State.idle
    private(set) var deviceName = ""
    private(set) var serial: String?
    /// Whether we turned the phone's screen off (mirroring continues).
    private(set) var screenOff = false

    @ObservationIgnored let renderer = VideoRenderer()
    @ObservationIgnored private let audio = AudioPlayer()
    /// Mutes the phone's sound on the Mac (the phone stays silent while mirroring either way).
    var soundMuted = false {
        didSet { audio.isMuted = soundMuted }
    }
    @ObservationIgnored private var connection: Connection?

    var isActive: Bool {
        switch state {
        case .connecting, .mirroring: true
        case .idle, .failed: false
        }
    }

    var videoSize: CGSize? {
        if case .mirroring(let w, let h) = state { CGSize(width: w, height: h) } else { nil }
    }

    func start(_ device: AdbDevice, options: PhoneServer.Options = .init()) {
        stop()
        serial = device.serial
        deviceName = device.name
        screenOff = false
        state = .connecting("Starting Zapmirror on your phone…")
        let renderer = renderer
        let audio = audio
        let owner = self // lives as long as the app
        Task.detached {
            do {
                let connection = try Connection.open(serial: device.serial, options: options) { step in
                    Task { @MainActor in owner.progress(step) }
                }
                await owner.attach(connection)
                connection.run(renderer: renderer, audio: audio,
                               onSession: { w, h in Task { @MainActor in owner.sessionChanged(width: w, height: h) } },
                               onClipboard: { text in Task { @MainActor in owner.phoneClipboard(text) } },
                               onEnd: { error in Task { @MainActor in owner.ended(connection, error: error) } })
            } catch {
                await owner.failed(error)
            }
        }
    }

    func stop() {
        connection?.close()
        connection = nil
        renderer.clear()
        audio.stop()
        if isActive { state = .idle }
    }

    // MARK: - Input

    func send(_ message: PhoneControl) {
        connection?.send(message)
    }

    func press(_ keycode: AndroidKeycode, meta: AndroidMetaState = []) {
        send(.key(.down, keycode, meta: meta))
        send(.key(.up, keycode, meta: meta))
    }

    /// Back, or wake the phone if its screen is off.
    func back() {
        send(.backOrWake)
    }

    func setScreenOff(_ off: Bool) {
        send(.screenPower(on: !off))
        screenOff = off
    }

    /// ⌘V: put the Mac's clipboard on the phone and paste it there.
    func pasteFromMac() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        send(.setClipboard(text, paste: true))
    }

    /// ⌘C / ⌘X: the phone copies its selection; the text comes back as a clipboard message.
    func copyOnPhone(cut: Bool = false) {
        send(.copy(cut: cut))
    }

    // MARK: - Session events

    private func progress(_ step: String) {
        if case .connecting = state { state = .connecting(step) }
    }

    private func attach(_ connection: Connection) {
        guard case .connecting = state else {
            connection.close() // stopped while connecting
            return
        }
        self.connection = connection
        if !connection.deviceName.isEmpty { deviceName = connection.deviceName }
    }

    private func sessionChanged(width: Int, height: Int) {
        guard connection != nil else { return }
        state = .mirroring(width: width, height: height)
    }

    private func phoneClipboard(_ text: String) {
        guard text != NSPasteboard.general.string(forType: .string) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func ended(_ ended: Connection, error: (any Error)?) {
        guard connection === ended else { return }
        connection = nil
        renderer.clear()
        audio.stop()
        if let error, !(error as? AdbError == .closed) {
            state = .failed(error.localizedDescription)
        } else {
            state = .failed("The phone disconnected.")
        }
        mirrorLog.notice("Session ended: \(String(describing: error), privacy: .public)")
    }

    private func failed(_ error: any Error) {
        guard case .connecting = state else { return }
        state = .failed(error.localizedDescription)
        mirrorLog.error("Couldn't start mirroring: \(String(describing: error), privacy: .public)")
    }
}

/// The connections of one session. Everything here runs off the main thread.
final class Connection: @unchecked Sendable {
    private let server: AdbSocket
    private let output: ServerOutput
    private let video: AdbSocket
    private let audioSocket: AdbSocket?
    private let control: AdbSocket
    private let stream: VideoStreamReader
    private let writer = DispatchQueue(label: "Zapmirror control")
    private let lock = NSLock()
    private var closed = false
    let deviceName: String

    private init(server: AdbSocket, output: ServerOutput, video: AdbSocket, audio: AdbSocket?, control: AdbSocket,
                 stream: VideoStreamReader, info: PhoneInfo) {
        self.server = server
        self.output = output
        self.video = video
        audioSocket = audio
        self.control = control
        self.stream = stream
        deviceName = info.name
    }

    enum SetupError: Error, LocalizedError {
        case componentMissing
        case componentDamaged
        case didNotStart(String)

        var errorDescription: String? {
            switch self {
            case .componentMissing: "This copy of Zapmirror is missing its phone component. Reinstall Zapmirror."
            case .componentDamaged: "Zapmirror's phone component has been changed. Reinstall Zapmirror."
            case .didNotStart(let output):
                output.isEmpty ? "Zapmirror couldn't start on the phone." : "Zapmirror couldn't start on the phone: \(output)"
            }
        }
    }

    /// Installs and starts the phone component, waits until it listens, then opens the channels.
    static func open(serial: String, options: PhoneServer.Options, progress: @Sendable (String) -> Void) throws -> Connection {
        let adb = AdbClient()
        guard let url = Bundle.main.url(forResource: PhoneServer.resourceName, withExtension: nil),
              let jar = try? Data(contentsOf: url) else { throw SetupError.componentMissing }
        guard SHA256.hash(data: jar).map({ String(format: "%02x", $0) }).joined() == PhoneServer.sha256 else {
            throw SetupError.componentDamaged
        }
        try adb.push(jar, to: PhoneServer.devicePath, on: serial)

        let token = PhoneServer.newToken()
        let server = try adb.open("shell:" + PhoneServer.command(token: token, options: options), on: serial)
        let output = ServerOutput(server)
        guard output.waitFor(PhoneServer.listeningLine, timeout: 10) else {
            server.close()
            throw SetupError.didNotStart(output.text)
        }
        progress("Connecting to the screen…")

        var opened: [AdbSocket] = []
        func connect(_ channel: PhoneChannel) throws -> AdbSocket {
            let socket = try adb.open("localabstract:" + PhoneServer.socketName(token: token), on: serial)
            opened.append(socket)
            try socket.write(Frame.hello(channel).encoded())
            return socket
        }
        do {
            let video = try connect(.video)
            let audio = options.audio ? try connect(.audio) : nil
            let control = try connect(.control)
            let stream = VideoStreamReader(reader: video)
            let info = try stream.readInfo()
            mirrorLog.notice("Mirroring \(info.manufacturer, privacy: .public) \(info.name, privacy: .public), Android \(info.android, privacy: .public)")
            return Connection(server: server, output: output, video: video, audio: audio, control: control,
                              stream: stream, info: info)
        } catch {
            opened.forEach { $0.close() }
            server.close()
            throw error
        }
    }

    /// Starts the reading threads. `onEnd` is called once, when the video stream stops.
    func run(renderer: VideoRenderer, audio player: AudioPlayer, onSession: @escaping @Sendable (Int, Int) -> Void,
             onClipboard: @escaping @Sendable (String) -> Void, onEnd: @escaping @Sendable ((any Error)?) -> Void) {
        let stream = stream
        Thread.detachNewThread { [self] in
            Thread.current.name = "Zapmirror video"
            Thread.current.qualityOfService = .userInteractive
            do {
                while true {
                    let packet = try stream.next()
                    if case .size(let w, let h) = packet { onSession(w, h) }
                    renderer.handle(packet)
                }
            } catch {
                let wasClosed = isClosed
                close()
                onEnd(wasClosed ? nil : error)
            }
        }
        if let audioSocket {
            Thread.detachNewThread {
                Thread.current.name = "Zapmirror audio"
                Thread.current.qualityOfService = .userInteractive
                let stream = AudioStreamReader(reader: audioSocket)
                do {
                    switch try stream.readHeader() {
                    case .unavailable(let reason):
                        mirrorLog.notice("No sound from the phone: \(reason, privacy: .public)")
                        return
                    case .format(let format):
                        try player.start(rate: format.rate)
                        mirrorLog.notice("Playing the phone's sound")
                    }
                    while true { player.enqueue(try stream.next()) }
                } catch {
                    player.stop()
                }
            }
        }
        Thread.detachNewThread { [control] in
            Thread.current.name = "Zapmirror phone messages"
            while let message = try? PhoneMessage.read(from: control) {
                if case .clipboard(let text) = message { onClipboard(text) }
            }
        }
    }

    func send(_ message: PhoneControl) {
        let data = message.frame.encoded()
        writer.async { [control] in try? control.write(data) }
    }

    var isClosed: Bool { lock.withLock { closed } }

    /// Closes the channels. The phone component then puts back what it changed (screen power, rotation) and exits;
    /// its shell stays open until it has, for at most two seconds.
    func close() {
        let first = lock.withLock {
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        control.close()
        video.close()
        audioSocket?.close()
        let server = server, output = output
        Thread.detachNewThread {
            _ = output.waitForEnd(timeout: 2)
            server.close()
        }
    }
}

/// Collects what the phone component prints, for the log and error messages.
private final class ServerOutput: @unchecked Sendable {
    private let condition = NSCondition()
    private var buffer = ""
    private var ended = false
    /// Only the recent output matters (the listening line, the last error).
    private static let kept = 16_384

    init(_ socket: AdbSocket) {
        Thread.detachNewThread { [self] in
            while let chunk = try? socket.readSome() {
                let text = String(decoding: chunk, as: UTF8.self)
                condition.withLock {
                    buffer += text
                    if buffer.count > Self.kept * 2 { buffer = String(buffer.suffix(Self.kept)) }
                    condition.broadcast()
                }
                for line in text.split(whereSeparator: \.isNewline) {
                    mirrorLog.notice("phone: \(line, privacy: .public)")
                }
            }
            condition.withLock {
                ended = true
                condition.broadcast()
            }
        }
    }

    /// Waits until the output contains `line`; false if the component exited or time ran out first.
    func waitFor(_ line: String, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        return condition.withLock {
            while !buffer.contains(line) {
                if ended || !condition.wait(until: deadline) { return buffer.contains(line) }
            }
            return true
        }
    }

    func waitForEnd(timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        return condition.withLock {
            while !ended {
                if !condition.wait(until: deadline) { return ended }
            }
            return true
        }
    }

    /// The last error line, or the last line.
    var text: String {
        let lines = condition.withLock { buffer }.split(whereSeparator: \.isNewline).map(String.init)
        let last = lines.last(where: { $0.localizedCaseInsensitiveContains("error") || $0.contains("Exception") }) ?? lines.last ?? ""
        return last.hasPrefix("zapmirror: ") ? String(last.dropFirst("zapmirror: ".count)) : last
    }
}
