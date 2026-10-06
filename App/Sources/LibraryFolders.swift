import AppKit
import Foundation

/// Library folders the user picks once for all capture layouts. Saved defaults are security-scoped bookmarks, because
/// the App Store build is sandboxed and loses access to a plain path after relaunch.
enum LibraryFolder: String, CaseIterable {
    case originals
    case backup

    var title: String {
        switch self {
        case .originals: return "Target Folder"
        case .backup: return "Backup Storage"
        }
    }

    /// Shown after the title in the window, so the two main folders can't be confused.
    var caption: String? {
        self == .originals ? "where you want them put" : nil
    }

    var question: String {
        switch self {
        case .originals: return "Where do you want the sorted images put?"
        case .backup: return "Where is your Backup Storage location?"
        }
    }

    var detail: String {
        switch self {
        case .originals:
            return "Choose your Target Folder. Sorted images go into Targets {year}/{object} inside it, alongside any Targets {year} folders already there."
        case .backup:
            return "Choose where backups of your capture folders are stored before sorting (zip or tarball archives, or folder copies)."
        }
    }

    private var key: String { "SmartTelescopeSort.\(rawValue)Folder" }

    /// Defaults used to be saved per telescope type; the last-used type's copy wins.
    private var legacyKeys: [String] {
        let last = UserDefaults.standard.string(forKey: TelescopeKind.storageKey).flatMap(TelescopeKind.init(rawValue:))
        let kinds = (last.map { [$0] } ?? []) + TelescopeKind.allCases.filter { $0 != last }
        return kinds.map { "\(key).\($0.rawValue)" }
    }

    func saved() -> URL? {
        let defaults = UserDefaults.standard
        let legacy = defaults.data(forKey: key) == nil
        guard let data = defaults.data(forKey: key) ?? legacyKeys.lazy.compactMap(defaults.data(forKey:)).first else {
            return nil
        }
        var stale = false
        let url = (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: data, options: [], bookmarkDataIsStale: &stale))
        guard let url else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        if stale || legacy { save(url) }
        return url
    }

    func save(_ url: URL) {
        let data = (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        UserDefaults.standard.set(data, forKey: key)
    }

    func clearDefault() {
        UserDefaults.standard.removeObject(forKey: key)
        legacyKeys.forEach(UserDefaults.standard.removeObject(forKey:))
    }

    /// Opens a Finder folder picker asking this folder's question, with a "Save this as default" checkbox.
    @MainActor
    func ask(startingAt start: URL?) -> (url: URL, saveAsDefault: Bool)? {
        let panel = NSOpenPanel()
        panel.title = question
        panel.message = "\(question)\n\(detail)"
        panel.prompt = "Use This Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let start { panel.directoryURL = start }

        let checkbox = NSButton(checkboxWithTitle: "Save this as default", target: nil, action: nil)
        checkbox.state = .on
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 36))
        checkbox.frame = NSRect(x: 16, y: 8, width: 400, height: 20)
        accessory.addSubview(checkbox)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return (url, checkbox.state == .on)
    }
}
