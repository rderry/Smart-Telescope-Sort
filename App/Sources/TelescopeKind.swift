import Foundation

/// Smart-telescope family. User picks this so scanning matches how that brand
/// drops TIFF/FITS onto disk after USB / FTP / Wi‑Fi transfer.
enum TelescopeKind: String, CaseIterable, Identifiable, Codable {
    case vaonis
    case seestar
    case dwarf
    case origin

    var id: String { rawValue }

    /// Set by a single-brand build via Info.plist `STSLockedTelescope`.
    static var lockedFromBundle: TelescopeKind? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "STSLockedTelescope") as? String else {
            return nil
        }
        return TelescopeKind(rawValue: raw)
    }

    /// Finder name. No manufacturer or model names.
    var editionName: String {
        switch self {
        case .vaonis: return "Smart Telescope Sort — Dated Sessions"
        case .seestar: return "Smart Telescope Sort — Object Albums"
        case .dwarf: return "Smart Telescope Sort — Session Files"
        case .origin: return "Smart Telescope Sort — Object Date Folders"
        }
    }

    var layoutTitle: String {
        switch self {
        case .vaonis: return "Dated session folders"
        case .seestar: return "Object album folders"
        case .dwarf: return "Session folders"
        case .origin: return "Object and date folders"
        }
    }

    /// One nominative mention, only inside the app, with a non-affiliation statement.
    var compatibilityNote: String {
        switch self {
        case .vaonis:
            return "Reads dated session folders from Vespera and Stellina telescopes. Independent app. Not affiliated with or created by Vaonis."
        case .seestar:
            return "Reads object albums from S30, S30 Pro, and S50 telescopes. Independent app. Not affiliated with or created by ZWO."
        case .dwarf:
            return "Reads session folders from DWARF 3, II, and mini telescopes. Independent app. Not affiliated with or created by DWARFLAB."
        case .origin:
            return "Reads object-and-date folders from Origin Mark II telescopes. Independent app. Not affiliated with or created by Celestron."
        }
    }

    static let notAffiliated = "Telescope names identify folder layouts only. This app is not affiliated with or created by those manufacturers."

    var menuTitle: String { layoutTitle }

    /// First How It Works step: how this layout's files get into Captures.
    var dropHint: String {
        switch self {
        case .vaonis:
            return "Copy the telescope’s dated session folders into the Capture Folder."
        case .seestar:
            return "Copy object albums into the Capture Folder and keep FIT/FITS files inside each object folder."
        case .dwarf:
            return "Copy session folders into the Capture Folder and keep the FITS/TIFF files inside each session."
        case .origin:
            return "Copy raw folders named with the object and date into Captures. Turn on raw-image saving on the telescope first."
        }
    }

    static let storageKey = "SmartTelescopeSort.telescopeKind"

    /// The layout most capture folders under `root` follow, at any depth, or nil when none are recognisable.
    /// A recognised folder is not searched further; Targets {year} folders are skipped.
    static func detect(in root: URL, maxDepth: Int = 8) -> TelescopeKind? {
        var votes: [TelescopeKind: Int] = [:]
        var pending = [(folder: root, depth: 0)]
        while let (folder, depth) = pending.popLast() {
            for child in subfolders(of: folder) where !child.lastPathComponent.lowercased().hasPrefix("targets ") {
                if let kind = guess(child) {
                    votes[kind, default: 0] += 1
                } else if depth < maxDepth {
                    pending.append((child, depth + 1))
                }
            }
        }
        return votes.max { ($0.value, $1.key.rawValue) < ($1.value, $0.key.rawValue) }?.key
    }

    private static func guess(_ folder: URL) -> TelescopeKind? {
        let name = folder.lastPathComponent
        let lower = name.lowercased()
        if lower.contains("seestar") { return .seestar }
        if lower.contains("dwarf") { return .dwarf }
        if matches(name, #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_(observation|plan)[-_]"#) { return .vaonis }
        let kids = subfolders(of: folder).map(\.lastPathComponent)
        if kids.contains(where: { matches($0, #"^\d+-(observation|images)"#) }) { return .vaonis }
        let originPattern = #"^[A-Za-z][^_-]*(?:[_-][A-Za-z][^_-]*)*[_-]\d{4}-\d{2}-\d{2}"#
        if matches(name, originPattern) || kids.contains(where: { matches($0, originPattern) }) { return .origin }
        return nil
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func subfolders(of url: URL) -> [URL] {
        let kids = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return kids.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }
}
