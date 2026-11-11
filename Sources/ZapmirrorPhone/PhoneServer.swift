import Foundation

/// Zapmirror's phone component (Phone/, built by Scripts/build-phone.sh): how it is installed and started.
/// docs/PHONE-PROTOCOL.md describes the conversation.
public enum PhoneServer {
    /// Must match `Main.VERSION` in the phone component, which refuses any other.
    public static let protocolVersion = "1"
    /// The component in the app bundle's Resources.
    public static let resourceName = "zapmirror-phone.jar"
    public static let devicePath = "/data/local/tmp/zapmirror-phone.jar"
    /// SHA-256 of the component this version of the app installs. The app refuses to install anything else, so a
    /// tampered jar in the bundle can't reach the phone. Scripts/build-phone.sh checks it and says how to update it.
    public static let sha256 = "b6715bf7490b35229e074a0bece71d63ae08b9e7f6fd3b87f76a512ae41bfd58"
    /// What the component prints once it accepts connections.
    public static let listeningLine = "zapmirror: listening"

    /// The abstract socket the component listens on for a session.
    public static func socketName(token: String) -> String {
        "zapmirror-" + token
    }

    /// A fresh 128-bit session token, as 32 hex digits. It names the socket, so nothing else can guess it.
    public static func newToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return String(format: "%016llx%016llx", generator.next() as UInt64, generator.next() as UInt64)
    }

    /// The shell command that starts the component.
    public static func command(token: String, options: Options) -> String {
        precondition(token.allSatisfy(\.isHexDigit), "the token goes into a shell command")
        return (["CLASSPATH=\(devicePath)", "app_process", "/", "app.zapmirror.phone.Main", protocolVersion, token]
            + options.arguments).joined(separator: " ")
    }

    public struct Options: Equatable, Sendable {
        /// Longest side of the video in pixels; 0 keeps the phone's resolution.
        public var maxSize = 1920
        public var bitRate = 8_000_000
        public var fps = 60
        /// Play the phone's sound on the Mac (Android 11+). The phone's speaker is quiet meanwhile.
        public var audio = true
        /// Keep the phone's screen on while mirroring.
        public var stayAwake = true

        public init() {}

        public var arguments: [String] {
            var args = ["--max-size", "\(maxSize)", "--bit-rate", "\(bitRate)", "--fps", "\(fps)"]
            if !audio { args.append("--no-audio") }
            if !stayAwake { args.append("--no-stay-awake") }
            return args
        }
    }
}

/// The three connections of a session.
public enum PhoneChannel: String, Sendable {
    case video, audio, control
}
