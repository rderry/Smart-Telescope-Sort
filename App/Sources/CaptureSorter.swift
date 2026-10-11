import Foundation

struct CaptureEntry: Identifiable, Hashable {
    var id: String { "\(captureFolder)|\(object)|\(session)|\(year)-\(month)" }
    var captureFolder: String
    var year: String
    var month: String
    var object: String
    /// The night or observation these files came from (2025-10-10_07-49-28, or 2025-10-10 when no time is known).
    /// Every session numbers its frames from IMG_0001 again, so a name another night already used gets a number added.
    var session: String
    var imageFolders: Int
    var files: Int
    var formats: [String]
    /// Targets {year}.
    var yearFolder: URL
    var targetExists: Bool
    var sourceFiles: [URL]
    /// No folder above these files names a target; `object` is only the folder's name and the user is asked at sort time.
    var needsObjectName = false

    var objectFolder: URL { yearFolder.appendingPathComponent(object, isDirectory: true) }
    /// Targets {year}/{object}.
    var targetDirectory: URL { objectFolder }
    /// The session's day, YYYY-MM-DD: the name offered when no folder names the object.
    var sessionDate: String { String(session.prefix(10)) }

    /// The same row sorted into Targets {year}/`name` instead.
    func named(_ name: String) -> CaptureEntry {
        var row = self
        row.object = name
        row.needsObjectName = false
        return row
    }
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
        /// New to Targets. Nothing in Targets is ever overwritten; a different file holding the name gets " 2" added.
        case move
        /// Byte-for-byte the same as `destination`, already in Targets or moved there by this sort.
        case duplicate

        var label: String {
            switch self {
            case .move: return "New"
            case .duplicate: return "Duplicate"
            }
        }
    }

    /// Never moved, only deleted when the user says yes.
    var isDuplicate: Bool { action == .duplicate }
}

struct SortSummary {
    var move = 0
    var duplicate = 0
    var createTargets: [String] = []
    var removedFolders = 0

    var duplicates: Int { duplicate }
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
    /// Emptied capture folders kept because they hold JSON or astrometry files not yet allowed to be deleted.
    var held: [String: ProtectedFiles] = [:]
}

/// Which protected files a folder may be deleted with. Off by default, so the user is asked first.
struct DeletePermissions: Equatable {
    var json = false
    var astrometry = false
}

/// What is left in a folder that's about to be deleted, apart from the files that deletion is meant to remove.
struct ProtectedFiles: Equatable {
    var json = 0
    /// Plate-solve files: named astrometry.*, or inside a folder whose name contains "astrometry".
    var astrometry = 0
    /// Anything else, e.g. .afphoto or .seq, by lowercased extension. A folder holding these is never deleted.
    var other: [String: Int] = [:]

    func blocked(by permissions: DeletePermissions) -> Bool {
        (json > 0 && !permissions.json) || (astrometry > 0 && !permissions.astrometry)
    }
}

/// The outcome of deleting folders: those removed, those held back for JSON or astrometry files, and those kept
/// because they hold other files.
struct FolderCleanup {
    var removed = 0
    var held: [String: ProtectedFiles] = [:]
    var kept: [String: [String: Int]] = [:]
}

/// How far a scan of the Capture Folder has got. `total` is nil while folders are still being found.
struct ScanProgress: Sendable {
    static let steps = 5
    var step: Int
    var phase: String
    var done = 0
    var total: Int?

    var fraction: Double? { total.map { $0 > 0 ? min(Double(done) / Double($0), 1) : 0 } }
    var countText: String { total.map { "\(done) of \($0)" } ?? "\(done) folders searched" }
}

/// Passes scan progress to the window at most ten times a second, and lets the user stop the scan.
final class ScanMonitor: @unchecked Sendable {
    struct Cancelled: Error {}

    private let lock = NSLock()
    private var cancelled = false
    private var lastReport = Date.distantPast
    private let onProgress: @Sendable (ScanProgress) -> Void

    init(onProgress: @escaping @Sendable (ScanProgress) -> Void) {
        self.onProgress = onProgress
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() { lock.withLock { cancelled = true } }

    func checkCancelled() throws {
        if isCancelled { throw Cancelled() }
    }

    /// `force` reports even within a tenth of a second of the last one, for the start of each step.
    func report(step: Int, _ phase: String, done: Int = 0, total: Int? = nil, force: Bool = false) {
        let now = Date()
        let due = lock.withLock { () -> Bool in
            guard force || now.timeIntervalSince(lastReport) >= 0.1 else { return false }
            lastReport = now
            return true
        }
        if due { onProgress(ScanProgress(step: step, phase: phase, done: done, total: total)) }
    }
}

/// Progress of the copy-then-delete steps of a sort: copying files or folders, or deleting the originals.
struct TransferProgress: Sendable {
    var phase: String
    var done = 0
    var total = 0
    var item = ""
    var deleting = false

    var fraction: Double { total > 0 ? min(Double(done) / Double(total), 1) : 0 }
}

final class TransferMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var lastReport = Date.distantPast
    private let onProgress: @Sendable (TransferProgress) -> Void

    init(onProgress: @escaping @Sendable (TransferProgress) -> Void) {
        self.onProgress = onProgress
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() { lock.withLock { cancelled = true } }

    func report(_ progress: TransferProgress, force: Bool = false) {
        let now = Date()
        let due = lock.withLock { () -> Bool in
            guard force || now.timeIntervalSince(lastReport) >= 0.1 else { return false }
            lastReport = now
            return true
        }
        if due { onProgress(progress) }
    }
}

/// An original that has been copied and checked byte for byte; it is deleted only when the user agrees.
struct CopiedItem: Sendable {
    var original: URL
    var copy: URL
    var isFolder: Bool
}

/// Byte-identical copies of one file inside a Targets {year}/{object} folder: the one kept and the extras.
struct RedundantCopies: Sendable {
    var keep: URL
    var extras: [URL]
}

struct CopyResult: Sendable {
    var copied: [CopiedItem] = []
    var failed: [String] = []
    var error: String?
}

/// A folder kept out of Targets and offered for Move, Leave or Delete after a sort: plate solves or calibration frames.
struct SetAsideFolder: Identifiable {
    var id: String { path }
    /// Relative to the Capture Folder.
    var path: String
    /// Image files inside, by lowercased extension.
    var images: [String: Int]
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
    static let keepFolderExtensions: Set<String> = ["tif", "tiff", "fit", "fits", "jpg", "jpeg", "png"]

