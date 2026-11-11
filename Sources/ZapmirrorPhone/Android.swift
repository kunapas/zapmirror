/// Android input constants, as the phone component passes them to Android (android.view.KeyEvent).

public enum AndroidKeyAction: UInt8, Sendable {
    case down = 0, up = 1
}

public struct AndroidMetaState: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let shift = AndroidMetaState(rawValue: 0x01)
    public static let alt = AndroidMetaState(rawValue: 0x02)
    public static let shiftLeft = AndroidMetaState(rawValue: 0x40)
    public static let ctrl = AndroidMetaState(rawValue: 0x1000)
    public static let meta = AndroidMetaState(rawValue: 0x10000)
}

/// The keycodes Zapmirror sends. Letters and digits are only used with Ctrl; plain typing goes as text.
public struct AndroidKeycode: RawRepresentable, Equatable, Sendable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    public static let home = AndroidKeycode(rawValue: 3)
    public static let back = AndroidKeycode(rawValue: 4)
    public static let dpadUp = AndroidKeycode(rawValue: 19)
    public static let dpadDown = AndroidKeycode(rawValue: 20)
    public static let dpadLeft = AndroidKeycode(rawValue: 21)
    public static let dpadRight = AndroidKeycode(rawValue: 22)
    public static let volumeUp = AndroidKeycode(rawValue: 24)
    public static let volumeDown = AndroidKeycode(rawValue: 25)
    public static let power = AndroidKeycode(rawValue: 26)
    public static let tab = AndroidKeycode(rawValue: 61)
    public static let space = AndroidKeycode(rawValue: 62)
    public static let enter = AndroidKeycode(rawValue: 66)
    public static let del = AndroidKeycode(rawValue: 67)
    public static let menu = AndroidKeycode(rawValue: 82)
    public static let pageUp = AndroidKeycode(rawValue: 92)
    public static let pageDown = AndroidKeycode(rawValue: 93)
    public static let escape = AndroidKeycode(rawValue: 111)
    public static let forwardDel = AndroidKeycode(rawValue: 112)
    public static let moveHome = AndroidKeycode(rawValue: 122)
    public static let moveEnd = AndroidKeycode(rawValue: 123)
    public static let appSwitch = AndroidKeycode(rawValue: 187)

    /// A…Z are 29…54.
    public static func letter(_ c: Character) -> AndroidKeycode? {
        guard let ascii = c.lowercased().unicodeScalars.first?.value, (97...122).contains(ascii) else { return nil }
        return AndroidKeycode(rawValue: Int32(ascii) - 97 + 29)
    }

    /// 0…9 are 7…16.
    public static func digit(_ c: Character) -> AndroidKeycode? {
        guard let value = c.wholeNumberValue, c.isASCII else { return nil }
        return AndroidKeycode(rawValue: 7 + Int32(value))
    }
}
