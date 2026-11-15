import AppKit
import SwiftUI

@main
struct ZapmirrorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window(AppConfig.name, id: "main") {
            MirrorScreen(devices: appDelegate.devices, session: appDelegate.session)
                .frame(minWidth: 320, minHeight: 480)
        }
        .commands {
            ZapmirrorCommands()
            PhoneCommands(session: appDelegate.session)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let devices = DevicesModel()
    let session = MirrorSession()

    /// Mirroring keeps the phone awake and unlocked, so it ends when this Mac is locked, put to sleep or switched to
    /// another user: an unattended phone goes back to locking itself.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.screensDidSleepNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.session.stop() }
            }
        }
        snapshotIfRequested()
        testRunIfRequested()
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.session.stop() }
        }
    }

    /// `--snapshot=/path/file.png` renders the Connect page to a picture and quits: a design aid that needs no
    /// screen recording.
    private func snapshotIfRequested() {
        guard let path = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--snapshot=") })?.dropFirst(11) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let page = ConnectView(devices: devices, session: session)
                .frame(width: 620, height: 860)
                .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: page)
            renderer.scale = 2
            if let tiff = renderer.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(path)))
            }
            NSApp.terminate(nil)
        }
    }

    /// `--connect` mirrors the one ready phone without a click, and `--record=<seconds>` then records for that long
    /// and quits. For testing with a real phone from the command line; neither is used in normal runs.
    private func testRunIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        let seconds = args.first { $0.hasPrefix("--record=") }.flatMap { Double($0.dropFirst(9)) }
        guard args.contains("--connect") || seconds != nil else { return }
        Task { @MainActor in
            while devices.ready.count != 1 { try? await Task.sleep(for: .milliseconds(300)) }
            session.start(devices.ready[0])
            guard let seconds else { return }
            while session.videoSize == nil { try? await Task.sleep(for: .milliseconds(300)) }
            try? await Task.sleep(for: .seconds(2))
            session.toggleRecording()
            try? await Task.sleep(for: .seconds(seconds))
            session.toggleRecording()
            try? await Task.sleep(for: .seconds(3)) // let the file finish
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.stop() // ends the component on the phone
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// The phone's buttons and panels, with Mac-friendly shortcuts (⌘H and ⌘Q stay macOS's).
struct PhoneCommands: Commands {
    let session: MirrorSession

    var body: some Commands {
        CommandMenu("Phone") {
            let off = !session.isActive
            Button("Back") { session.back() }.keyboardShortcut("[", modifiers: .command).disabled(off)
            Button("Home") { session.press(.home) }.keyboardShortcut("h", modifiers: [.command, .shift]).disabled(off)
            Button("Recent Apps") { session.press(.appSwitch) }.keyboardShortcut("a", modifiers: [.command, .shift]).disabled(off)
            Divider()
            Button("Volume Up") { session.press(.volumeUp) }.keyboardShortcut(.upArrow, modifiers: .command).disabled(off)
            Button("Volume Down") { session.press(.volumeDown) }.keyboardShortcut(.downArrow, modifiers: .command).disabled(off)
            Button(session.soundMuted ? "Unmute Phone Sound" : "Mute Phone Sound") { session.soundMuted.toggle() }
                .keyboardShortcut("m", modifiers: [.command, .shift]).disabled(off)
            Button("Power Button") { session.press(.power) }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(off)
            Divider()
            Button(session.screenOff ? "Turn Phone Screen On" : "Turn Phone Screen Off") { session.setScreenOff(!session.screenOff) }
                .keyboardShortcut("o", modifiers: [.command, .shift]).disabled(off)
            Button("Rotate Phone") { session.send(.rotate) }.keyboardShortcut("r", modifiers: .command).disabled(off)
            Button(session.isRecording ? "Stop Recording" : "Start Recording") { session.toggleRecording() }
                .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(off)
            Divider()
            Button("Show Notifications") { session.send(.panel(.notifications)) }
                .keyboardShortcut("n", modifiers: [.command, .shift]).disabled(off)
            Button("Show Quick Settings") { session.send(.panel(.quickSettings)) }
                .keyboardShortcut("n", modifiers: [.command, .option, .shift]).disabled(off)
            Button("Close Panels") { session.send(.panel(.close)) }.disabled(off)
            Divider()
            Button("Disconnect") { session.stop() }.keyboardShortcut("d", modifiers: [.command, .shift]).disabled(off)
        }
    }
}

struct ZapmirrorCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(AppConfig.name)") { showAbout() }
        }
        // Zapmirror is free. The optional link is for anyone who wants to support the work.
        CommandGroup(after: .appInfo) {
            if let url = AppConfig.supportURL {
                Button("Support Zapmirror…") { NSWorkspace.shared.open(url) }
            }
        }
    }

    private func showAbout() {
        let credits = NSAttributedString(string: "Show and control your Android phone on your Mac. Free.", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }
}