    // Vaonis / Singularity
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
    // Month first, year last: 4-19-2026, 10-7-2025, 04_05_2026
    private static let monthFirstDate = try! NSRegularExpression(
        pattern: #"^(\d{1,2})[-_.](\d{1,2})[-_.](\d{4})(?:$|\D)"#
    )

    /// Every layout is searched the same way, to any depth below `sourceRoot`: observation folders first, then the
    /// nearest folder naming a target above any other image files. `kind` only labels the layout in the window.
    static func scan(
        kind: TelescopeKind,
        sourceRoot: URL = defaultSource,
        targetsRoot: URL? = nil,
        year: String? = nil,
        month: String? = nil,
        monitor: ScanMonitor? = nil
    ) throws -> (entries: [CaptureEntry], years: [String], excluded: String) {
        try scanCaptures(sourceRoot: sourceRoot, targetsRoot: targetsRoot ?? sourceRoot, year: year, month: month, monitor: monitor)
    }

    private static func scanCaptures(
        sourceRoot: URL,
        targetsRoot: URL,
        year: String?,
        month: String?,
        monitor: ScanMonitor?
    ) throws -> (entries: [CaptureEntry], years: [String], excluded: String) {
        guard FileManager.default.fileExists(atPath: sourceRoot.path) else {
            return ([], [], "Targets …")
        }

        struct Bundle {
            var capture: URL
            var object: String
            var date: FolderDate
            var needsObjectName: Bool
            var folders = 0
            var files: [URL] = []
        }
        var bundles: [String: Bundle] = [:]
        func add(capture: URL, object: String, files: [URL], folders: Int, datedBy folder: URL, needsObjectName: Bool = false) {
            let date = namedDate(of: folder, within: sourceRoot) ?? newestDate(of: files.isEmpty ? [folder] : files)
            let key = "\(relativePath(of: capture, in: sourceRoot))|\(object)|\(date.session)"
            var bundle = bundles[key]
                ?? Bundle(capture: capture, object: object, date: date, needsObjectName: needsObjectName)
            bundle.folders += folders
            bundle.files += files
            bundles[key] = bundle
        }

        let units = observationUnits(under: sourceRoot, monitor: monitor)
        try monitor?.checkCancelled()
        monitor?.report(step: 2, "Reading observation folders", total: units.count, force: true)
        for (index, unit) in units.enumerated() {
            try monitor?.checkCancelled()
            monitor?.report(step: 2, "Reading observation folders", done: index + 1, total: units.count)
            let imageDirs = imagesFolders(under: unit.observation)
            let files = imageFiles(from: imageDirs, alsoUnder: unit.observation)
            add(capture: unit.capture, object: unit.object, files: files, folders: max(imageDirs.count, 1), datedBy: unit.observation)
        }

        let claimed = Set(units.map { $0.observation.standardizedFileURL.path })
        let unclaimed = unclaimedImageFiles(under: sourceRoot, skipping: claimed, monitor: monitor)
        try monitor?.checkCancelled()
        for (folder, files) in unclaimed {
            let capture = captureFolder(holding: folder, within: sourceRoot)
            let name = objectName(from: capture.lastPathComponent)
            add(capture: capture, object: dsoName(name), files: files, folders: 1, datedBy: folder, needsObjectName: !namesTarget(name))
        }

        var entries: [CaptureEntry] = []
        var years = Set<String>()
        for bundle in bundles.values {
            years.insert(bundle.date.year)
            if let year, year != "all", bundle.date.year != year { continue }
            if let month, month != "all", bundle.date.month != month { continue }
            var row = entry(
                capture: relativePath(of: bundle.capture, in: sourceRoot),
                object: bundle.object,
                date: bundle.date,
                imageFolders: bundle.folders,
                files: bundle.files,
                targetsRoot: targetsRoot
            )
            row.needsObjectName = bundle.needsObjectName
            entries.append(row)
        }

        entries.sort {
            ($0.year, $0.month, $0.captureFolder, $0.object, $0.session) < ($1.year, $1.month, $1.captureFolder, $1.object, $1.session)
        }
        return (entries, years.sorted(by: >), "Targets …")
    }

    /// The rows the window lists: those with files to sort. Rows with none stay in the scan, since they mark capture
    /// folders a sort emptied or finished, which the app offers to remove.
    static func rowsToShow(_ entries: [CaptureEntry]) -> [CaptureEntry] {
        entries.filter { $0.files > 0 }
    }

    private static func entry(
        capture: String,
        object: String,
        date: FolderDate,
        imageFolders: Int,
        files: [URL],
        targetsRoot: URL
    ) -> CaptureEntry {
        let uniqueFiles = dedupeFiles(files)
        let yearFolder = targetsRoot.appendingPathComponent("Targets \(date.year)", isDirectory: true)
        var isDir: ObjCBool = false
        let targetExists = FileManager.default.fileExists(atPath: yearFolder.path, isDirectory: &isDir) && isDir.boolValue
        return CaptureEntry(
            captureFolder: capture,
            year: date.year,
            month: date.month,
            object: object,
            session: date.session,
            imageFolders: imageFolders,
            files: uniqueFiles.count,
            formats: formats(of: uniqueFiles),
            yearFolder: yearFolder,
            targetExists: targetExists,
            sourceFiles: uniqueFiles
        )
    }

    private struct ObservationUnit {
        /// The folder treated as one capture: a dated observation folder itself, or the folder holding NN-observation folders.
        var capture: URL
        var observation: URL
        var object: String
    }

    /// Observation folders at any depth under `root`, whatever the folders above them are called.
    /// Targets {year} folders are not entered, and nothing inside an observation folder is searched again.
    /// An NN-observation folder straight in `root` is its own capture: the capture can't be `root` itself.
    private static func observationUnits(under root: URL, monitor: ScanMonitor? = nil) -> [ObservationUnit] {
        var units: [ObservationUnit] = []
        let rootPath = root.standardizedFileURL.path
        func unit(for folder: URL) -> ObservationUnit? {
            let name = folder.lastPathComponent
            if let match = firstMatch(datedObservationCapture, in: name) {
                return ObservationUnit(capture: folder, observation: folder, object: dsoName(substring(match.range(at: 1), in: name)))
            }
            if let match = firstMatch(observation, in: name) {
                let parent = folder.deletingLastPathComponent()
                let capture = parent.standardizedFileURL.path == rootPath ? folder : parent
                return ObservationUnit(capture: capture, observation: folder, object: dsoName(substring(match.range(at: 1), in: name)))
            }
            return nil
        }
        if let rootUnit = unit(for: root) {
            return [ObservationUnit(capture: root, observation: root, object: rootUnit.object)]
        }
        guard let walk = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var searched = 0
        monitor?.report(step: 1, "Finding observation folders", force: true)
        for case let url as URL in walk {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if monitor?.isCancelled == true { break }
            searched += 1
            monitor?.report(step: 1, "Finding observation folders", done: searched)
            if isTargetsFolder(url.lastPathComponent) {
                walk.skipDescendants()
            } else if let found = unit(for: url) {
                units.append(found)
                walk.skipDescendants()
            }
        }
        return units.sorted { $0.observation.path < $1.observation.path }
    }

