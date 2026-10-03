import Foundation

struct CaptureEntry: Identifiable, Hashable {
    var id: String { "\(captureFolder)|\(object)|\(year)-\(month)" }
    var captureFolder: String
    var year: String
    var month: String
    var object: String
    var imageFolders: Int
    var files: Int
    var formats: [String]
    var targetDirectory: URL
    var targetExists: Bool
    var sourceFiles: [URL]
}

struct SortPlanItem: Identifiable {
    var id: String { source.path }
    var source: URL
    var destination: URL
    var action: Action
    var entryID: String
    var captureFolder: String
    var object: String
    var targetFolder: String
    var date: Date

    enum Action: String {
        /// New to Targets.
        case move
        /// Newer than the copy in Targets.
        case replace
        /// Same name and size as the copy already in Targets.
        case duplicate
        /// Already in Targets as a different, newer file.
        case older

        var label: String {
            switch self {
            case .move: return "New"
            case .replace: return "Replaces older"
            case .duplicate: return "Duplicate"
            case .older: return "Older copy"
            }
        }
    }

    /// Already in Targets; never moved, only deleted when the user says yes.
    var isDuplicate: Bool { action == .duplicate || action == .older }
}

struct SortSummary {
    var move = 0
    var replace = 0
    var duplicate = 0
    var older = 0
    var createTargets: [String] = []
    var removedFolders = 0

    var duplicates: Int { duplicate + older }
}

/// Image types the user can choose to sort.
enum SortFileType: String, CaseIterable, Identifiable {
    case tiff, jpeg, fits

    static let defaults: [SortFileType] = [.tiff, .fits]

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tiff: return "TIFF"
        case .jpeg: return "JPG / JPEG"
        case .fits: return "FITS / FIT"
        }
    }

    var extensions: Set<String> {
        switch self {
        case .tiff: return ["tif", "tiff"]
        case .jpeg: return ["jpg", "jpeg"]
        case .fits: return ["fit", "fits"]
        }
    }
}

/// Archive formats for the backup made before a sort.
enum BackupFormat: String, CaseIterable, Identifiable {
    case zip, tarball

    var id: String { rawValue }

    var label: String {
        switch self {
        case .zip: return "Zip"
        case .tarball: return "Tarball"
        }
    }

    var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .tarball: return "tar.gz"
        }
    }

    /// The archiver that ships with macOS (libarchive's bsdtar on the sealed system volume); nothing to install.
    static let systemArchiver = URL(fileURLWithPath: "/usr/bin/tar")

    static var systemArchiverAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: systemArchiver.path)
    }
}

/// Free Mac apps that build zip and tarball archives, offered if the built-in archiver can't be used.
struct ArchiveProgress: Sendable {
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var filesDone = 0
    var filesTotal = 0
    var currentFile = ""

    var fraction: Double { bytesTotal > 0 ? min(Double(bytesDone) / Double(bytesTotal), 1) : 0 }
}

/// Lets the UI stop a running archive; the partial archive is deleted.
final class ArchiveJob: @unchecked Sendable {
    struct Cancelled: Error {}

    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    /// False when Cancel was pressed before the archiver started.
    func attach(_ process: Process) -> Bool {
        lock.withLock {
            self.process = process
            return !cancelled
        }
    }

    func cancel() {
        let running = lock.withLock {
            cancelled = true
            return process
        }
        if running?.isRunning == true { running?.terminate() }
    }
}

enum ArchiverLinks {
    static let all: [(title: String, url: URL)] = [
        ("Keka (free zip & tarball)", URL(string: "https://www.keka.io/en/")!),
        ("PeaZip (free, open source)", URL(string: "https://peazip.github.io/peazip-macos.html")!),
        ("Finder Compress (built-in zip)", URL(string: "https://support.apple.com/guide/mac-help/zip-and-unzip-files-and-folders-on-mac-mchlp2528/mac")!),
    ]
}

struct DuplicateCleanup {
    var deleted = 0
    var skipped = 0
    var removedFolders = 0
}

struct BackupSummary {
    var folders = 0
    var files = 0
    var destination: URL
}

