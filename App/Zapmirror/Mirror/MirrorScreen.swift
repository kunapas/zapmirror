import SwiftUI
import ZapmirrorADB
import ZapmirrorPhone

/// The main window's content: the phone's screen, or the Connect page.
/// Zapmirror never connects by itself: plugging the phone in only updates the Connect page.
struct MirrorScreen: View {
    let devices: DevicesModel
    let session: MirrorSession

    var body: some View {
        Group {
            switch session.state {
            case .mirroring:
                MirrorView(session: session)
                    .toolbar { PhoneToolbar(session: session) }
            case .connecting(let step):
                StatusView(symbol: nil, title: "Connecting to \(session.deviceName)", message: step)
            case .idle, .failed:
                ConnectView(devices: devices, session: session)
            }
        }
        .navigationTitle(session.isActive ? session.deviceName : AppConfig.name)
        .onAppear { devices.start() }
        .onChange(of: devices.devices) {
            // Unplugged mid-session: end it.
            let serials = Set(devices.devices.map(\.serial))
            if let serial = session.serial, session.isActive, !serials.contains(serial) { session.stop() }
        }
    }
}

struct PhoneToolbar: ToolbarContent {
    let session: MirrorSession

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { session.back() } label: { Label("Back", systemImage: "chevron.backward") }
                .help("Back (⌘[ or right-click)")
            Button { session.press(.home) } label: { Label("Home", systemImage: "circle") }
                .help("Home (⇧⌘H or middle-click)")
            Button { session.press(.appSwitch) } label: { Label("Recent Apps", systemImage: "square.on.square") }
                .help("Recent apps (⇧⌘A)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { session.soundMuted.toggle() } label: {
                Label(session.soundMuted ? "Unmute Phone Sound" : "Mute Phone Sound",
                      systemImage: session.soundMuted ? "speaker.slash" : "speaker")
            }
            .help("Mute or unmute the phone's sound on this Mac (⇧⌘M)")
            Button { session.press(.volumeDown) } label: { Label("Volume Down", systemImage: "speaker.wave.1") }
                .help("Volume down (⌘↓)")
            Button { session.press(.volumeUp) } label: { Label("Volume Up", systemImage: "speaker.wave.3") }
                .help("Volume up (⌘↑)")
            Button { session.send(.rotate) } label: { Label("Rotate", systemImage: "rotate.right") }
                .help("Rotate the phone (⌘R)")
            Button { session.setScreenOff(!session.screenOff) } label: {
                Label(session.screenOff ? "Turn Phone Screen On" : "Turn Phone Screen Off",
                      systemImage: session.screenOff ? "iphone.slash" : "iphone")
            }
            .help("Turn the phone's own screen off or on; mirroring continues (⇧⌘O)")
            Button { session.press(.power) } label: { Label("Power", systemImage: "power") }
                .help("Power button (⇧⌘P)")
        }
    }
}

/// A rounded, coloured square with a white symbol: the icon style of System Settings.
struct IconTile: View {
    let symbol: String
    var color: Color = .accentColor
    var size: CGFloat = 36

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol).font(.system(size: size * 0.54, weight: .medium)).foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// Everything before mirroring: a welcome, how to turn on USB debugging, what Zapmirror sees, and the Connect button.
struct ConnectView: View {
    let devices: DevicesModel
    let session: MirrorSession
    /// Why the last press of Connect couldn't start, until the next press.
    @State private var problem: String?

    var body: some View {
        if devices.availability == .adbMissing {
            StatusView(symbol: "wrench.and.screwdriver", title: "Zapmirror needs Android's platform tools",
                       message: "This early version uses Google's adb to reach your phone. Install it with Homebrew, then come back:",
                       command: "brew install --cask android-platform-tools")
        } else {
            // Scrolls only when the window is too short for the page.
            ViewThatFits(in: .vertical) {
                page
                ScrollView { page }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .onChange(of: devices.devices) { problem = nil }
        }
    }

    private var page: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(AppConfig.name).font(.system(size: 30, weight: .bold))
                Text("Your Android phone, on your Mac")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                feature("rectangle.on.rectangle", .blue, "See and control your phone",
                        "Click, drag, scroll and type. Sound plays on your Mac.")
                feature("doc.on.clipboard.fill", .purple, "Copy and paste across",
                        "⌘C and ⌘V work between the phone and your Mac.")
            }
            .frame(maxWidth: 420, alignment: .leading)

            // The heading sits on an accent-coloured ribbon so it catches the eye; the steps stay on a quiet panel.
            VStack(alignment: .leading, spacing: 0) {
                Label("First time? Turn on USB debugging once", systemImage: "cable.connector")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor)
                VStack(alignment: .leading, spacing: 11) {
                    step(1, "On the phone, open **Settings → About phone** and tap **Build number** seven times.")
                    step(2, "Go to **Settings → System → Developer options** and switch on **USB debugging**.")
                    step(3, "Plug the phone into this Mac with a USB cable and unlock it.")
                    step(4, "When the phone asks **Allow USB debugging?**, tick **Always allow from this computer** and tap **Allow**.")
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 456)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            statusLine
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.5), in: Capsule())
            if case .failed(let message) = session.state {
                Label("Mirroring stopped: \(message)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            connectButtons
            if let url = AppConfig.supportURL {
                Link(destination: url) {
                    Label("Zapmirror is free. If it helps you, buy me a coffee.", systemImage: "cup.and.saucer.fill")
                }
                .font(.callout)
            }
        }
        .padding(32)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    private func feature(_ symbol: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// What Zapmirror sees on USB right now.
    @ViewBuilder private var statusLine: some View {
        let ready = devices.ready
        if devices.availability == .starting {
            Label("Looking for phones…", systemImage: "hourglass").foregroundStyle(.secondary)
        } else if ready.count == 1 {
            Label("\(ready[0].name) is plugged in and ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if ready.count > 1 {
            Label("\(ready.count) phones are ready. Choose one below.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if let waiting = devices.devices.first(where: { $0.state == .unauthorized }) {
            Label("\(waiting.name) is waiting: tap **Allow** on the phone", systemImage: "hand.tap.fill")
                .foregroundStyle(.orange)
        } else if let other = devices.devices.first {
            Label("\(other.name) is plugged in but not ready yet. Unlock it.", systemImage: "clock")
                .foregroundStyle(.secondary)
        } else {
            Label("No phone with USB debugging found yet", systemImage: "smartphone").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var connectButtons: some View {
        let ready = devices.ready
        if ready.count > 1 {
            HStack {
                ForEach(ready) { device in
                    Button("Connect \(device.name)") { connect(device) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.extraLarge)
                }
            }
        } else {
            Button { connect(ready.first) } label: {
                Text("Connect").fontWeight(.semibold).frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
            .disabled(devices.availability == .starting)
        }
    }

    private func connect(_ device: AdbDevice?) {
        problem = nil
        if let device {
            session.start(device)
        } else if devices.devices.contains(where: { $0.state == .unauthorized }) {
            problem = "Your phone hasn't allowed this Mac yet. Tap Allow on the phone, then press Connect again."
        } else {
            problem = "Zapmirror can't find a phone with USB debugging on. Check the steps above, then press Connect again."
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct StatusView<Actions: View>: View {
    let symbol: String?
    let title: String
    let message: String
    var command: String?
    @ViewBuilder var actions: Actions

    init(symbol: String?, title: String, message: String, command: String? = nil, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.command = command
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 14) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.large)
            }
            Text(title).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            if !message.isEmpty {
                Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            if let command {
                Text(command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
            }
            actions
        }
        .frame(maxWidth: 460)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
