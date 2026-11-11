import Foundation

/// Build settings baked into Info.plist by Scripts/build-app.sh (Scripts/config.sh).
enum AppConfig {
    static let name = "Zapmirror"

    /// The optional "Buy Me a Coffee" link (SUPPORT_URL in Scripts/config.sh). Only https links are accepted; nil
    /// hides the Support items.
    static var supportURL: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "ZapmirrorSupportURL") as? String,
              text.hasPrefix("https://"), let url = URL(string: text), url.host != nil else { return nil }
        return url
    }
}