enum CaptureSorter {
    static let defaultSource = URL(fileURLWithPath: "/Volumes/Astronomy/Captures")
    /// Extensions the next scan sorts; set from the file-type checkboxes.
    static var sortExtensions: Set<String> = SortFileType.defaults.reduce(into: []) { $0.formUnion($1.extensions) }
    /// Any of these left in a capture folder keeps it from being deleted, whether or not its type is being sorted.
    private static let keepFolderExtensions: Set<String> = ["tif", "tiff", "fit", "fits", "jpg", "jpeg", "png"]

    // Vaonis / Singularity
    private static let datedCapture = try! NSRegularExpression(pattern: #"^(\d{4})-(\d{2})-"#)
    private static let observation = try! NSRegularExpression(
        pattern: #"^(?:\d+-)?observation[-_](.+)$"#,
        options: .caseInsensitive
    )
    private static let datedObservationCapture = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_observation[-_](.+)$"#,
        options: .caseInsensitive
    )
    private static let imagesFolder = try! NSRegularExpression(
        pattern: #"^(?:\d+-)?images(?:[-_].+)?$"#,
        options: .caseInsensitive
    )

    // Origin: M31_2024-06-15 or M31-2024-06-15
    private static let originDatedObject = try! NSRegularExpression(
        pattern: #"^(.+?)[_-](\d{4})-(\d{2})-(\d{2})(?:$|[_-].*)"#,
        options: .caseInsensitive
    )
    // Generic leading date YYYY-MM-DD or YYYYMMDD
    private static let leadingISODate = try! NSRegularExpression(
        pattern: #"^(\d{4})-(\d{2})-(\d{2})"#
    )
    private static let leadingCompactDate = try! NSRegularExpression(
        pattern: #"^(\d{4})(\d{2})(\d{2})(?:[_-].*)?$"#
    )

    static func scan(
        kind: TelescopeKind,
        sourceRoot: URL = defaultSource,
        targetsRoot: URL? = nil,
        year: String? = nil,
        month: String? = nil
    ) throws -> (entries: [CaptureEntry], years: [String], excluded: String) {
        let targets = targetsRoot ?? sourceRoot
        switch kind {
        case .vaonis:
            return try scanVaonis(sourceRoot: sourceRoot, targetsRoot: targets, year: year, month: month)
        case .seestar, .dwarf, .origin:
            return try scanGenericSessions(kind: kind, sourceRoot: sourceRoot, targetsRoot: targets, year: year, month: month)
        }
    }

    // MARK: - Vaonis (existing rules)

    private static func scanVaonis(
        sourceRoot: URL,
        targetsRoot: URL,
        year: String?,
        month: String?
    ) throws -> (entries: [CaptureEntry], years: [String], excluded: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceRoot.path) else {
            return ([], [], "Targets …")
        }

        var entries: [CaptureEntry] = []
        var years = Set<String>()
        let children = try fm.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for capture in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: capture.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let name = capture.lastPathComponent
            if name.lowercased().hasPrefix("targets ") { continue }

            guard let match = firstMatch(datedCapture, in: name) else { continue }
            let captureYear = substring(match.range(at: 1), in: name)
            let captureMonth = substring(match.range(at: 2), in: name)
            guard !captureYear.isEmpty, !captureMonth.isEmpty else { continue }
            years.insert(captureYear)
            if let year, year != "all", captureYear != year { continue }
            if let month, month != "all", captureMonth != month { continue }

            var byObject: [String: (folders: Int, files: [URL])] = [:]
            for (observationURL, objectName) in observationFolders(in: capture) {
                let imageDirs = imagesFolders(under: observationURL)
                let files = imageFiles(from: imageDirs, alsoUnder: observationURL)
                let prior = byObject[objectName] ?? (0, [])
                let folderCount = max(imageDirs.count, 1)
                byObject[objectName] = (prior.folders + folderCount, prior.files + files)
            }

            let targetRoot = targetsRoot.appendingPathComponent("Targets \(captureYear)", isDirectory: true)
            var targetIsDir: ObjCBool = false
            let targetExists = fm.fileExists(atPath: targetRoot.path, isDirectory: &targetIsDir) && targetIsDir.boolValue

