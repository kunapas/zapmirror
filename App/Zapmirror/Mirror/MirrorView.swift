import AppKit
import AVFoundation
import SwiftUI
import ZapmirrorPhone

/// The phone's screen. Clicks and drags become touches, the wheel and trackpad scroll, typing goes to the phone.
struct MirrorView: NSViewRepresentable {
    let session: MirrorSession

    func makeNSView(context: Context) -> MirrorNSView {
        let view = MirrorNSView(session: session)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: MirrorNSView, context: Context) {
        view.videoSize = session.videoSize
    }
}

final class MirrorNSView: NSView {
    private let session: MirrorSession
    private let displayLayer: AVSampleBufferDisplayLayer
    /// Set when a session starts or the phone rotates; it sets the window's shape.
    var videoSize: CGSize? {
        didSet {
            guard videoSize != oldValue, let videoSize else { return }
            fitWindow(to: videoSize, firstFrame: oldValue == nil)
        }
    }
    private var dragging = false

    init(session: MirrorSession) {
        self.session = session
        displayLayer = session.renderer.layer
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = .black
        layer?.addSublayer(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    /// The part of the view the video fills (aspect fit).
    private var videoRect: CGRect {
        guard let size = videoSize, size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    /// Where a mouse event is on the phone's screen, as fractions from the top-left, clamped to the screen.
    private func position(of event: NSEvent) -> (x: Float, y: Float)? {
        guard videoSize != nil else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let rect = videoRect
        let x = (p.x - rect.minX) / rect.width
        let y = (rect.maxY - p.y) / rect.height // the view's origin is bottom-left
        return (Float(min(max(x, 0), 1)), Float(min(max(y, 0), 1)))
    }

    private func touch(_ action: PhoneControl.TouchAction, _ event: NSEvent) {
        guard let (x, y) = position(of: event) else { return }
        session.send(.touch(action, x: x, y: y, pressure: action == .up ? 0 : 1))
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard videoRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        dragging = true
        touch(.down, event)
    }

    override func mouseDragged(with event: NSEvent) {
        if dragging { touch(.move, event) }
    }

    override func mouseUp(with event: NSEvent) {
        if dragging { touch(.up, event) }
        dragging = false
    }

    /// Right-click is Back, the way a mouse's back button works on Android (it wakes the phone if its screen is off).
    override func rightMouseDown(with event: NSEvent) { session.back() }

    /// Middle-click is Home.
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { session.press(.home) }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let (x, y) = position(of: event) else { return }
        // Trackpads report fine-grained deltas; scale them to roughly wheel notches. A Mac delta moves the content,
        // Android's scroll axes move the view: the same sign vertically, the opposite horizontally.
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 0.1 : 1
        let horizontal = Float(-event.scrollingDeltaX * scale), vertical = Float(event.scrollingDeltaY * scale)
        guard horizontal != 0 || vertical != 0 else { return }
        session.send(.scroll(x: x, y: y, horizontal: max(-16, min(16, horizontal)), vertical: max(-16, min(16, vertical))))
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return super.keyDown(with: event) } // menu shortcuts
        if let keycode = Self.specialKeys[event.keyCode] {
            session.send(.key(.down, keycode, meta: Self.meta(flags), repeat: event.isARepeat ? 1 : 0))
            return
        }
        if flags.contains(.control), let c = event.charactersIgnoringModifiers?.first,
           let keycode = AndroidKeycode.letter(c) ?? AndroidKeycode.digit(c) {
            session.send(.key(.down, keycode, meta: Self.meta(flags)))
            return
        }
        if let text = event.characters, !text.isEmpty, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            session.send(.text(text))
        }
    }

    override func keyUp(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return super.keyUp(with: event) }
        if let keycode = Self.specialKeys[event.keyCode] {
            session.send(.key(.up, keycode, meta: Self.meta(flags)))
        } else if flags.contains(.control), let c = event.charactersIgnoringModifiers?.first,
                  let keycode = AndroidKeycode.letter(c) ?? AndroidKeycode.digit(c) {
            session.send(.key(.up, keycode, meta: Self.meta(flags)))
        }
    }

    /// Mac key codes for keys that aren't text.
    static let specialKeys: [UInt16: AndroidKeycode] = [
        36: .enter, 76: .enter, 51: .del, 117: .forwardDel, 48: .tab, 53: .escape,
        123: .dpadLeft, 124: .dpadRight, 125: .dpadDown, 126: .dpadUp,
        115: .moveHome, 119: .moveEnd, 116: .pageUp, 121: .pageDown,
    ]

    static func meta(_ flags: NSEvent.ModifierFlags) -> AndroidMetaState {
        var meta: AndroidMetaState = []
        if flags.contains(.shift) { meta.insert(.shift) }
        if flags.contains(.option) { meta.insert(.alt) }
        if flags.contains(.control) { meta.insert(.ctrl) }
        return meta
    }

    // MARK: - Edit menu: ⌘C, ⌘X, ⌘V and ⌘A act on the phone (Ctrl+C… on Android)

    @objc func copy(_ sender: Any?) { session.copyOnPhone() }
    @objc func cut(_ sender: Any?) { session.copyOnPhone(cut: true) }
    @objc func paste(_ sender: Any?) { session.pasteFromMac() }
    @objc override func selectAll(_ sender: Any?) { session.press(AndroidKeycode.letter("a")!, meta: .ctrl) }

    // MARK: - Window

    /// Sizes the window to the phone's shape: on the first frame to most of the screen's height, after a rotation
    /// keeping roughly the same area.
    private func fitWindow(to size: CGSize, firstFrame: Bool) {
        guard let window, let screen = window.screen?.visibleFrame else { return }
        let chrome = window.frame.height - bounds.height
        let maxContent = CGSize(width: screen.width * 0.9, height: screen.height * 0.9 - chrome)
        let current = bounds.size
        let target: CGSize
        if firstFrame || current.width < 50 {
            let scale = min(maxContent.width / size.width, maxContent.height / size.height, 1)
            target = CGSize(width: size.width * scale, height: size.height * scale)
        } else {
            let longest = max(current.width, current.height)
            let scale = min(longest / max(size.width, size.height), maxContent.width / size.width, maxContent.height / size.height)
            target = CGSize(width: size.width * scale, height: size.height * scale)
        }
        var frame = window.frame
        frame.size = CGSize(width: max(target.width, 320), height: target.height + chrome)
        frame.origin.y = window.frame.maxY - frame.height
        frame.origin.x = min(max(frame.origin.x, screen.minX), screen.maxX - frame.width)
        if frame.minY < screen.minY { frame.origin.y = screen.minY }
        window.setFrame(frame, display: true, animate: !firstFrame)
    }
}
