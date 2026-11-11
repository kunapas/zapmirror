import Foundation

/// Finds and starts the adb server from Android's platform tools. A stopgap until Zapmirror speaks the adb protocol
/// over USB itself (docs/MIRRORING-PLAN.md, stage C).
public enum AdbServer {
    /// Where platform tools usually live on a Mac.
    public static let searchPaths = [
        "/opt/homebrew/bin/adb",
        "/usr/local/bin/adb",
        "~/Library/Android/sdk/platform-tools/adb",
        "/opt/homebrew/share/android-commandlinetools/platform-tools/adb",
    ]

    public static func findExecutable(paths: [String] = searchPaths) -> URL? {
        // Fixed places only: an environment variable such as ANDROID_HOME could point this at any program.
        for path in paths {
            let expanded = (path as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) { return URL(fileURLWithPath: expanded) }
        }
        return nil
    }

    public enum Availability: Equatable, Sendable {
        case running
        /// No server and no adb to start one with.
        case notInstalled
    }

    /// Makes sure an adb server answers on localhost:5037, starting one with `adb start-server` if needed.
    public static func ensureRunning(client: AdbClient = AdbClient()) -> Availability {
        if (try? client.serverVersion()) != nil { return .running }
        guard let adb = findExecutable() else { return .notInstalled }
        let process = Process()
        process.executableURL = adb
        process.arguments = ["start-server"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .notInstalled
        }
        return (try? client.serverVersion()) != nil ? .running : .notInstalled
    }
}