            for (objectName, bundle) in byObject.sorted(by: { $0.key < $1.key }) {
                let uniqueFiles = dedupeFiles(bundle.files)
                entries.append(
                    CaptureEntry(
                        captureFolder: name,
                        year: captureYear,
                        month: captureMonth,
                        object: objectName,
                        imageFolders: bundle.folders,
                        files: uniqueFiles.count,
                        formats: formats(of: uniqueFiles),
                        targetDirectory: targetRoot.appendingPathComponent(objectName, isDirectory: true),
                        targetExists: targetExists,
                        sourceFiles: uniqueFiles
                    )
                )
            }
        }

        entries.sort {
            ($0.year, $0.month, $0.captureFolder, $0.object) < ($1.year, $1.month, $1.captureFolder, $1.object)
        }
        return (entries, years.sorted(by: >), "Targets …")
    }

    // MARK: - Seestar / DWARF / Origin

    /// Top-level session/object folders under Captures. Year/month from folder name
    /// when possible, otherwise from newest TIFF/FITS modification date.
    private static func scanGenericSessions(
        kind: TelescopeKind,
        sourceRoot: URL,
        targetsRoot: URL,
        year: String?,
        month: String?
    ) throws -> (entries: [CaptureEntry], years: [String], excluded: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceRoot.path) else {
            return ([], [], "Targets …")
        }

        var entries: [CaptureEntry] = []
        var years = Set<String>()
        let children = try fm.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for capture in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: capture.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let name = capture.lastPathComponent
            if name.lowercased().hasPrefix("targets ") { continue }

            let groups = sessionObjectGroups(kind: kind, captureRoot: capture)
            guard !groups.isEmpty else { continue }

            for group in groups {
                let (y, m) = yearMonth(for: group, captureName: name, kind: kind)
                years.insert(y)
                if let year, year != "all", y != year { continue }
                if let month, month != "all", m != month { continue }

                let uniqueFiles = dedupeFiles(group.files)

                let targetRoot = targetsRoot.appendingPathComponent("Targets \(y)", isDirectory: true)
                var targetIsDir: ObjCBool = false
                let targetExists = fm.fileExists(atPath: targetRoot.path, isDirectory: &targetIsDir) && targetIsDir.boolValue

                entries.append(
                    CaptureEntry(
                        captureFolder: name,
                        year: y,
                        month: m,
                        object: group.object,
                        imageFolders: group.imageFolders,
                        files: uniqueFiles.count,
                        formats: formats(of: uniqueFiles),
                        targetDirectory: targetRoot.appendingPathComponent(group.object, isDirectory: true),
                        targetExists: targetExists,
                        sourceFiles: uniqueFiles
                    )
                )
            }
        }

        entries.sort {
            ($0.year, $0.month, $0.captureFolder, $0.object) < ($1.year, $1.month, $1.captureFolder, $1.object)
        }
        return (entries, years.sorted(by: >), "Targets …")
    }

    private struct SessionGroup {
        var object: String
        var files: [URL]
        var imageFolders: Int
        var hintYear: String?
        var hintMonth: String?
    }

    private static func sessionObjectGroups(kind: TelescopeKind, captureRoot: URL) -> [SessionGroup] {
        switch kind {
        case .vaonis:
            return []
        case .origin:
            return originGroups(captureRoot: captureRoot)
        case .seestar:
            return seestarGroups(captureRoot: captureRoot)
        case .dwarf:
            return dwarfGroups(captureRoot: captureRoot)
        }
    }

    /// Origin: folder often `Object_YYYY-MM-DD` (or nested). All FITS under that folder → one DSO.
    private static func originGroups(captureRoot: URL) -> [SessionGroup] {
        let name = captureRoot.lastPathComponent
        if let match = firstMatch(originDatedObject, in: name) {
            let object = dsoName(substring(match.range(at: 1), in: name))
            let y = substring(match.range(at: 2), in: name)
            let m = substring(match.range(at: 3), in: name)
            let files = imageFiles(under: captureRoot)
            guard !object.isEmpty else { return [] }
            return [SessionGroup(object: object, files: files, imageFolders: 1, hintYear: y, hintMonth: m)]
        }
        // Nested object+date folders one level down
        var groups: [SessionGroup] = []
        let kids = (try? FileManager.default.contentsOfDirectory(
            at: captureRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for kid in kids {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: kid.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let leaf = kid.lastPathComponent
            if let match = firstMatch(originDatedObject, in: leaf) {
                let object = dsoName(substring(match.range(at: 1), in: leaf))
                let y = substring(match.range(at: 2), in: leaf)
                let m = substring(match.range(at: 3), in: leaf)
                let files = imageFiles(under: kid)
                if !object.isEmpty {
                    groups.append(SessionGroup(object: object, files: files, imageFolders: 1, hintYear: y, hintMonth: m))
                }
            }
        }
        if !groups.isEmpty { return groups }

        // Fallback: whole tree as one object named from folder
        let files = imageFiles(under: captureRoot)
        guard !files.isEmpty else { return [] }
        return [SessionGroup(object: dsoName(stripVendorNoise(name)), files: files, imageFolders: 1, hintYear: nil, hintMonth: nil)]
    }

    /// Seestar: object albums (M31, NGC7023) or a dump of FIT files under one transfer folder.
    private static func seestarGroups(captureRoot: URL) -> [SessionGroup] {
        let name = captureRoot.lastPathComponent
        let kids = (try? FileManager.default.contentsOfDirectory(
            at: captureRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var subDirs: [URL] = []
        var loose: [URL] = []
        for kid in kids {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: kid.path, isDirectory: &isDir), isDir.boolValue {
                let lower = kid.lastPathComponent.lowercased()
                // Skip Seestar UI noise folders if present
                if lower == "thumbnail" || lower == "thumbnails" || lower.hasSuffix("_thumbnail") { continue }
                subDirs.append(kid)
            } else if sortExtensions.contains(kid.pathExtension.lowercased()) {
                loose.append(kid)
            }
        }

        // If children look like object albums, one group per child that has images.
        let albumGroups: [SessionGroup] = subDirs.compactMap { dir in
            let files = imageFiles(under: dir)
            guard !files.isEmpty else { return nil }
            let object = dsoName(stripVendorNoise(dir.lastPathComponent))
            guard !object.isEmpty else { return nil }
            let (hy, hm) = dateHints(fromFolderName: dir.lastPathComponent)
            return SessionGroup(object: object, files: files, imageFolders: 1, hintYear: hy, hintMonth: hm)
        }
        if albumGroups.count >= 1, loose.isEmpty {
            return albumGroups
        }
        if !albumGroups.isEmpty, !loose.isEmpty {
            // Mixed: albums + loose at root → albums + one UNKNOWN for loose
            var all = albumGroups
            if !loose.isEmpty {
                let (hy, hm) = dateHints(fromFolderName: name)
                all.append(SessionGroup(object: dsoName(stripVendorNoise(name)), files: loose, imageFolders: 1, hintYear: hy, hintMonth: hm))
            }
            return all
        }

        let files = imageFiles(under: captureRoot)
        guard !files.isEmpty else { return [] }
        let (hy, hm) = dateHints(fromFolderName: name)
        return [SessionGroup(object: dsoName(stripVendorNoise(name)), files: files, imageFolders: max(subDirs.count, 1), hintYear: hy, hintMonth: hm)]
    }

    /// DWARF: each top-level transfer is usually one session; object from folder name.
    private static func dwarfGroups(captureRoot: URL) -> [SessionGroup] {
        let name = captureRoot.lastPathComponent
        let files = imageFiles(under: captureRoot)
        guard !files.isEmpty else { return [] }
        let (hy, hm) = dateHints(fromFolderName: name)
        // Prefer a nested folder that looks like an object if the root is only a date stamp
        if looksLikeDateOnly(name) {
            let kids = (try? FileManager.default.contentsOfDirectory(
                at: captureRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            var nested: [SessionGroup] = []
            for kid in kids {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: kid.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let nestedFiles = imageFiles(under: kid)
                guard !nestedFiles.isEmpty else { continue }
                let object = dsoName(stripVendorNoise(kid.lastPathComponent))
                guard !object.isEmpty, !looksLikeDateOnly(kid.lastPathComponent) else { continue }
                nested.append(SessionGroup(object: object, files: nestedFiles, imageFolders: 1, hintYear: hy, hintMonth: hm))
            }
            if !nested.isEmpty { return nested }
        }
        return [SessionGroup(object: dsoName(stripVendorNoise(name)), files: files, imageFolders: 1, hintYear: hy, hintMonth: hm)]
    }

    private static func yearMonth(for group: SessionGroup, captureName: String, kind: TelescopeKind) -> (String, String) {
        if let y = group.hintYear, let m = group.hintMonth, y.count == 4, m.count == 2 {
            return (y, m)
        }
        let (hy, hm) = dateHints(fromFolderName: captureName)
        if let hy, let hm { return (hy, hm) }

        // Newest image mtime
        var newest = Date.distantPast
        for url in group.files {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if date > newest { newest = date }
        }
        if newest == .distantPast { newest = Date() }
        let cal = Calendar.current
        let y = String(cal.component(.year, from: newest))
        let m = String(format: "%02d", cal.component(.month, from: newest))
        _ = kind
        return (y, m)
    }

    private static func dateHints(fromFolderName name: String) -> (String?, String?) {
        if let match = firstMatch(leadingISODate, in: name) {
            return (substring(match.range(at: 1), in: name), substring(match.range(at: 2), in: name))
        }
        if let match = firstMatch(leadingCompactDate, in: name) {
            return (substring(match.range(at: 1), in: name), substring(match.range(at: 2), in: name))
        }
        if let match = firstMatch(originDatedObject, in: name) {
            return (substring(match.range(at: 2), in: name), substring(match.range(at: 3), in: name))
        }
        return (nil, nil)
    }

    private static func looksLikeDateOnly(_ name: String) -> Bool {
        if firstMatch(leadingCompactDate, in: name) != nil { return true }
        if firstMatch(leadingISODate, in: name) != nil,
           name.count <= 12 { return true }
        return false
    }

    private static func stripVendorNoise(_ raw: String) -> String {
        var s = raw
        let prefixes = ["seestar_", "seestar-", "dwarf_", "dwarf-", "dwarf3_", "origin_", "origin-"]
        let lower = s.lowercased()
        for p in prefixes where lower.hasPrefix(p) {
            s = String(s.dropFirst(p.count))
            break
        }
        // Drop trailing _stacked / _fit noise
        if let r = s.range(of: #"(?i)[_-](stacked|stack|fit|fits|tiff?)$"#, options: .regularExpression) {
            s.removeSubrange(r)
        }
        return s
    }

    // MARK: - Shared sort / backup / cleanup (unchanged behavior)

    static func preview(entries: [CaptureEntry]) -> (plans: [SortPlanItem], summary: SortSummary) {
        var plans: [SortPlanItem] = []
        var summary = SortSummary()
        summary.createTargets = Array(Set(entries.filter { !$0.targetExists }.map(\.year))).sorted()

        var bestByDestination: [String: (source: URL, destination: URL, entry: CaptureEntry)] = [:]
        for entry in entries {
            for source in entry.sourceFiles {
                let destination = entry.targetDirectory.appendingPathComponent(source.lastPathComponent)
                let key = destination.standardizedFileURL.path
                if let existing = bestByDestination[key] {
                    if modified(source) > modified(existing.source) {
                        bestByDestination[key] = (source, destination, entry)
                    }
                } else {
                    bestByDestination[key] = (source, destination, entry)
                }
            }
        }

        for item in bestByDestination.values.sorted(by: { $0.destination.path < $1.destination.path }) {
            let action = classify(source: item.source, destination: item.destination)
            switch action {
            case .move: summary.move += 1
            case .replace: summary.replace += 1
            case .duplicate: summary.duplicate += 1
            case .older: summary.older += 1
            }
            plans.append(SortPlanItem(
                source: item.source,
                destination: item.destination,
                action: action,
                entryID: item.entry.id,
                captureFolder: item.entry.captureFolder,
                object: item.entry.object,
                targetFolder: "Targets \(item.entry.year)/\(item.entry.object)",
                date: modified(item.source)
            ))
        }
        plans.sort {
            ($0.captureFolder, $0.object, $0.source.lastPathComponent) < ($1.captureFolder, $1.object, $1.source.lastPathComponent)
        }
        return (plans, summary)
    }

    private static func classify(source: URL, destination: URL) -> SortPlanItem.Action {
        guard FileManager.default.fileExists(atPath: destination.path) else { return .move }
        if modified(source) > modified(destination) { return .replace }
        return size(source) == size(destination) ? .duplicate : .older
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
    }

    /// Deletes source files that are already in Targets (moved to the Trash when the volume allows it), then
    /// removes capture folders left with no TIFF/FITS. Each file is re-checked against its Targets copy first.
    static func deleteDuplicates(_ items: [SortPlanItem], sourceRoot: URL) -> DuplicateCleanup {
        let fm = FileManager.default
        var result = DuplicateCleanup()
        for item in items where item.isDuplicate {
            guard fm.fileExists(atPath: item.source.path),
                  fm.fileExists(atPath: item.destination.path),
                  classify(source: item.source, destination: item.destination) == item.action else {
                result.skipped += 1
                continue
            }
            do {
                do {
                    try fm.trashItem(at: item.source, resultingItemURL: nil)
                } catch {
                    try fm.removeItem(at: item.source)
                }
                result.deleted += 1
            } catch {
                result.skipped += 1
            }
        }
        result.removedFolders = removeSpentCaptureFolders(
            captureNames: Array(Set(items.filter(\.isDuplicate).map(\.captureFolder))),
            sourceRoot: sourceRoot.standardizedFileURL
        )
        return result
    }

    @discardableResult
    static func createTargetsFolder(year: String, targetsRoot: URL = defaultSource) throws -> URL {
        guard year.range(of: #"^\d{4}$"#, options: .regularExpression) != nil else {
            throw NSError(domain: "SmartTelescopeSort", code: 1, userInfo: [NSLocalizedDescriptionKey: "A target year must be four digits."])
        }
        let target = targetsRoot.appendingPathComponent("Targets \(year)", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    static func performSort(entries: [CaptureEntry], sourceRoot: URL = defaultSource, targetsRoot: URL? = nil) throws -> SortSummary {
        let (plans, summary) = preview(entries: entries)
        for year in summary.createTargets {
            try createTargetsFolder(year: year, targetsRoot: targetsRoot ?? sourceRoot)
        }
        var result = SortSummary(duplicate: summary.duplicate, older: summary.older, createTargets: summary.createTargets)
        let fm = FileManager.default
        for item in plans where !item.isDuplicate {
            try fm.createDirectory(at: item.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch item.action {
            case .duplicate, .older:
                continue
            case .replace:
                _ = try fm.replaceItemAt(item.destination, withItemAt: item.source)
                result.replace += 1
            case .move:
                try fm.moveItem(at: item.source, to: item.destination)
                result.move += 1
            }
        }
        result.removedFolders = removeSpentCaptureFolders(
            captureNames: Array(Set(entries.map(\.captureFolder))),
            sourceRoot: sourceRoot.standardizedFileURL
        )
        return result
    }

    static var defaultBackupName: String {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        stamp.timeZone = .current
        return "SmartTelescopeSort-Backup-\(stamp.string(from: Date()).replacingOccurrences(of: ":", with: "-"))"
    }

    /// A name the user typed, made safe for a file name (no slashes, colons or archive extension); blank gives the default.
    static func backupBaseName(_ requested: String?) -> String {
        var name = (requested ?? "")
            .replacingOccurrences(of: #"[/:\\]"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [".tar.gz", ".tgz", ".zip"] where name.lowercased().hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return name.isEmpty ? defaultBackupName : String(name.prefix(200))
    }

    /// `base` plus `ext` in `parent`, numbered " 2", " 3"… when that name is taken.
    static func unusedURL(in parent: URL, base: String, extension ext: String?) -> URL {
        let suffix = ext.map { ".\($0)" } ?? ""
        var candidate = parent.appendingPathComponent(base + suffix)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base) \(number)\(suffix)")
            number += 1
        }
        return candidate
    }

    static func backupCaptureFolders(
        entries: [CaptureEntry],
        sourceRoot: URL,
        destinationParent: URL,
        name: String? = nil
    ) throws -> BackupSummary {
        let fm = FileManager.default
        let destination = unusedURL(in: destinationParent, base: backupBaseName(name), extension: nil)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var folders = 0
        var files = 0
        let names = Array(Set(entries.map(\.captureFolder))).sorted()
        for name in names {
            if name.lowercased().hasPrefix("targets ") { continue }
            let source = sourceRoot.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let target = destination.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.copyItem(at: source, to: target)
            folders += 1
            files += imageFiles(under: target, extensions: keepFolderExtensions).count
        }
        return BackupSummary(folders: folders, files: files, destination: destination)
    }

    /// Writes a zip or tarball holding the named capture folders with the archiver built into macOS.
    /// Returns the archive, or nil when there was nothing to back up.
    static func archiveCaptureFolders(
        names: [String],
        sourceRoot: URL,
        destinationParent: URL,
        format: BackupFormat,
        name: String? = nil,
        job: ArchiveJob? = nil,
        progress: (@Sendable (ArchiveProgress) -> Void)? = nil
    ) throws -> URL? {
        let fm = FileManager.default
        let folders = Array(Set(names)).sorted().filter { name in
            var isDir: ObjCBool = false
            return !name.lowercased().hasPrefix("targets ")
                && fm.fileExists(atPath: sourceRoot.appendingPathComponent(name).path, isDirectory: &isDir)
                && isDir.boolValue
        }
        guard !folders.isEmpty else { return nil }
        let archive = unusedURL(in: destinationParent, base: backupBaseName(name), extension: format.fileExtension)

        let rootPath = sourceRoot.standardizedFileURL.path + "/"
        var sizes: [String: Int64] = [:]
        for name in folders {
            let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
            guard let walk = fm.enumerator(at: sourceRoot.appendingPathComponent(name), includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in walk {
                let leaf = url.lastPathComponent
                guard !leaf.hasPrefix("._"), leaf != ".DS_Store",
                      let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                sizes[String(url.standardizedFileURL.path.dropFirst(rootPath.count))] = Int64(values.fileSize ?? 0)
            }
        }
        var state = ArchiveProgress(bytesTotal: sizes.values.reduce(0, +), filesTotal: sizes.count)
        progress?(state)

        // Level 1 is about ten times faster than the default on FITS for roughly 30% larger archives.
        let tar = Process()
        tar.executableURL = BackupFormat.systemArchiver
        tar.arguments = (format == .zip
                ? ["--format", "zip", "--options", "zip:compression-level=1", "-cvf"]
                : ["--options", "gzip:compression-level=1", "-cvzf"])
            + [archive.path, "--exclude", "._*", "--exclude", ".DS_Store", "-C", sourceRoot.path]
            + folders.map { $0.hasPrefix("-") ? "./\($0)" : $0 }
        tar.environment = ["COPYFILE_DISABLE": "1"]
        let errors = Pipe()
        tar.standardError = errors
        tar.standardOutput = FileHandle.nullDevice
        guard job?.attach(tar) ?? true else { throw ArchiveJob.Cancelled() }
        try tar.run()
        if job?.isCancelled == true { tar.terminate() }

        // tar names each entry as it starts writing it, so a file counts as done when the next one starts.
        var messages: [String] = []
        var pending = Data()
        var writing: Int64?
        func finishWriting() {
            guard let size = writing else { return }
            state.bytesDone += size
            state.filesDone += 1
            writing = nil
        }
        let reader = errors.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                guard line.hasPrefix("a ") else { messages.append(line); continue }
                var path = String(line.dropFirst(2))
                if path.hasPrefix("./") { path.removeFirst(2) }
                guard let size = sizes[path] else { continue }
                finishWriting()
                writing = size
                state.currentFile = path
                progress?(state)
            }
        }
        tar.waitUntilExit()
        finishWriting()
        progress?(state)
        if job?.isCancelled == true {
            try? fm.removeItem(at: archive)
            throw ArchiveJob.Cancelled()
        }
        guard tar.terminationStatus == 0 else {
            try? fm.removeItem(at: archive)
            throw NSError(domain: "SmartTelescopeSort", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(format.label) backup failed: \(messages.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines))"
            ])
        }
        return archive
    }

    /// Sends whole capture folders to the Trash (removing them if the volume has none), images and all.
    static func trashCaptureFolders(names: [String], sourceRoot: URL) -> Int {
        let fm = FileManager.default
        var removed = 0
        for name in Set(names) where !name.isEmpty && !name.lowercased().hasPrefix("targets ") && !name.contains("/") {
            let folder = sourceRoot.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: folder.path) else { continue }
            do {
                try fm.trashItem(at: folder, resultingItemURL: nil)
                removed += 1
            } catch {
                if (try? fm.removeItem(at: folder)) != nil { removed += 1 }
            }
        }
        return removed
    }

    /// Image files still inside each capture folder that survived a sort, counted by lowercased extension.
    static func leftoverImages(captureNames: [String], sourceRoot: URL) -> [String: [String: Int]] {
        var kept: [String: [String: Int]] = [:]
        for name in Set(captureNames) where !name.lowercased().hasPrefix("targets ") {
            let files = imageFiles(under: sourceRoot.appendingPathComponent(name, isDirectory: true), extensions: keepFolderExtensions)
            guard !files.isEmpty else { continue }
            kept[name] = files.reduce(into: [:]) { $0[$1.pathExtension.lowercased(), default: 0] += 1 }
        }
        return kept
    }

    /// True while any TIFF, FITS, JPG or PNG is left under the folder, sorted type or not.
    static func holdsImages(_ folder: URL) -> Bool {
        !imageFiles(under: folder, extensions: keepFolderExtensions).isEmpty
    }

    @discardableResult
    static func removeSpentCaptureFolders(captureNames: [String], sourceRoot: URL) -> Int {
        let fm = FileManager.default
        var removed = 0
        for name in captureNames.sorted() {
            let lower = name.lowercased()
            if lower.hasPrefix("targets ") { continue }
            let capture = sourceRoot.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: capture.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if holdsImages(capture) { continue }
            do {
                try fm.removeItem(at: capture)
                removed += 1
            } catch {
                continue
            }
        }
        return removed
    }

    // MARK: - Vaonis helpers

    private static func observationFolders(in captureFolder: URL) -> [(URL, String)] {
        var result: [(URL, String)] = []
        let captureName = captureFolder.lastPathComponent

        if let match = firstMatch(datedObservationCapture, in: captureName) {
            result.append((captureFolder, dsoName(substring(match.range(at: 1), in: captureName))))
        } else if let match = firstMatch(observation, in: captureName) {
            result.append((captureFolder, dsoName(substring(match.range(at: 1), in: captureName))))
        }

        guard let enumerator = FileManager.default.enumerator(
            at: captureFolder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return result }

        for case let url as URL in enumerator {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let name = url.lastPathComponent
            if let match = firstMatch(observation, in: name) {
                result.append((url, dsoName(substring(match.range(at: 1), in: name))))
            }
        }
        return result
    }

    private static func imagesFolders(under observationFolder: URL) -> [URL] {
        var folders: [URL] = []
        let observationPath = observationFolder.standardizedFileURL.path

        guard let enumerator = FileManager.default.enumerator(
            at: observationFolder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let url as URL in enumerator {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let name = url.lastPathComponent
            if firstMatch(observation, in: name) != nil,
               url.deletingLastPathComponent().standardizedFileURL.path != observationPath {
                enumerator.skipDescendants()
                continue
            }
            if firstMatch(imagesFolder, in: name) != nil {
                folders.append(url)
            }
        }
        return folders.sorted { $0.path < $1.path }
    }

    private static func imageFiles(from imageFolders: [URL], alsoUnder observationFolder: URL) -> [URL] {
        if imageFolders.isEmpty {
            return imageFiles(under: observationFolder)
        }
        var files: [URL] = []
        for folder in imageFolders {
            files.append(contentsOf: imageFiles(under: folder))
        }
        return files
    }

    private static func imageFiles(under folder: URL, extensions: Set<String> = sortExtensions) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if extensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func dedupeFiles(_ files: [URL]) -> [URL] {
        var seen = Set<String>()
        var unique: [URL] = []
        for file in files.sorted(by: { $0.path < $1.path }) {
            let key = file.standardizedFileURL.path
            if seen.insert(key).inserted {
                unique.append(file)
            }
        }
        return unique
    }

    private static func formats(of files: [URL]) -> [String] {
        guard !files.isEmpty else { return [] }
        return Array(Set(files.map { $0.pathExtension.uppercased() })).sorted()
    }

    private static func dsoName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
            .uppercased()
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func substring(_ range: NSRange, in text: String) -> String {
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return "" }
        return String(text[swiftRange])
    }
}