    /// Image files of the checked types under `root` outside Targets {year} and outside the `skipping` folders, grouped by the folder
    /// that holds them. Files with no dated or observation folder above them still get sorted this way.
    private static func unclaimedImageFiles(under root: URL, skipping: Set<String>, monitor: ScanMonitor? = nil) -> [(URL, [URL])] {
        var byFolder: [String: (URL, [URL])] = [:]
        guard let walk = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var searched = 0
        monitor?.report(step: 3, "Finding other images", force: true)
        for case let url as URL in walk {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if monitor?.isCancelled == true { break }
                searched += 1
                monitor?.report(step: 3, "Finding other images", done: searched)
                let name = url.lastPathComponent
                if isTargetsFolder(name) || isSetupFolder(name) || isCalibrationFolder(name)
                    || skipping.contains(url.standardizedFileURL.path) {
                    walk.skipDescendants()
                }
                continue
            }
            guard sortExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let folder = url.deletingLastPathComponent()
            byFolder[folder.standardizedFileURL.path, default: (folder, [])].1.append(url)
        }
        return byFolder.values.sorted { $0.0.path < $1.0.path }
    }

    // Catalog designations (M31, NGC 7000, IC_1805, Sh2-155, Barnard150, C 2023 A3…) and solar-system targets.
    private static let catalogObject = try! NSRegularExpression(
        pattern: #"(?:^|[^A-Za-z])(?:M|NGC|IC|Sh2|Sh-2|SH2|C|B|Barnard|LDN|LBN|vdB|Abell|Arp|Mel|Cr|Collinder|UGC|PGC|Caldwell)[ _-]?\d+"#,
        options: .caseInsensitive
    )
    private static let solarSystemObject = try! NSRegularExpression(
        pattern: #"(?:^|[^A-Za-z])(?:moon|sun|mercury|venus|mars|jupiter|saturn|uranus|neptune|pluto|comet)(?:$|[^A-Za-z])"#,
        options: .caseInsensitive
    )

    private static func namesTarget(_ name: String) -> Bool {
        firstMatch(catalogObject, in: name) != nil || firstMatch(solarSystemObject, in: name) != nil
    }

    /// The capture a folder of image files belongs to: the nearest folder at or above it, up to `root`, that names a
    /// deep-sky or solar-system target; else the nearest one below `root` that isn't a date or a word like lights or
    /// raw; else the folder itself.
    private static func captureFolder(holding folder: URL, within root: URL) -> URL {
        let rootPath = root.standardizedFileURL.path
        var named: URL?
        var url = folder.standardizedFileURL
        while url.path.hasPrefix(rootPath) {
            if namesTarget(objectName(from: url.lastPathComponent)) { return url }
            if url.path == rootPath || url.path == "/" { break }
            if named == nil, !isGenericFolderName(url.lastPathComponent) { named = url }
            url = url.deletingLastPathComponent()
        }
        return named ?? folder
    }

    private static let genericFolderNames: Set<String> = [
        "light", "lights", "raw", "raws", "image", "images", "img", "sub", "subs", "frame", "frames", "capture", "captures",
        "fit", "fits", "tif", "tiff", "jpg", "jpeg", "stack", "stacked", "output", "user", "data", "files",
        "dark", "darks", "flat", "flats", "bias",
    ]

