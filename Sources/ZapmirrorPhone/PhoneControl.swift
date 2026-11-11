import Foundation

/// What the Mac asks the phone to do, sent on the control channel. Positions are fractions of the screen (0…1 from
/// the top-left), so they hold across rotations and video scaling.
public enum PhoneControl: Equatable, Sendable {
    public enum TouchAction: UInt8, Sendable { case down = 0, move = 1, up = 2 }
    public enum Panel: UInt8, Sendable { case notifications = 0, quickSettings = 1, close = 2 }

    case key(AndroidKeyAction, AndroidKeycode, meta: AndroidMetaState = [], repeat: UInt32 = 0)
    /// Typed on the phone; what its virtual keyboard can't type is pasted.
    case text(String)
    /// `finger` 0 is the mouse; 1 is a second finger, for pinching.
    case touch(TouchAction, finger: UInt8 = 0, x: Float, y: Float, pressure: Float = 1)
    /// Wheel notches: positive `horizontal` scrolls right, positive `vertical` up.
    case scroll(x: Float, y: Float, horizontal: Float, vertical: Float)
    /// Back, or wakes the phone if its screen is off.
    case backOrWake
    case panel(Panel)
    /// Copies (or cuts) the phone's selection; the text comes back as a clipboard message.
    case copy(cut: Bool)
    case setClipboard(String, paste: Bool)
    /// The phone's own screen; mirroring continues either way.
    case screenPower(on: Bool)
    /// Between portrait and landscape.
    case rotate

    static let maxTextBytes = 4_096
    static let maxClipboardBytes = 256 << 10

    public var frame: Frame {
        var out = PayloadWriter()
        let type: Character
        switch self {
        case .key(let action, let keycode, let meta, let repeatCount):
            type = "k"
            out.u8(action.rawValue)
            out.i32(keycode.rawValue)
            out.u32(meta.rawValue)
            out.u32(repeatCount)
        case .text(let text):
            type = "t"
            out.text(text, maxBytes: Self.maxTextBytes)
        case .touch(let action, let finger, let x, let y, let pressure):
            type = "p"
            out.u8(action.rawValue)
            out.u8(finger)
            out.f32(x)
            out.f32(y)
            out.f32(pressure)
        case .scroll(let x, let y, let horizontal, let vertical):
            type = "w"
            out.f32(x)
            out.f32(y)
            out.f32(horizontal)
            out.f32(vertical)
        case .backOrWake:
            type = "b"
        case .panel(let panel):
            type = "n"
            out.u8(panel.rawValue)
        case .copy(let cut):
            type = "g"
            out.u8(cut ? 1 : 0)
        case .setClipboard(let text, let paste):
            type = "s"
            out.u8(paste ? 1 : 0)
            out.text(text, maxBytes: Self.maxClipboardBytes)
        case .screenPower(let on):
            type = "d"
            out.u8(on ? 1 : 0)
        case .rotate:
            type = "r"
        }
        return Frame(type, out.data)
    }
}
