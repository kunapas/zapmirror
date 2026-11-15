import AppKit
import SwiftUI

/// Where screenshots and recordings are saved. Each has a standard folder (Pictures/Zapmirror, Movies/Zapmirror)
/// that the user can replace in Settings.
enum SaveLocation: String, CaseIterable, Identifiable {
    case screenshots, recordings

    var id: String { rawValue }

    /// The preference holding the user's folder; empty or missing means the standard one.
    var key: String { "\(rawValue)Folder" }

    var title: String {
        switch self {
        case .screenshots: "Screenshots"
        case .recordings: "Recordings"
        }
    }

    var standardFolder: URL {
        let directory: FileManager.SearchPathDirectory = self == .screenshots ? .picturesDirectory : .moviesDirectory
        return FileManager.default.urls(for: directory, in: .userDomainMask)[0]
            .appendingPathComponent(AppConfig.name, isDirectory: true)
    }

    /// The folder the user chose, if they chose one.
    var chosenFolder: URL? {
        guard let path = UserDefaults.standard.string(forKey: key), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Where to save now: the chosen folder while it exists, otherwise the standard one. A chosen folder on a disk
    /// that isn't connected mustn't lose the screenshot or recording.
    var folder: URL {
        if let chosen = chosenFolder {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: chosen.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return chosen
            }
        }
        return standardFolder
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            Section {
                ForEach(SaveLocation.allCases) { location in
                    SaveLocationRow(location: location)
                }
            } header: {
                Text("Save To")
            } footer: {
                Text("If a folder you chose isn't available, for example on a disk that's unplugged, Zapmirror saves to the standard folder instead.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SaveLocationRow: View {
    let location: SaveLocation
    @AppStorage private var path: String

    init(location: SaveLocation) {
        self.location = location
        _path = AppStorage(wrappedValue: "", location.key)
    }

    var body: some View {
        let custom = !path.isEmpty
        let shown = custom ? URL(fileURLWithPath: path, isDirectory: true) : location.standardFolder
        let missing = custom && !FileManager.default.fileExists(atPath: path)
        LabeledContent(location.title) {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: missing ? location.standardFolder.deletingLastPathComponent().path : shown.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    Text((shown.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(shown.path)
                }
                if missing {
                    Label("Not available right now", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 6) {
                    Button("Choose…") { choose(startingAt: shown) }
                    Button("Use Standard Folder") { path = "" }
                        .disabled(!custom)
                }
                .controlSize(.small)
            }
        }
    }

    private func choose(startingAt current: URL) {
        let panel = NSOpenPanel()
        panel.title = "Save \(location.title) To"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.fileExists(atPath: current.path) ? current : current.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}
