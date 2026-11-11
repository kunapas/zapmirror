import Foundation
import Observation
import ZapmirrorADB

/// Phones the adb server sees, kept up to date with `host:track-devices-l`.
@MainActor @Observable
final class DevicesModel {
    enum Availability: Equatable {
        case starting
        case ready
        /// No adb server and no platform tools to start one (docs/MIRRORING-PLAN.md: until the built-in USB connection).
        case adbMissing
    }

    private(set) var availability = Availability.starting
    private(set) var devices: [AdbDevice] = []
    @ObservationIgnored private var started = false

    var ready: [AdbDevice] { devices.filter { $0.state == .device } }

    func start() {
        guard !started else { return }
        started = true
        let model = self // lives as long as the app
        Thread.detachNewThread {
            Thread.current.name = "Zapmirror devices"
            while true {
                switch AdbServer.ensureRunning() {
                case .notInstalled:
                    Task { @MainActor in model.update(.adbMissing, []) }
                case .running:
                    try? AdbClient().trackDevices { list in
                        Task { @MainActor in model.update(.ready, list) }
                        return true
                    }
                }
                // The server stopped (or isn't installed yet): look again shortly.
                Thread.sleep(forTimeInterval: 2)
            }
        }
    }

    private func update(_ availability: Availability, _ devices: [AdbDevice]) {
        self.availability = availability
        if self.devices != devices { self.devices = devices }
    }
}