    /// Folder names that say nothing about the target: dates and numbers, image or frame folders.
    private static func isGenericFolderName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return genericFolderNames.contains(lower)
            || firstMatch(imagesFolder, in: name) != nil
            || lower.rangeOfCharacter(from: .letters) == nil
    }

    /// Folders of frames that aren't target images: thumbnails, the telescope's auto-init shots, and the plate-solve
    /// frames taken while pointing and guiding (NN-pointing-astrometry, NN-post-guiding-astrometry…).
    private static func isSetupFolder(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "thumbnail" || lower == "thumbnails" || lower.hasSuffix("_thumbnail")
            || lower.contains("auto-init") || isPlateSolveFolder(name)
    }

    // Lights, Darks, Dark Flats, Flats, Bias and Master… folders, including names like Flats1x20 or Dark_Flats.
    private static let calibrationFolderName = try! NSRegularExpression(
        pattern: #"^(?:master|(?:lights?|darks?|dark[ _-]?flats?|flats?|bias(?:es)?)(?:$|[^a-z]))"#,
        options: .caseInsensitive
    )

    static func isCalibrationFolder(_ name: String) -> Bool {
        firstMatch(calibrationFolderName, in: name) != nil
    }

    /// True when a folder between `base` and `file` holds setup or calibration frames rather than target images.
    private static func isSetupOrCalibrationFile(_ file: URL, below base: URL) -> Bool {
        file.deletingLastPathComponent().pathComponents.dropFirst(base.pathComponents.count)
            .contains { isSetupFolder($0) || isCalibrationFolder($0) }
    }

    /// Folders of plate-solve frames the telescope took while pointing and guiding (01-pointing-astrometry…).
    static func isPlateSolveFolder(_ name: String) -> Bool {
        name.lowercased().contains("astrometry")
    }

    static func plateSolveFolders(under root: URL) -> [SetAsideFolder] {
        setAsideFolders(under: root, matching: isPlateSolveFolder)
    }

    /// The outermost calibration folders under `root` that hold images, outside Targets {year}.
    static func calibrationFolders(under root: URL) -> [SetAsideFolder] {
        setAsideFolders(under: root, matching: isCalibrationFolder)
    }

    /// Plate-solve and calibration folders in one walk of `root`, for the scan.
    static func setAsideFolders(under root: URL, monitor: ScanMonitor?) -> (plateSolves: [SetAsideFolder], calibration: [SetAsideFolder]) {
        var plateSolves: [SetAsideFolder] = []
        var calibration: [SetAsideFolder] = []
        var searched = 0
        monitor?.report(step: 5, "Finding plate solves and calibration folders", force: true)
        for folder in setAsideFolders(under: root, matching: { isCalibrationFolder($0) || isPlateSolveFolder($0) }, onFolder: {
            searched += 1
            monitor?.report(step: 5, "Finding plate solves and calibration folders", done: searched)
            return monitor?.isCancelled != true
        }) {
            if isCalibrationFolder(URL(fileURLWithPath: folder.path).lastPathComponent) {
                calibration.append(folder)
            } else {
                plateSolves.append(folder)
            }
        }
        return (plateSolves, calibration)
    }

    /// `onFolder` is called for each folder walked; returning false stops the walk.
    private static func setAsideFolders(
        under root: URL,
        matching matches: (String) -> Bool,
        onFolder: () -> Bool = { true }
    ) -> [SetAsideFolder] {
        guard let walk = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var found: [SetAsideFolder] = []
        for case let url as URL in walk {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard onFolder() else { break }
            let name = url.lastPathComponent
            if isTargetsFolder(name) {
                walk.skipDescendants()
            } else if matches(name) {
                walk.skipDescendants()
                let files = imageFiles(under: url, extensions: calibrationExtensions)
                guard !files.isEmpty else { continue }
                found.append(SetAsideFolder(
                    path: relativePath(of: url, in: root),
                    images: files.reduce(into: [:]) { $0[$1.pathExtension.lowercased(), default: 0] += 1 }
                ))
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    private static let calibrationExtensions = keepFolderExtensions.union(["xisf"])

    /// Copies set-aside folders into `destination`, each keeping its path from the Capture Folder so folders with the
    /// same name don't collide. The originals stay until the user agrees to delete them.
    static func copySetAsideFolders(_ paths: [String], sourceRoot: URL, to destination: URL, monitor: TransferMonitor? = nil) -> CopyResult {
        var result = CopyResult()
        let folders = outermost(paths)
        for (index, path) in folders.enumerated() {
            if monitor?.isCancelled == true { break }
            monitor?.report(TransferProgress(phase: "Copying folders", done: index, total: folders.count, item: path))
            if let item = copyFolder(path, sourceRoot: sourceRoot, to: destination.appendingPathComponent(path, isDirectory: true)) {
                result.copied.append(item)
            } else {
                result.failed.append(path)
            }
        }
        return result
    }

    /// Copies one folder under the Capture Folder to `target`, adding a number when that path is taken, and checks the
    /// copy matches the original file for file. A copy that doesn't match is removed. Refuses to copy a folder into itself.
    private static func copyFolder(_ path: String, sourceRoot: URL, to target: URL) -> CopiedItem? {
        let fm = FileManager.default
        guard let folder = captureFolderURL(path, in: sourceRoot), fm.fileExists(atPath: folder.path),
              !(target.standardizedFileURL.path + "/").hasPrefix(folder.standardizedFileURL.path + "/") else { return nil }
        var target = target
        if fm.fileExists(atPath: target.path) {
            target = unusedURL(in: target.deletingLastPathComponent(), base: target.lastPathComponent, extension: nil)
        }
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: folder, to: target)
        } catch {
            try? fm.removeItem(at: target)
            return nil
        }
        guard fm.contentsEqual(atPath: folder.path, andPath: target.path) else {
            try? fm.removeItem(at: target)
            return nil
        }
        return CopiedItem(original: folder, copy: target, isFolder: true)
    }

    /// Where one plate-solve folder goes when moved: Targets {year}/{object}/Plate Solves/{session}/{subpath}.
    struct PlateSolveMove {
        /// Relative to the Capture Folder.
        var path: String
        /// From the observation or target-named folder above; nil when none names one, and the user is asked.
        var object: String?
        var year: String
        var session: String
        /// The folders below the observation folder, e.g. 10-pointing-bad-registration/01-pointing-astrometry; just the
        /// folder's own name when nothing above names an object.
        var subpath: String
        var images: Int

        var sessionDate: String { String(session.prefix(10)) }
    }

    static func plateSolveMoves(_ folders: [SetAsideFolder], sourceRoot: URL) -> [PlateSolveMove] {
        let rootPath = sourceRoot.standardizedFileURL.path
        return folders.map { folder in
            let url = sourceRoot.appendingPathComponent(folder.path, isDirectory: true).standardizedFileURL
            var object: String?
            var below = [url.lastPathComponent]
            var cursor = url.deletingLastPathComponent()
            while cursor.path.hasPrefix(rootPath) {
                let name = cursor.lastPathComponent
                if let match = firstMatch(datedObservationCapture, in: name) ?? firstMatch(observation, in: name) {
                    object = dsoName(substring(match.range(at: 1), in: name))
                    break
                }
                if namesTarget(objectName(from: name)) {
                    object = dsoName(objectName(from: name))
                    break
                }
                if cursor.path == rootPath { break }
                below.insert(name, at: 0)
                cursor = cursor.deletingLastPathComponent()
            }
            let files = imageFiles(under: url, extensions: calibrationExtensions)
            let date = namedDate(of: url, within: sourceRoot) ?? newestDate(of: files.isEmpty ? [url] : files)
            return PlateSolveMove(path: folder.path, object: object, year: date.year, session: date.session,
                                  subpath: object == nil ? url.lastPathComponent : below.joined(separator: "/"),
                                  images: folder.images.values.reduce(0, +))
        }
    }

    static let plateSolvesFolderName = "Plate Solves"

    /// Copies named plate-solve folders in with their object's images: Targets {year}/{object}/Plate Solves/{session}/{subpath}
    /// under `targetsRoot`. {session} is dropped when the object was named after it. The originals stay until the user
    /// agrees to delete them.
    static func copyPlateSolves(_ moves: [PlateSolveMove], sourceRoot: URL, targetsRoot: URL, monitor: TransferMonitor? = nil) -> CopyResult {
        var result = CopyResult()
        for (index, move) in moves.enumerated() {
            if monitor?.isCancelled == true { break }
            monitor?.report(TransferProgress(phase: "Copying plate solves", done: index, total: moves.count, item: move.path))
            guard let object = move.object else { continue }
            var target = targetsRoot
                .appendingPathComponent("Targets \(move.year)", isDirectory: true)
                .appendingPathComponent(object, isDirectory: true)
                .appendingPathComponent(plateSolvesFolderName, isDirectory: true)
            if move.session != object {
                target.appendPathComponent(move.session, isDirectory: true)
            }
            target.appendPathComponent(move.subpath, isDirectory: true)
            if let item = copyFolder(move.path, sourceRoot: sourceRoot, to: target) {
                result.copied.append(item)
            } else {
                result.failed.append(move.path)
            }
        }
        return result
    }

    /// A folder name without vendor prefixes or the dates around it: "2025-01-04 M42" and "M42_2025-01-04" give "M42".
    private static func objectName(from folderName: String) -> String {
        var name = stripVendorNoise(folderName)
        for pattern in [
            #"^\d{4}-\d{2}-\d{2}(?:[_ T-]\d{2}[-:]\d{2}(?:[-:]\d{2})?)?[_ -]*"#,
            #"^\d{1,2}[-_.]\d{1,2}[-_.]\d{4}[_ -]*"#,
            #"[_ -]+\d{4}-\d{2}-\d{2}.*$"#,
            #"[_ -]+\d{1,2}[-_.]\d{1,2}[-_.]\d{4}.*$"#,
        ] {
            name = name.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return name.isEmpty ? folderName : name
    }

    private static func isTargetsFolder(_ name: String) -> Bool {
        name.lowercased().hasPrefix("targets ")
    }

    /// `url` as a path under `root` ("" for `root` itself).
    static func relativePath(of url: URL, in root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == rootPath { return "" }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    private struct FolderDate {
        var year: String
        var month: String
        /// YYYY-MM-DD_HH-MM-SS when the folder name has a time, else YYYY-MM-DD.
        var session: String
    }

    /// The date named by `folder` or the nearest folder above it, up to and including `root`.
    private static func namedDate(of folder: URL, within root: URL) -> FolderDate? {
        let rootPath = root.standardizedFileURL.path
        var url = folder.standardizedFileURL
        while true {
            if let date = folderDate(fromFolderName: url.lastPathComponent) { return date }
            if url.path == rootPath || url.path == "/" || !url.path.hasPrefix(rootPath) { return nil }
            url = url.deletingLastPathComponent()
        }
    }

    private static func newestDate(of files: [URL]) -> FolderDate {
        let newest = files.map(modified).filter { $0 > .distantPast }.max() ?? Date()
        let day = Calendar.current.dateComponents([.year, .month, .day], from: newest)
        let year = String(day.year ?? 0), month = String(format: "%02d", day.month ?? 1)
        return FolderDate(year: year, month: month, session: "\(year)-\(month)-\(String(format: "%02d", day.day ?? 1))")
    }

    private static let leadingTimestamp = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2}[_ T-](\d{2})[-:](\d{2})[-:](\d{2})"#
    )

    /// The date in a folder name with the year first (2026-04-20…, 20260420) or last (4-19-2026), or an
    /// Object_YYYY-MM-DD name. A number on its own, such as 2025 or the 2024 in NGC2024, is not a date.
    private static func folderDate(fromFolderName name: String) -> FolderDate? {
        func checked(_ year: String, _ month: String, _ day: String) -> FolderDate? {
            guard year.count == 4, let m = Int(month), (1...12).contains(m), let d = Int(day), (1...31).contains(d) else { return nil }
            let month = String(format: "%02d", m)
            return FolderDate(year: year, month: month, session: "\(year)-\(month)-\(String(format: "%02d", d))")
        }
        func part(_ match: NSTextCheckingResult, _ index: Int) -> String { substring(match.range(at: index), in: name) }
        if let match = firstMatch(leadingISODate, in: name), var date = checked(part(match, 1), part(match, 2), part(match, 3)) {
            if let time = firstMatch(leadingTimestamp, in: name) {
                date.session += "_\(substring(time.range(at: 1), in: name))-\(substring(time.range(at: 2), in: name))-\(substring(time.range(at: 3), in: name))"
            }
            return date
        }
        if let match = firstMatch(leadingCompactDate, in: name), let date = checked(part(match, 1), part(match, 2), part(match, 3)) {
            return date
        }
        if let match = firstMatch(monthFirstDate, in: name), let date = checked(part(match, 3), part(match, 1), part(match, 2)) {
            return date
        }
        if let match = firstMatch(originDatedObject, in: name), let date = checked(part(match, 2), part(match, 3), part(match, 4)) {
            return date
        }
        return nil
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

    /// Stops early when `monitor` is cancelled; the caller checks for that and drops the partial plan.
    static func preview(entries: [CaptureEntry], monitor: ScanMonitor? = nil) -> (plans: [SortPlanItem], summary: SortSummary) {
        var plans: [SortPlanItem] = []
        var summary = SortSummary()
        summary.createTargets = Array(Set(entries.filter { !$0.targetExists }.map(\.year))).sorted()

        // Copies already anywhere in Targets {year}/{object}, and files this sort sends there, by duplicateKey.
        var inTargets: [String: [String: [URL]]] = [:]
        var planned: [String: [String: [URL]]] = [:]
        var taken = Set<String>()
        func copies(in objectFolder: URL) -> [String: [URL]] {
            let key = objectFolder.standardizedFileURL.path
            if let index = inTargets[key] { return index }
            let index = Dictionary(grouping: imageFiles(under: objectFolder, extensions: keepFolderExtensions), by: duplicateKey)
            inTargets[key] = index
            return index
        }

        let work = entries.flatMap { entry in entry.sourceFiles.map { (entry: entry, source: $0) } }
            .sorted { ($0.entry.session, $0.source.path) < ($1.entry.session, $1.source.path) }
        monitor?.report(step: 4, "Comparing with Targets", total: work.count, force: true)
        for (index, (entry, source)) in work.enumerated() {
            if monitor?.isCancelled == true { break }
            monitor?.report(step: 4, "Comparing with Targets", done: index + 1, total: work.count)
            let objectKey = entry.objectFolder.standardizedFileURL.path
            let name = duplicateKey(source)
            let action: SortPlanItem.Action
            let destination: URL
            if let copy = copies(in: entry.objectFolder)[name]?.first(where: { identical(source, $0) }) {
                action = .duplicate
                destination = copy
            } else if let earlier = planned[objectKey]?[name]?.first(where: { identical(source, $0) }),
                      let item = plans.first(where: { $0.source == earlier }) {
                action = .duplicate
                destination = item.destination
            } else {
                action = .move
                destination = freeDestination(for: source, in: entry.targetDirectory, taken: taken)
                taken.insert(destination.standardizedFileURL.path.lowercased())
                planned[objectKey, default: [:]][name, default: []].append(source)
            }
            if action == .move { summary.move += 1 } else { summary.duplicate += 1 }
            plans.append(SortPlanItem(
                source: source,
                destination: destination,
                action: action,
                entryID: entry.id,
                captureFolder: entry.captureFolder,
                object: entry.object,
                targetFolder: "Targets \(entry.year)/\(entry.object)",
                date: modified(source)
            ))
        }
        plans.sort {
            ($0.captureFolder, $0.object, $0.source.lastPathComponent) < ($1.captureFolder, $1.object, $1.source.lastPathComponent)
        }
        return (plans, summary)
    }

    /// A file's name for finding copies: lowercased, without the " 2", " 3"… a clashing name was given, so
    /// "IMG_0001 2.jpg" is checked against "IMG_0001.jpg". Candidates are still compared byte for byte.
    static func duplicateKey(_ url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: #" \d+$"#, with: "", options: .regularExpression)
        let ext = url.pathExtension
        return (ext.isEmpty ? base : base + "." + ext).lowercased()
    }

    /// Byte-identical copies within each Targets {year}/{object} folder, Plate Solves left out: files whose names
    /// differ only by a " 2", " 3"… In each set the un-numbered, least nested file is kept.
    static func findRedundantCopies(targetsRoot: URL, monitor: TransferMonitor? = nil) -> [RedundantCopies] {
        let fm = FileManager.default
        func subfolders(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        func numbered(_ url: URL) -> Bool {
            url.deletingPathExtension().lastPathComponent.range(of: #" \d+$"#, options: .regularExpression) != nil
        }
        func keptFirst(_ a: URL, _ b: URL) -> Bool {
            (numbered(a) ? 1 : 0, a.pathComponents.count, a.path) < (numbered(b) ? 1 : 0, b.pathComponents.count, b.path)
        }
        let objectFolders = subfolders(targetsRoot)
            .filter { $0.lastPathComponent.range(of: #"^Targets \d{4}$"#, options: .regularExpression) != nil }
            .flatMap(subfolders)
            .sorted { $0.path < $1.path }
        let phase = "Finding identical copies in Targets"
        var found: [RedundantCopies] = []
        for (index, folder) in objectFolders.enumerated() {
            if monitor?.isCancelled == true { break }
            monitor?.report(TransferProgress(phase: phase, done: index, total: objectFolders.count, item: folder.lastPathComponent))
            let depth = folder.pathComponents.count
            let files = imageFiles(under: folder, extensions: keepFolderExtensions)
                .filter { !$0.pathComponents.dropFirst(depth).contains(plateSolvesFolderName) }
            for named in Dictionary(grouping: files, by: { "\(duplicateKey($0))|\(size($0))" }).values where named.count > 1 {
                var sets: [[URL]] = []
                for file in named.sorted(by: keptFirst) {
                    if let i = sets.firstIndex(where: { identical($0[0], file) }) {
                        sets[i].append(file)
                    } else {
                        sets.append([file])
                    }
                }
                found += sets.filter { $0.count > 1 }.map { RedundantCopies(keep: $0[0], extras: Array($0.dropFirst())) }
            }
        }
        monitor?.report(TransferProgress(phase: phase, done: objectFolders.count, total: objectFolders.count), force: true)
        return found.sorted { $0.keep.path < $1.keep.path }
    }

    /// Moves each extra copy to the Trash (deleting it outright on drives without one) after re-reading it byte for
    /// byte against the copy that's kept. Returns how many went, the bytes freed and the paths skipped.
    static func removeRedundantCopies(_ sets: [RedundantCopies], monitor: TransferMonitor? = nil)
        -> (deleted: Int, bytes: Int64, skipped: [String]) {
        let fm = FileManager.default
        let extras = sets.flatMap { set in set.extras.map { (keep: set.keep, extra: $0) } }
        let phase = "Deleting identical copies in Targets"
        var deleted = 0
        var bytes: Int64 = 0
        var skipped: [String] = []
        for (index, pair) in extras.enumerated() {
            if monitor?.isCancelled == true {
                skipped += extras[index...].map(\.extra.path)
                break
            }
            monitor?.report(TransferProgress(phase: phase, done: index, total: extras.count,
                                             item: pair.extra.lastPathComponent, deleting: true))
            let fileSize = size(pair.extra)
            guard fm.fileExists(atPath: pair.keep.path), identical(pair.extra, pair.keep, cached: false) else {
                skipped.append(pair.extra.path)
                continue
            }
            do {
                do { try fm.trashItem(at: pair.extra, resultingItemURL: nil) } catch { try fm.removeItem(at: pair.extra) }
                deleted += 1
                bytes += Int64(fileSize)
            } catch {
                skipped.append(pair.extra.path)
            }
        }
        monitor?.report(TransferProgress(phase: phase, done: extras.count, total: extras.count, deleting: true), force: true)
        return (deleted, bytes, skipped)
    }

    /// `folder`/`source`'s name, or "name 2.ext", "name 3.ext"… when a different file already holds it.
    private static func freeDestination(for source: URL, in folder: URL, taken: Set<String>) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var candidate = folder.appendingPathComponent(source.lastPathComponent)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) || taken.contains(candidate.standardizedFileURL.path.lowercased()) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    /// Same bytes. FITS frames of one camera are all the same size, so size alone proves nothing. Answers are
    /// remembered while both files keep their size and date, so a refresh doesn't re-read them; `cached: false`
    /// always reads, for the check just before a file is deleted.
    private static func identical(_ a: URL, _ b: URL, cached: Bool = true) -> Bool {
        guard a.standardizedFileURL != b.standardizedFileURL, size(a) == size(b), size(a) >= 0 else { return false }
        let key = "\(a.path)|\(b.path)|\(size(a))|\(modified(a).timeIntervalSince1970)|\(modified(b).timeIntervalSince1970)"
        if cached, let known = identicalCache.withLock({ $0[key] }) { return known }
        let same = FileManager.default.contentsEqual(atPath: a.path, andPath: b.path)
        identicalCache.withLock { $0[key] = same }
        return same
    }

    private static let identicalCache = LockedDictionary()

    private final class LockedDictionary: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Bool] = [:]

        func withLock<T>(_ body: (inout [String: Bool]) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(&values)
        }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
    }

    /// Deletes source files that are already in Targets (moved to the Trash when the volume allows it), then
    /// removes capture folders left with no TIFF/FITS. Each file is re-compared byte for byte with its Targets copy first.
    static func deleteDuplicates(_ items: [SortPlanItem], sourceRoot: URL, allowing: DeletePermissions = .init()) -> DuplicateCleanup {
        let fm = FileManager.default
        var result = DuplicateCleanup()
        for item in items where item.isDuplicate {
            guard fm.fileExists(atPath: item.source.path),
                  fm.fileExists(atPath: item.destination.path),
                  identical(item.source, item.destination, cached: false) else {
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
        let cleanup = removeSpentCaptureFolders(
            captureNames: Array(Set(items.filter(\.isDuplicate).map(\.captureFolder))),
            sourceRoot: sourceRoot.standardizedFileURL,
            allowing: allowing
        )
        result.removedFolders = cleanup.removed
        result.held = cleanup.held
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

    /// Copies every file the plan moves into Targets {year}/{object} and checks each copy byte for byte. Nothing is
    /// deleted: the originals stay until the user agrees, at the end of the sort, to delete them.
    static func copySort(entries: [CaptureEntry], sourceRoot: URL = defaultSource, targetsRoot: URL? = nil,
                         monitor: TransferMonitor? = nil) -> CopyResult {
        let targetsRoot = targetsRoot ?? sourceRoot
        let (plans, summary) = preview(entries: entries)
        let moves = plans.filter { $0.action == .move }
        var result = CopyResult()
        do {
            for year in summary.createTargets {
                try createTargetsFolder(year: year, targetsRoot: targetsRoot)
            }
            try checkFreeSpace(for: moves.map(\.source), at: targetsRoot)
        } catch {
            result.error = error.localizedDescription
            return result
        }
        let fm = FileManager.default
        for (index, item) in moves.enumerated() {
            if monitor?.isCancelled == true { break }
            monitor?.report(TransferProgress(phase: "Copying images", done: index, total: moves.count, item: item.source.lastPathComponent))
            let folder = item.destination.deletingLastPathComponent()
            let destination = fm.fileExists(atPath: item.destination.path)
                ? freeDestination(for: item.destination, in: folder, taken: [])
                : item.destination
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try fm.copyItem(at: item.source, to: destination)
            } catch {
                try? fm.removeItem(at: destination)
                result.failed.append(item.source.lastPathComponent)
                continue
            }
            if identical(item.source, destination, cached: false) {
                result.copied.append(CopiedItem(original: item.source, copy: destination, isFolder: false))
            } else {
                try? fm.removeItem(at: destination)
                result.failed.append(item.source.lastPathComponent)
            }
        }
        monitor?.report(TransferProgress(phase: "Copying images", done: moves.count, total: moves.count), force: true)
        return result
    }

    /// Throws when the Target Folder's drive hasn't room for `files`. Copies within one APFS volume are clones that
    /// take no extra space, so they aren't checked.
    private static func checkFreeSpace(for files: [URL], at targetsRoot: URL) throws {
        guard let first = files.first else { return }
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey, .volumeSupportsFileCloningKey,
                                         .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let target = try? targetsRoot.resourceValues(forKeys: keys),
              let source = try? first.resourceValues(forKeys: [.volumeIdentifierKey]) else { return }
        if target.volumeSupportsFileCloning == true, let a = target.volumeIdentifier as? NSObject,
           let b = source.volumeIdentifier as? NSObject, a.isEqual(b) {
            return
        }
        let available = target.volumeAvailableCapacityForImportantUsage ?? Int64(target.volumeAvailableCapacity ?? Int.max)
        let needed = files.reduce(Int64(0)) { $0 + Int64(max(size($1), 0)) }
        guard needed + 100_000_000 > available else { return }
        let format = ByteCountFormatter()
        throw NSError(domain: "SmartTelescopeSort", code: 3, userInfo: [NSLocalizedDescriptionKey:
            "Not enough free space on the Target Folder's drive: copying needs \(format.string(fromByteCount: needed)), "
            + "and \(format.string(fromByteCount: available)) is free. Nothing was copied or deleted."])
    }

    /// Moves folders to the Trash, or deletes them outright on drives without one. Returns how many went and the paths skipped.
    static func trashFolders(_ folders: [URL], monitor: TransferMonitor? = nil) -> (deleted: Int, skipped: [String]) {
        let fm = FileManager.default
        var deleted = 0
        var skipped: [String] = []
        for (index, folder) in folders.enumerated() {
            if monitor?.isCancelled == true {
                skipped += folders[index...].map(\.path)
                break
            }
            monitor?.report(TransferProgress(phase: "Deleting capture folders", done: index, total: folders.count,
                                             item: folder.lastPathComponent, deleting: true))
            do {
                do { try fm.trashItem(at: folder, resultingItemURL: nil) } catch { try fm.removeItem(at: folder) }
                deleted += 1
            } catch {
                skipped.append(folder.path)
            }
        }
        monitor?.report(TransferProgress(phase: "Deleting capture folders", done: folders.count, total: folders.count, deleting: true), force: true)
        return (deleted, skipped)
    }

    /// Moves originals to the Trash (deleting them outright on drives without one) once their copies are confirmed to
    /// still be in place. Returns how many were deleted and the paths skipped.
    static func deleteOriginals(_ items: [CopiedItem], monitor: TransferMonitor? = nil) -> (deleted: Int, skipped: [String]) {
        let fm = FileManager.default
        var deleted = 0
        var skipped: [String] = []
        for (index, item) in items.enumerated() {
            if monitor?.isCancelled == true {
                skipped += items[index...].map(\.original.path)
                break
            }
            monitor?.report(TransferProgress(phase: "Deleting originals", done: index, total: items.count,
                                             item: item.original.lastPathComponent, deleting: true))
            guard fm.fileExists(atPath: item.original.path), fm.fileExists(atPath: item.copy.path),
                  item.isFolder || size(item.original) == size(item.copy) else {
                skipped.append(item.original.path)
                continue
            }
            do {
                do { try fm.trashItem(at: item.original, resultingItemURL: nil) } catch { try fm.removeItem(at: item.original) }
                deleted += 1
            } catch {
                skipped.append(item.original.path)
            }
        }
        monitor?.report(TransferProgress(phase: "Deleting originals", done: items.count, total: items.count, deleting: true), force: true)
        return (deleted, skipped)
    }

    static var defaultBackupName: String {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        stamp.timeZone = .current
        return "TelescopeDataSort-Backup-\(stamp.string(from: Date()).replacingOccurrences(of: ":", with: "-"))"
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
        for name in backupPaths(for: entries, sourceRoot: sourceRoot) {
            guard let source = captureFolderURL(name, in: sourceRoot) else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { continue }
            let target = destination.appendingPathComponent(name, isDirectory: isDir.boolValue)
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: target)
            if isDir.boolValue {
                folders += 1
                files += imageFiles(under: target, extensions: keepFolderExtensions).count
            } else {
                files += 1
            }
        }
        return BackupSummary(folders: folders, files: files, destination: destination)
    }

    /// What a backup of these rows copies, relative to `sourceRoot`: each capture folder, or the image files
    /// themselves for rows found loose in the source folder. Paths inside another listed path are dropped.
    static func backupPaths(for entries: [CaptureEntry], sourceRoot: URL) -> [String] {
        var paths: [String] = []
        for entry in entries {
            if entry.captureFolder.isEmpty {
                paths += entry.sourceFiles.map { relativePath(of: $0, in: sourceRoot) }
            } else {
                paths.append(entry.captureFolder)
            }
        }
        return outermost(paths)
    }

    static func outermost(_ paths: [String]) -> [String] {
        var kept: [String] = []
        for path in Set(paths).sorted() where !path.isEmpty && !kept.contains(where: { path.hasPrefix($0 + "/") }) {
            kept.append(path)
        }
        return kept
    }

    /// A capture path under `sourceRoot`; nil for the source folder itself, Targets {year}, or anything outside it.
    private static func captureFolderURL(_ name: String, in sourceRoot: URL) -> URL? {
        let parts = name.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == "." || $0 == ".." || isTargetsFolder($0) }) else { return nil }
        return sourceRoot.appendingPathComponent(name)
    }

    /// Deepest paths first, so a capture inside another capture is handled before its parent.
    private static func deepestFirst(_ names: [String]) -> [String] {
        Set(names).sorted { ($0.split(separator: "/").count, $0) > ($1.split(separator: "/").count, $1) }
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
        let folders = outermost(names).filter { name in
            guard let url = captureFolderURL(name, in: sourceRoot) else { return false }
            return fm.fileExists(atPath: url.path)
        }
        guard !folders.isEmpty else { return nil }
        let archive = unusedURL(in: destinationParent, base: backupBaseName(name), extension: format.fileExtension)

        let rootPath = sourceRoot.standardizedFileURL.path + "/"
        var sizes: [String: Int64] = [:]
        for name in folders {
            let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
            let item = sourceRoot.appendingPathComponent(name)
            if let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
                sizes[name] = Int64(values.fileSize ?? 0)
                continue
            }
            guard let walk = fm.enumerator(at: item, includingPropertiesForKeys: keys) else { continue }
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

    /// Sends capture folders to the Trash (removing them if the volume has none) with the images inside them.
    /// `disposable` lists the extensions the user agreed to delete; JSON and astrometry files need `allowing`, and a folder
    /// holding any other file is kept.
    static func trashCaptureFolders(names: [String], sourceRoot: URL, disposable: Set<String> = keepFolderExtensions,
                                    allowing: DeletePermissions = .init()) -> FolderCleanup {
        cleanUp(names, sourceRoot: sourceRoot, disposable: disposable, allowing: allowing, trash: true)
    }

    static let calibrationDisposable = calibrationExtensions

    private static func cleanUp(_ names: [String], sourceRoot: URL, disposable: Set<String>,
                                allowing: DeletePermissions, trash: Bool) -> FolderCleanup {
        let fm = FileManager.default
        var result = FolderCleanup()
        for name in deepestFirst(names) {
            guard let folder = captureFolderURL(name, in: sourceRoot) else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let left = protectedFiles(in: folder, disposable: disposable)
            if !left.other.isEmpty {
                result.kept[name] = left.other
                continue
            }
            if left.blocked(by: allowing) {
                result.held[name] = left
                continue
            }
            do {
                if trash {
                    do { try fm.trashItem(at: folder, resultingItemURL: nil) } catch { try fm.removeItem(at: folder) }
                } else {
                    try fm.removeItem(at: folder)
                }
                result.removed += 1
            } catch {
                continue
            }
        }
        return result
    }

    /// Counts the files under `folder` that deleting it would take, apart from those with a `disposable` extension.
    /// Hidden files such as .DS_Store don't count.
    static func protectedFiles(in folder: URL, disposable: Set<String> = []) -> ProtectedFiles {
        var found = ProtectedFiles()
        let base = folder.standardizedFileURL
        let inPlateSolve = base.lastPathComponent.lowercased().contains("astrometry")
        guard let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return found }
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let name = url.lastPathComponent.lowercased()
            let ext = url.pathExtension.lowercased()
            let folders = url.standardizedFileURL.deletingLastPathComponent().path.dropFirst(base.path.count).lowercased()
            if inPlateSolve || name.hasPrefix("astrometry") || folders.contains("astrometry") {
                found.astrometry += 1
            } else if ext == "json" {
                found.json += 1
            } else if !disposable.contains(ext) {
                found.other[ext.isEmpty ? "(no extension)" : ext, default: 0] += 1
            }
        }
        return found
    }

    /// Image files still inside each capture folder that survived a sort, counted by lowercased extension.
    static func leftoverImages(captureNames: [String], sourceRoot: URL) -> [String: [String: Int]] {
        var kept: [String: [String: Int]] = [:]
        for name in Set(captureNames) {
            guard let folder = captureFolderURL(name, in: sourceRoot) else { continue }
            let files = imageFiles(under: folder, extensions: keepFolderExtensions)
            // Offering to trash this folder would take the plate solves or calibration frames the user chose to leave.
            guard !files.isEmpty, calibrationFolders(under: folder).isEmpty, plateSolveFolders(under: folder).isEmpty else { continue }
            kept[name] = files.reduce(into: [:]) { $0[$1.pathExtension.lowercased(), default: 0] += 1 }
        }
        return kept
    }

    /// True while any TIFF, FITS, JPG or PNG is left under the folder, sorted type or not.
    static func holdsImages(_ folder: URL) -> Bool {
        !imageFiles(under: folder, extensions: keepFolderExtensions).isEmpty
    }

    /// Removes capture folders a sort emptied. A folder holding any image or other file stays; one holding only JSON or
    /// astrometry files stays unless `allowing` permits them, and is listed in `held` so the user can be asked.
    @discardableResult
    static func removeSpentCaptureFolders(captureNames: [String], sourceRoot: URL, allowing: DeletePermissions = .init()) -> FolderCleanup {
        cleanUp(captureNames, sourceRoot: sourceRoot, disposable: [], allowing: allowing, trash: false)
    }

    // MARK: - Vaonis helpers

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
        let files = imageFolders.isEmpty ? imageFiles(under: observationFolder) : imageFolders.flatMap { imageFiles(under: $0) }
        return files.filter { !isSetupOrCalibrationFile($0, below: observationFolder) }
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
