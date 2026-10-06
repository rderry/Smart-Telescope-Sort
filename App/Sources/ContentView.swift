import SwiftUI
import AppKit

@MainActor
final class SortViewModel: ObservableObject {
    /// Detected from the Capture Folder on every refresh, unless the build is locked to one layout.
    @Published var telescopeKind: TelescopeKind {
        didSet { UserDefaults.standard.set(telescopeKind.rawValue, forKey: TelescopeKind.storageKey) }
    }
    @Published var layoutDetected = false
    @Published var fileTypes: Set<SortFileType> = Set(SortFileType.defaults) {
        didSet {
            UserDefaults.standard.set(fileTypes.map(\.rawValue).sorted(), forKey: Self.fileTypesKey)
            refreshInBackground()
        }
    }
    private static let fileTypesKey = "SmartTelescopeSort.fileTypes"
    /// JSON and astrometry files a folder may be deleted with without asking. Off by default.
    @Published var deletePermissions = DeletePermissions(
        json: UserDefaults.standard.bool(forKey: SortViewModel.deleteJSONKey),
        astrometry: UserDefaults.standard.bool(forKey: SortViewModel.deleteAstrometryKey)
    ) {
        didSet {
            UserDefaults.standard.set(deletePermissions.json, forKey: Self.deleteJSONKey)
            UserDefaults.standard.set(deletePermissions.astrometry, forKey: Self.deleteAstrometryKey)
        }
    }
    private static let deleteJSONKey = "SmartTelescopeSort.deleteJSON"
    private static let deleteAstrometryKey = "SmartTelescopeSort.deleteAstrometry"
    /// Zip or tarball made when the user says Yes to a backup before sorting; nil makes a folder copy instead.
    @Published var backupFormat: BackupFormat? = nil {
        didSet { UserDefaults.standard.set(backupFormat?.rawValue ?? "off", forKey: Self.backupFormatKey) }
    }
    private static let backupFormatKey = "SmartTelescopeSort.backupFormat"
    @Published var backupFailed = false
    /// Set while a zip or tarball backup runs; drives the progress sheet.
    @Published var backupProgress: ArchiveProgress?
    @Published var backupTitle = ""
    var backupStarted = Date()
    private var backupJob: ArchiveJob?
    var isBackingUp: Bool { backupJob != nil }

    /// Offer free archiver apps when the built-in one is missing or a backup just failed.
    var showArchiverLinks: Bool { !BackupFormat.systemArchiverAvailable || backupFailed }
    @Published var libraryFolders: [LibraryFolder: URL] = [:]
    @Published var savedDefaults: Set<LibraryFolder> = []
    private var sessionFolders: [String: URL] = [:]
    private var askedThisSession: Set<String> = []
    /// Empty until the user chooses a Capture Folder; nothing is scanned before that.
    @Published var sourcePath = ""
    @Published var selectedYear = "all"
    @Published var selectedMonth = "all"
    @Published var years: [String] = []
    @Published var entries: [CaptureEntry] = []
    @Published var summary = SortSummary()
    @Published var status = "Ready."
    @Published var sourceAvailable = false
    @Published var excluded = "Targets …"
    @Published var isBusy = false
    @Published var showCreateConfirm = false
    @Published var showSortConfirm = false
    @Published var showBackupOffer = false
    @Published var showPlanSheet = false
    @Published var showDuplicateConfirm = false
    @Published var planItems: [SortPlanItem] = []
    @Published var entryStatus: [String: String] = [:]
    @Published var pendingCreateYear: String?

    let months: [(id: String, title: String)] = [
        ("all", "All months"),
        ("01", "January"), ("02", "February"), ("03", "March"),
        ("04", "April"), ("05", "May"), ("06", "June"),
        ("07", "July"), ("08", "August"), ("09", "September"),
        ("10", "October"), ("11", "November"), ("12", "December"),
    ]

    let lockedKind = TelescopeKind.lockedFromBundle

    init() {
        if let path = ProcessInfo.processInfo.environment["STS_CAPTURES"], !path.isEmpty {
            sourcePath = path
        }
        if let locked = TelescopeKind.lockedFromBundle {
            telescopeKind = locked
        } else if let raw = ProcessInfo.processInfo.environment["STS_KIND"],
                  let kind = TelescopeKind(rawValue: raw) {
            telescopeKind = kind
        } else if let raw = UserDefaults.standard.string(forKey: TelescopeKind.storageKey),
           let kind = TelescopeKind(rawValue: raw) {
            telescopeKind = kind
        } else {
            telescopeKind = .vaonis
        }
        if let raw = UserDefaults.standard.stringArray(forKey: Self.fileTypesKey) {
            fileTypes = Set(raw.compactMap(SortFileType.init(rawValue:)))
        }
        if let raw = UserDefaults.standard.string(forKey: Self.backupFormatKey) {
            backupFormat = BackupFormat(rawValue: raw)
        }
        loadLibraryFolders()
    }

    var fileTypesSummary: String {
        let chosen = SortFileType.allCases.filter(fileTypes.contains)
        return chosen.isEmpty ? "no file types" : chosen.map(\.label).joined(separator: ", ")
    }

    // MARK: Library folders

    /// Where Targets {year} folders live: the chosen Target Folder (or its parent when a Targets {year}
    /// folder itself was picked), else the Capture Folder. When that folder holds no Targets {year} folder,
    /// the nearest folder above it that does is used.
    var targetsRoot: URL {
        let url = libraryFolders[.originals] ?? URL(fileURLWithPath: sourcePath)
        if url.lastPathComponent.range(of: Self.targetsYearPattern, options: .regularExpression) != nil {
            return url.deletingLastPathComponent()
        }
        return Self.folderHoldingTargets(from: url) ?? url
    }

    private static let targetsYearPattern = #"^Targets \d{4}$"#

    /// Where sorted images really go, shown under the Target Folder; a warning when that isn't the folder chosen.
    var targetFolderNote: (text: String, warning: Bool)? {
        guard hasCaptureFolder || libraryFolders[.originals] != nil else { return nil }
        let root = targetsRoot.standardizedFileURL
        let destination = "Sorted images go to \(root.path)/Targets {year}/{object}"
        guard let chosen = libraryFolders[.originals]?.standardizedFileURL else {
            return (destination + ".", false)
        }
        if chosen.lastPathComponent.range(of: Self.targetsYearPattern, options: .regularExpression) != nil || chosen == root {
            return (destination + ".", false)
        }
        let capture = URL(fileURLWithPath: sourcePath).standardizedFileURL.path + "/"
        let inside = hasCaptureFolder && (chosen.path + "/").hasPrefix(capture)
        return (destination + (inside
            ? ". The folder chosen is inside the Capture Folder, so the folder above it that holds Targets {year} is used. Choose that folder to avoid confusion."
            : ". The folder chosen holds no Targets {year} folder, so the folder above it that does is used."), true)
    }

    private static func folderHoldingTargets(from url: URL) -> URL? {
        var folder = url.standardizedFileURL
        while folder.pathComponents.count > 2 {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            if names.contains(where: { $0.range(of: targetsYearPattern, options: .regularExpression) != nil }) {
                return folder
            }
            folder = folder.deletingLastPathComponent()
        }
        return nil
    }

    private func sessionKey(_ folder: LibraryFolder) -> String { folder.rawValue }

    func loadLibraryFolders() {
        libraryFolders = [:]
        savedDefaults = []
        for folder in LibraryFolder.allCases {
            if let url = folder.saved() {
                libraryFolders[folder] = url
                savedDefaults.insert(folder)
            } else if let url = sessionFolders[sessionKey(folder)] {
                libraryFolders[folder] = url
            }
        }
    }

    /// Asks for any library folder with no default, once per session, after the window has appeared.
    func askLibraryFoldersIfNeeded() {
        let missing = LibraryFolder.allCases.filter {
            libraryFolders[$0] == nil && !askedThisSession.contains(sessionKey($0))
        }
        guard !missing.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            for folder in missing { self?.chooseLibraryFolder(folder) }
        }
    }

    func chooseLibraryFolder(_ folder: LibraryFolder) {
        askedThisSession.insert(sessionKey(folder))
        let capture = hasCaptureFolder ? URL(fileURLWithPath: sourcePath) : nil
        let start = libraryFolders[folder] ?? (folder == .originals ? capture : capture?.deletingLastPathComponent())
        guard let choice = folder.ask(startingAt: start) else {
            if libraryFolders[folder] == nil {
                status = folder == .originals
                    ? "Target Folder not set — Targets {year} folders go inside the Capture Folder."
                    : "\(folder.title) not set."
            }
            return
        }
        libraryFolders[folder] = choice.url
        if choice.saveAsDefault {
            folder.save(choice.url)
            savedDefaults.insert(folder)
            sessionFolders[sessionKey(folder)] = nil
        } else {
            folder.clearDefault()
            savedDefaults.remove(folder)
            sessionFolders[sessionKey(folder)] = choice.url
        }
        refreshInBackground()
    }

    var missingYears: [String] {
        Array(Set(entries.filter { !$0.targetExists }.map(\.year))).sorted()
    }

    var plannedCount: Int { summary.move }
    var actionableCount: Int { summary.move + summary.duplicates }

    var duplicateItems: [SortPlanItem] { planItems.filter(\.isDuplicate) }

    var duplicatePrompt: String {
        let folders = Set(duplicateItems.map(\.captureFolder)).count
        return "\(summary.duplicates) image file(s) in \(folders) capture folder(s) are byte-for-byte copies of files in Targets"
            + ". Delete them from the Capture Folder? They go to the Trash, the copies in the Target Folder are not touched, and capture folders left with no images to sort are removed."
    }

    static func statusText(_ items: [SortPlanItem]) -> String {
        let duplicates = items.filter(\.isDuplicate).count
        if duplicates == items.count {
            return duplicates == 1 ? "Duplicate" : "\(duplicates) duplicates"
        }
        let new = items.filter { $0.action == .move }.count
        var parts: [String] = []
        if new > 0 { parts.append("\(new) new") }
        if duplicates > 0 { parts.append("\(duplicates) duplicate") }
        return parts.joined(separator: " · ")
    }

    var spentCaptureNames: [String] {
        let grouped = Dictionary(grouping: entries, by: \.captureFolder)
        let root = URL(fileURLWithPath: sourcePath)
        return grouped.compactMap { name, rows in
            !name.isEmpty && rows.allSatisfy { $0.files == 0 } && !CaptureSorter.holdsImages(root.appendingPathComponent(name)) ? name : nil
        }.sorted()
    }

    var canSortOrCleanup: Bool {
        actionableCount > 0 || !spentCaptureNames.isEmpty || !finishedCaptureNames.isEmpty
    }

    /// Nothing to move or remove except finished folders still holding unchecked image types.
    var onlyFinishedFolders: Bool {
        actionableCount == 0 && spentCaptureNames.isEmpty && !finishedCaptureNames.isEmpty
    }

    private struct ScanInputs: Sendable {
        var root: URL
        var targetsRoot: URL
        var year: String?
        var month: String?
        var kind: TelescopeKind
        var detectLayout: Bool
        var extensions: Set<String>
    }

    private struct ScanOutput: Sendable {
        var detected: TelescopeKind?
        var entries: [CaptureEntry] = []
        var years: [String] = []
        var excluded = "Targets …"
        var sourceAvailable = false
        var plans: [SortPlanItem] = []
        var summary = SortSummary()
        var calibration: [SetAsideFolder] = []
        var plateSolves: [SetAsideFolder] = []
        var error: String?
        var cancelled = false
    }

    /// Bumped by every scan, so a background scan that finishes after a newer one is thrown away.
    private var scanGeneration = 0

    private func scanInputs() -> ScanInputs {
        ScanInputs(
            root: URL(fileURLWithPath: sourcePath),
            targetsRoot: targetsRoot,
            year: selectedYear == "all" ? nil : selectedYear,
            month: selectedMonth == "all" ? nil : selectedMonth,
            kind: telescopeKind,
            detectLayout: lockedKind == nil,
            extensions: fileTypes.reduce(into: []) { $0.formUnion($1.extensions) }
        )
    }

    /// The disk work of a refresh: walking the Capture Folder and comparing files with Targets. Runs off the main thread.
    nonisolated private static func scan(_ inputs: ScanInputs, monitor: ScanMonitor) -> ScanOutput {
        var output = ScanOutput()
        CaptureSorter.sortExtensions = inputs.extensions
        monitor.report(step: 1, "Detecting the telescope layout", force: true)
        output.detected = inputs.detectLayout ? TelescopeKind.detect(in: inputs.root) : nil
        do {
            let result = try CaptureSorter.scan(
                kind: output.detected ?? inputs.kind,
                sourceRoot: inputs.root,
                targetsRoot: inputs.targetsRoot,
                year: inputs.year,
                month: inputs.month,
                monitor: monitor
            )
            output.entries = result.entries
            output.years = result.years
            output.excluded = result.excluded
            output.sourceAvailable = FileManager.default.fileExists(atPath: inputs.root.path)
            (output.plans, output.summary) = CaptureSorter.preview(entries: result.entries, monitor: monitor)
            try monitor.checkCancelled()
            (output.plateSolves, output.calibration) = CaptureSorter.setAsideFolders(under: inputs.root, monitor: monitor)
            try monitor.checkCancelled()
        } catch is ScanMonitor.Cancelled {
            output.cancelled = true
        } catch {
            output.error = error.localizedDescription
        }
        return output
    }

    private func apply(_ output: ScanOutput) {
        if lockedKind == nil {
            layoutDetected = output.detected != nil
            if let detected = output.detected, detected != telescopeKind { telescopeKind = detected }
        }
        if let error = output.error {
            status = error
            entries = []
            summary = SortSummary()
            planItems = []
            entryStatus = [:]
            return
        }
        entries = output.entries
        years = output.years
        excluded = output.excluded
        sourceAvailable = output.sourceAvailable
        summary = output.summary
        planItems = output.plans
        entryStatus = Dictionary(grouping: planItems, by: \.entryID).mapValues(Self.statusText)
        calibrationFolders = output.calibration
        plateSolveFolders = output.plateSolves
        status = !sourceAvailable ? "Capture Folder unavailable."
            : fileTypes.isEmpty ? "Check at least one file type under Files to Move."
            : "Preview ready for \(telescopeKind.menuTitle) (\(fileTypesSummary)) — no files have been moved."
                + (plateSolveFolders.isEmpty && calibrationFolders.isEmpty ? ""
                    : " \(plateSolveFolders.count) plate-solve and \(calibrationFolders.count) calibration folder(s) are left out; you'll be asked about them after sorting.")
        if selectedYear != "all", !years.contains(selectedYear), let first = years.first {
            selectedYear = first
        }
    }

    var hasCaptureFolder: Bool { !sourcePath.isEmpty }

    /// Set while a scan runs; drives the progress sheet.
    @Published var scanProgress: ScanProgress?
    var scanStarted = Date()
    private var scanMonitor: ScanMonitor?

    /// Scans the Capture Folder in the background with the progress sheet up, then runs `completion` with the new plan
    /// in place. Nothing is scanned until a Capture Folder has been chosen.
    func refreshInBackground(then completion: (() -> Void)? = nil) {
        guard hasCaptureFolder else {
            status = "Choose a Capture Folder to start: click Choose… next to Capture Folder."
            return
        }
        scanGeneration += 1
        let generation = scanGeneration
        scanMonitor?.cancel()
        let monitor = ScanMonitor { [weak self] progress in
            Task { @MainActor in
                guard let self, generation == self.scanGeneration, self.scanProgress != nil else { return }
                self.scanProgress = progress
            }
        }
        scanMonitor = monitor
        let inputs = scanInputs()
        isBusy = true
        sourceAvailable = FileManager.default.fileExists(atPath: inputs.root.path)
        status = "Scanning the Capture Folder…"
        scanStarted = Date()
        scanProgress = ScanProgress(step: 1, phase: "Starting")
        Task.detached(priority: .userInitiated) {
            let output = Self.scan(inputs, monitor: monitor)
            await MainActor.run { [weak self] in
                guard let self, generation == self.scanGeneration else { return }
                self.scanProgress = nil
                self.scanMonitor = nil
                self.isBusy = false
                if output.cancelled {
                    self.status = "Scan cancelled. The list shows the last finished scan; click Refresh preview to scan again."
                    return
                }
                self.apply(output)
                completion?()
            }
        }
    }

    func cancelScan() {
        scanMonitor?.cancel()
    }

    private static let lastCaptureFolderKey = "SmartTelescopeSort.lastCaptureFolder"

    /// After the launch popup closes: ask for the Capture Folder, then any library folder without a default, then scan.
    func start() {
        if hasCaptureFolder {
            askLibraryFoldersIfNeeded()
            refreshInBackground()
        } else {
            DispatchQueue.main.async { [weak self] in self?.chooseSourceFolder() }
        }
    }

    /// Opens the per-folder file list (does not move files).
    func reviewFilePlan() {
        refreshInBackground { [weak self] in
            guard let self else { return }
            if self.planItems.isEmpty, self.entries.isEmpty {
                self.status = "No plan yet — choose a Capture Folder that holds your telescope's images, then try again."
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.showPlanSheet = true }
        }
    }

    func chooseSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose the Capture Folder"
        panel.message = "Choose the Capture Folder: where your telescope's images are located. Nothing is scanned until you choose."
        panel.prompt = "Scan This Folder"
        let last = UserDefaults.standard.string(forKey: Self.lastCaptureFolderKey)
        panel.directoryURL = URL(fileURLWithPath: hasCaptureFolder ? sourcePath : last ?? "/Volumes")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            if !hasCaptureFolder {
                status = "Choose a Capture Folder to start: click Choose… next to Capture Folder."
            }
            return
        }
        sourcePath = url.path
        UserDefaults.standard.set(url.path, forKey: Self.lastCaptureFolderKey)
        askLibraryFoldersIfNeeded()
        refreshInBackground()
    }

    func createMissingTarget() {
        guard let year = pendingCreateYear ?? missingYears.first else { return }
        do {
            let created = try CaptureSorter.createTargetsFolder(year: year, targetsRoot: targetsRoot)
            refreshInBackground { [weak self] in self?.status = "Created \(created.path). No capture files were moved." }
        } catch {
            status = error.localizedDescription
        }
    }

    func beginSortFlow() {
        guard canSortOrCleanup, !isBackingUp else { return }
        if onlyFinishedFolders {
            askAboutFinishedFolders()
            return
        }
        if plannedCount == 0, summary.duplicates > 0 {
            showDuplicateConfirm = true
            return
        }
        showBackupOffer = true
    }

    /// Yes in the "Back up before sorting?" dialog: the chosen archive format, or a folder copy when the format is Off.
    func backUpThenConfirmSort() {
        if let format = backupFormat {
            Task { await archiveThenConfirmSort(format) }
        } else {
            chooseBackupLocationAndRun()
        }
    }

    var backupOfferMessage: String {
        let destination = libraryFolders[.backup]?.path ?? "Backup Storage (you'll be asked where)"
        let kind = backupFormat.map { "a \($0.label) archive (.\($0.fileExtension))" } ?? "a copy"
        return "Yes saves \(kind) of the capture folders in \(destination) before anything moves. No sorts without a backup."
    }

    /// Zip and/or tarball backup of the capture folders into Backup Storage; the sort is only offered once it succeeds.
    func archiveThenConfirmSort(_ format: BackupFormat) async {
        guard BackupFormat.systemArchiverAvailable else {
            backupFailed = true
            status = "This Mac's built-in archiver (/usr/bin/tar) is missing — nothing was moved. Use one of the free archivers below, or sort again and answer No to the backup."
            return
        }
        if libraryFolders[.backup] == nil {
            chooseLibraryFolder(.backup)
        }
        guard let destination = libraryFolders[.backup] else {
            status = "No Backup Storage location — nothing was moved."
            return
        }
        guard !isBackingUp else { return }
        guard let backupName = askBackupName(kind: "\(format.label) (.\(format.fileExtension))", destination: destination) else {
            status = "Backup cancelled — nothing was moved."
            return
        }
        let source = URL(fileURLWithPath: sourcePath)
        let names = CaptureSorter.backupPaths(for: entries, sourceRoot: source)
        let job = ArchiveJob()
        backupJob = job
        backupStarted = Date()
        backupTitle = "\(backupName).\(format.fileExtension) → \(destination.path)"
        backupProgress = ArchiveProgress()
        status = "Creating \(format.label) backup in \(destination.path)…"
        defer {
            backupJob = nil
            backupProgress = nil
        }
        let report: @Sendable (ArchiveProgress) -> Void = { [weak self] progress in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self?.backupJob === job { self?.backupProgress = progress }
                }
            }
        }
        do {
            let archive = try await Task.detached(priority: .userInitiated) {
                try CaptureSorter.archiveCaptureFolders(
                    names: names, sourceRoot: source, destinationParent: destination, format: format,
                    name: backupName, job: job, progress: report
                )
            }.value
            backupFailed = false
            status = archive.map { "Backup complete: \($0.lastPathComponent) in \(destination.path)" } ?? "No capture folders to back up."
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showSortConfirm = true
            }
        } catch is ArchiveJob.Cancelled {
            status = "Backup cancelled — nothing was moved."
        } catch {
            backupFailed = true
            status = "Backup failed — nothing was moved. \(error.localizedDescription)"
        }
    }

    func cancelBackup() {
        backupJob?.cancel()
    }

    /// Objects being sorted plus the date and time, e.g. "MOON Backup 2026-10-03 15-27".
    var suggestedBackupName: String {
        let objects = Array(Set(entries.filter { $0.files > 0 }.map(\.object))).sorted()
        let label = objects.isEmpty ? "Captures" : objects.count <= 3 ? objects.joined(separator: " ") : "\(objects.count) objects"
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH-mm"
        return "\(label) Backup \(stamp.string(from: Date()))"
    }

    /// Asks what to call the backup; nil when cancelled.
    private func askBackupName(kind: String, destination: URL) -> String? {
        let alert = NSAlert()
        alert.messageText = "Name this backup"
        alert.informativeText = "\(kind) of the capture folders will be saved in \(destination.path). A number is added if the name is already used."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.stringValue = suggestedBackupName
        field.placeholderString = CaptureSorter.defaultBackupName
        alert.accessoryView = field
        alert.addButton(withTitle: "Start Backup")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return CaptureSorter.backupBaseName(field.stringValue)
    }

    func deleteDuplicates() {
        let source = URL(fileURLWithPath: sourcePath)
        let result = CaptureSorter.deleteDuplicates(duplicateItems, sourceRoot: source, allowing: withoutAstrometry)
        let removedHeld = askToDeleteHeld(result.held, offerAstrometry: false) { allowing in
            CaptureSorter.removeSpentCaptureFolders(captureNames: Array(result.held.keys), sourceRoot: source, allowing: allowing)
        }
        refreshInBackground { [weak self] in
            self?.status = "Deleted \(result.deleted) duplicate(s) from the Capture Folder and removed \(result.removedFolders + removedHeld) emptied capture folder(s)."
                + (result.skipped > 0 ? " \(result.skipped) skipped because they changed since the preview." : "")
        }
    }

    func keepDuplicates() {
        status = "Kept \(summary.duplicates) duplicate(s) in the Capture Folder. They stay marked Duplicate, and their capture folders stay until they are deleted."
    }

    func chooseBackupLocationAndRun() {
        if libraryFolders[.backup] == nil {
            chooseLibraryFolder(.backup)
        }
        guard let url = libraryFolders[.backup],
              let backupName = askBackupName(kind: "A folder copy", destination: url) else {
            status = "Backup cancelled — nothing was moved."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try CaptureSorter.backupCaptureFolders(
                entries: entries,
                sourceRoot: URL(fileURLWithPath: sourcePath),
                destinationParent: url,
                name: backupName
            )
            status = "Backup complete: \(result.folders) folders (\(result.files) image files) → \(result.destination.path)"
            showSortConfirm = true
        } catch {
            status = "Backup failed: \(error.localizedDescription)"
        }
    }

    func performSort() {
        guard entries.contains(where: { $0.needsObjectName && $0.files > 0 }) else {
            sort(entries)
            return
        }
        // Wait for the confirmation dialog to close before asking for names.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            guard let rows = self.askObjectNames(for: self.entries) else {
                self.status = "Sort cancelled — nothing was moved."
                return
            }
            self.sort(rows)
        }
    }

    /// Names every row whose folders don't name an object, all in one list. Unchecked rows are left out, so their
    /// files stay in the Capture Folder; nil when the user cancels the sort.
    private func askObjectNames(for rows: [CaptureEntry]) -> [CaptureEntry]? {
        let unnamed = rows.filter { $0.needsObjectName && $0.files > 0 }
        let groups = Dictionary(grouping: unnamed, by: \.captureFolder)
        let requests = groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key -> NameRequest in
            let group = groups[key] ?? []
            return NameRequest(
                key: key,
                label: key.isEmpty ? URL(fileURLWithPath: sourcePath).lastPathComponent : key,
                detail: "\(group.reduce(0) { $0 + $1.files }) image(s) · \(group.first?.yearFolder.lastPathComponent ?? "")",
                suggestion: group.first?.sessionDate ?? "")
        }
        let choices = Set(unnamed.map(\.yearFolder)).flatMap(Self.folderNames(in:))
        guard let names = askNames(
            title: "Name the \(requests.count) folder(s) with no object name",
            message: "No folder names a DSO or other celestial object for these images. Each is filled in with its date; keep it, "
                + "pick an object already in Targets {year}, or type a name. Uncheck a folder to leave its images in the Capture Folder.",
            requests: requests,
            choices: choices,
            okTitle: "Sort All",
            cancelTitle: "Cancel Sort"
        ) else { return nil }
        return rows.compactMap { row in
            guard row.needsObjectName, row.files > 0 else { return row }
            return names[row.captureFolder].map(row.named)
        }
    }

    private struct NameRequest {
        let key: String
        let label: String
        let detail: String
        let suggestion: String
    }

    /// One dialog listing every request with a checkbox and a name box (existing `choices` offered). Returns the names
    /// of the checked rows by key; nil when cancelled.
    private func askNames(title: String, message: String, requests: [NameRequest], choices: [String],
                          okTitle: String, cancelTitle: String) -> [String: String]? {
        let choices = Array(Set(choices)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var checks: [NSButton] = []
        var boxes: [NSComboBox] = []
        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        for request in requests {
            let check = NSButton(checkboxWithTitle: request.label, target: nil, action: nil)
            check.state = .on
            check.lineBreakMode = .byTruncatingMiddle
            check.widthAnchor.constraint(equalToConstant: 300).isActive = true
            let box = NSComboBox()
            box.addItems(withObjectValues: choices)
            box.completes = true
            box.numberOfVisibleItems = 14
            box.placeholderString = "e.g. M31, NGC7000, Moon"
            box.stringValue = request.suggestion
            box.widthAnchor.constraint(equalToConstant: 220).isActive = true
            let detail = NSTextField(labelWithString: request.detail)
            detail.textColor = .secondaryLabelColor
            detail.font = .systemFont(ofSize: 11)
            grid.addRow(with: [check, box, detail])
            checks.append(check)
            boxes.append(box)
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            grid.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 4),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -4),
            grid.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4),
        ])
        let height = min(CGFloat(requests.count) * 32 + 8, 380)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 720, height: height))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = scroll
        alert.addButton(withTitle: okTitle)
        alert.addButton(withTitle: cancelTitle)
        NSApp.activate(ignoringOtherApps: true)

        while true {
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            var names: [String: String] = [:]
            var blank = false
            for (index, request) in requests.enumerated() where checks[index].state == .on {
                let name = Self.folderName(boxes[index].stringValue)
                if name.isEmpty { blank = true } else { names[request.key] = name }
            }
            if !blank { return names }
            NSSound.beep()
        }
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private static func folderNames(in parent: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
    }

    /// A typed object name made safe for a folder: no slashes or colons, no surrounding spaces or dots.
    private static func folderName(_ typed: String) -> String {
        typed.replacingOccurrences(of: #"[/:\\]"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
    }

    /// Set while files are copied or originals deleted; drives the transfer progress sheet.
    @Published var transferProgress: TransferProgress?
    /// Title and note for the transfer sheet when the job isn't a sort.
    var transferExplanation: (title: String, note: String)?
    var transferStarted = Date()
    private var transferMonitor: TransferMonitor?
    private var transferGeneration = 0
    /// Copied and checked during this sort. Deleted only when the user says Yes twice once every move is done.
    private var pendingOriginals: [CopiedItem] = []

    /// Runs `work` off the main thread with the transfer sheet up, then `completion` with its result and whether the
    /// user stopped it.
    private func runTransfer<T: Sendable>(_ phase: String, deleting: Bool = false,
                                          explanation: (title: String, note: String)? = nil,
                                          work: @escaping @Sendable (TransferMonitor) -> T,
                                          then completion: @escaping (T, _ stopped: Bool) -> Void) {
        transferExplanation = explanation
        transferGeneration += 1
        let generation = transferGeneration
        let monitor = TransferMonitor { [weak self] progress in
            Task { @MainActor in
                guard let self, generation == self.transferGeneration, self.transferProgress != nil else { return }
                self.transferProgress = progress
            }
        }
        transferMonitor = monitor
        isBusy = true
        transferStarted = Date()
        transferProgress = TransferProgress(phase: phase, deleting: deleting)
        Task.detached(priority: .userInitiated) {
            let result = work(monitor)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.transferProgress = nil
                self.transferMonitor = nil
                self.isBusy = false
                completion(result, monitor.isCancelled)
            }
        }
    }

    func stopTransfer() {
        transferMonitor?.cancel()
    }

    /// Waits for the sheet that just closed before showing the next question.
    private func next(_ step: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            step()
        }
    }

    /// Copy then delete: copies and checks every file, asks about plate solves and calibration folders, and only then
    /// offers to delete the originals.
    private func sort(_ rows: [CaptureEntry]) {
        let source = URL(fileURLWithPath: sourcePath)
        let targets = targetsRoot
        let sorted = rows.map(\.captureFolder)
        pendingOriginals = []
        runTransfer("Copying images", work: { monitor in
            CaptureSorter.copySort(entries: rows, sourceRoot: source, targetsRoot: targets, monitor: monitor)
        }, then: { [weak self] result, stopped in
            guard let self else { return }
            if let error = result.error {
                self.status = error
                return
            }
            self.pendingOriginals = result.copied
            self.status = "Copied \(result.copied.count) image file(s) into Targets {year}/{object}, each checked byte for byte."
                + (result.failed.isEmpty ? "" : " \(result.failed.count) couldn't be copied and stay where they are.")
                + (stopped ? " Copying was stopped early." : "")
            self.next {
                if stopped {
                    self.askToDeleteOriginals(sorted: sorted)
                } else {
                    self.askAboutSetAsideFolders(.plateSolves) {
                        self.askAboutSetAsideFolders(.calibration) { self.askToDeleteOriginals(sorted: sorted) }
                    }
                }
            }
        })
    }

    /// Once every move is done: asks twice before deleting the originals that were copied, then tidies emptied folders.
    private func askToDeleteOriginals(sorted: [String]) {
        let items = pendingOriginals
        pendingOriginals = []
        guard !items.isEmpty else {
            finishCleanup(sorted: sorted, originalsDeleted: true)
            return
        }
        let files = items.filter { !$0.isFolder }.count
        let folders = items.count - files
        let what = [files > 0 ? "\(files) image file(s)" : nil, folders > 0 ? "\(folders) plate-solve or calibration folder(s)" : nil]
            .compactMap { $0 }.joined(separator: " and ")

        let first = NSAlert()
        first.messageText = "All moves are done. Delete the original folders and files?"
        first.informativeText = "\(what) were copied and each copy was checked byte for byte against its original. "
            + "The originals are still in the Capture Folder.\n\nYes deletes the originals. No keeps them; the next scan marks them Duplicate."
        guard Self.confirm(first) else {
            keepOriginals(sorted: sorted, what: what)
            return
        }
        let second = NSAlert()
        second.messageText = "Are you sure?"
        second.informativeText = "This moves \(what) from the Capture Folder to the Trash (or deletes them outright on a drive without one). "
            + "The copies in the Target Folder are not touched."
        guard Self.confirm(second) else {
            keepOriginals(sorted: sorted, what: what)
            return
        }
        runTransfer("Deleting originals", deleting: true, work: { monitor in
            CaptureSorter.deleteOriginals(items, monitor: monitor)
        }, then: { [weak self] result, _ in
            guard let self else { return }
            self.status += " Deleted \(result.deleted) original(s)."
                + (result.skipped.isEmpty ? "" : " \(result.skipped.count) kept because they or their copies changed, or deleting was stopped.")
            self.next { self.finishCleanup(sorted: sorted, originalsDeleted: true) }
        })
    }

    /// A Yes/No question with No as the default.
    private static func confirm(_ alert: NSAlert) -> Bool {
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func keepOriginals(sorted: [String], what: String) {
        status += " Kept the originals of \(what) in the Capture Folder."
        finishCleanup(sorted: sorted, originalsDeleted: false)
    }

    /// Removes capture folders the sort left empty, rescans the Capture Folder and, when the originals were deleted,
    /// offers to delete the processed capture folders and everything left in them.
    private func finishCleanup(sorted: [String], originalsDeleted: Bool) {
        if originalsDeleted {
            let source = URL(fileURLWithPath: sourcePath)
            let plateSolvesGone = CaptureSorter.plateSolveFolders(under: source).isEmpty
            let spent = CaptureSorter.removeSpentCaptureFolders(
                captureNames: sorted, sourceRoot: source,
                allowing: DeletePermissions(json: deletePermissions.json, astrometry: deletePermissions.astrometry && plateSolvesGone))
            if spent.removed > 0 {
                status += " Removed \(spent.removed) emptied capture folder(s)."
            }
        }
        let message = status
        refreshInBackground { [weak self] in
            guard let self else { return }
            self.status = message
            if originalsDeleted {
                self.next { self.askToDeleteProcessedFolders(sorted: sorted) }
            }
        }
    }

    /// After the rescan: offers to delete the capture folders this sort processed and all the data left in them, asking
    /// Yes/No twice. Never offers the Capture Folder itself, a folder holding Targets, the Target Folder or Backup Storage,
    /// or a folder still holding images that aren't in Targets yet.
    private func askToDeleteProcessedFolders(sorted: [String]) {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: sourcePath).standardizedFileURL
        let guarded = [targetsRoot, libraryFolders[.originals], libraryFolders[.backup]].compactMap { $0?.standardizedFileURL.path }
        let unsorted = Set(planItems.filter { $0.action == .move }.map(\.captureFolder))
        var stillUnsorted = 0
        let names = CaptureSorter.outermost(sorted).filter { name in
            let path = source.appendingPathComponent(name).standardizedFileURL.path
            guard fm.fileExists(atPath: path), !guarded.contains(where: { ($0 + "/").hasPrefix(path + "/") }) else { return false }
            if unsorted.contains(where: { $0 == name || $0.hasPrefix(name + "/") }) {
                stillUnsorted += 1
                return false
            }
            return true
        }
        let keptNote = stillUnsorted > 0 ? " \(stillUnsorted) processed folder(s) kept because they still hold images not in Targets yet." : ""
        guard !names.isEmpty else {
            status += keptNote
            return
        }
        let contents = names.map { CaptureSorter.protectedFiles(in: source.appendingPathComponent($0)) }
        func summary(_ files: ProtectedFiles) -> String {
            let parts = [files.json > 0 ? "\(files.json) JSON" : nil, files.astrometry > 0 ? "\(files.astrometry) plate-solve" : nil]
                .compactMap { $0 } + files.other.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key.uppercased())" }
            return parts.isEmpty ? "empty folders only" : parts.joined(separator: ", ")
        }
        var total = ProtectedFiles()
        for files in contents {
            total.json += files.json
            total.astrometry += files.astrometry
            total.other.merge(files.other, uniquingKeysWith: +)
        }
        let fileCount = total.json + total.astrometry + total.other.values.reduce(0, +)
        let shown = 10
        let lines = zip(names, contents).prefix(shown).map { "• \($0): \(summary($1))" }

        let first = NSAlert()
        first.messageText = "Processing is done. Delete the \(names.count) capture folder(s) and their data?"
        first.informativeText = "The Capture Folder was scanned again. Everything sorted is in Targets {year}. Left in these folders:\n"
            + lines.joined(separator: "\n")
            + (names.count > shown ? "\n…and \(names.count - shown) more" : "")
            + "\n\nIn all: \(summary(total)).\(keptNote)\n\nYes deletes these folders and everything in them. No keeps them."
        guard Self.confirm(first) else {
            status += " Kept the processed capture folders." + keptNote
            return
        }
        let second = NSAlert()
        second.messageText = "Are you sure?"
        second.informativeText = "This moves \(names.count) folder(s) and \(fileCount) file(s) (\(summary(total))) from the Capture Folder "
            + "to the Trash, or deletes them outright on a drive without one. Your sorted images in Targets are not touched."
        guard Self.confirm(second) else {
            status += " Kept the processed capture folders." + keptNote
            return
        }
        let folders = names.map { source.appendingPathComponent($0, isDirectory: true) }
        runTransfer("Deleting capture folders", deleting: true, work: { monitor in
            CaptureSorter.trashFolders(folders, monitor: monitor)
        }, then: { [weak self] result, _ in
            guard let self else { return }
            let message = self.status + " Deleted \(result.deleted) processed capture folder(s)."
                + (result.skipped.isEmpty ? "" : " \(result.skipped.count) couldn't be deleted.") + keptNote
            self.refreshInBackground { self.status = message }
        })
    }

    /// Finds byte-identical numbered copies ("IMG_0001 2.jpg"…) in each Targets {year}/{object} folder, lists them and
    /// asks Yes/No twice before moving the extras to the Trash. One copy of each file is always kept.
    func removeIdenticalCopiesInTargets() {
        let targets = targetsRoot
        runTransfer("Finding identical copies in Targets",
                    explanation: ("Finding identical copies in Targets",
                                  "Each Targets {year}/{object} folder is searched for files whose names differ only by a number "
                                  + "and whose bytes are the same. Nothing is deleted now; you're asked twice first."),
                    work: { monitor in
            CaptureSorter.findRedundantCopies(targetsRoot: targets, monitor: monitor)
        }, then: { [weak self] sets, stopped in
            guard let self else { return }
            if stopped {
                self.status = "Stopped looking for identical copies in Targets. Nothing was deleted."
                return
            }
            guard !sets.isEmpty else {
                self.status = "No identical copies found in \(targets.path)/Targets {year}."
                let alert = NSAlert()
                alert.messageText = "No identical copies in Targets"
                alert.informativeText = "Every image in each Targets {year}/{object} folder is different from the others."
                self.next { alert.runModal() }
                return
            }
            self.next { self.askToRemoveRedundantCopies(sets, targetsRoot: targets) }
        })
    }

    private func askToRemoveRedundantCopies(_ sets: [RedundantCopies], targetsRoot: URL) {
        let extras = sets.flatMap(\.extras)
        let bytes = extras.reduce(Int64(0)) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let rootDepth = targetsRoot.standardizedFileURL.pathComponents.count
        let byObject = Dictionary(grouping: sets) { $0.keep.standardizedFileURL.pathComponents.dropFirst(rootDepth).prefix(2).joined(separator: "/") }
            .mapValues { $0.reduce(0) { $0 + $1.extras.count } }
            .sorted { ($1.value, $0.key) < ($0.value, $1.key) }
        let shown = 10
        let lines = byObject.prefix(shown).map { "• \($0.key): \($0.value) extra" }
        let example = sets[0]

        let first = NSAlert()
        first.messageText = "Delete \(extras.count) identical copies in Targets?"
        first.informativeText = "Earlier sorts gave clashing names a number, so some images were saved more than once. These files are byte-for-byte "
            + "the same as another file in the same object folder; one copy of each is kept, the un-numbered one when there is one.\n\n"
            + lines.joined(separator: "\n")
            + (byObject.count > shown ? "\n…and \(byObject.count - shown) more folders" : "")
            + "\n\nFor example \(example.keep.lastPathComponent) is kept and \(example.extras.map(\.lastPathComponent).joined(separator: ", ")) go.\n\n"
            + "In all: \(extras.count) extra copies of \(sets.count) file(s), \(size).\n\nYes deletes the extra copies. No keeps everything."
        guard Self.confirm(first) else {
            status = "Kept all \(extras.count) identical copies in Targets."
            return
        }
        let second = NSAlert()
        second.messageText = "Are you sure?"
        second.informativeText = "This moves \(extras.count) file(s) (\(size)) from the Target Folder to the Trash, or deletes them outright on a drive "
            + "without one. Each is read again and compared byte for byte with the copy that's kept just before it goes. The kept copies are not touched."
        guard Self.confirm(second) else {
            status = "Kept all \(extras.count) identical copies in Targets."
            return
        }
        runTransfer("Deleting identical copies in Targets", deleting: true,
                    explanation: ("Deleting identical copies in Targets",
                                  "You said Yes twice. One copy of each image stays in Targets; the extra copies go to the Trash."),
                    work: { monitor in
            CaptureSorter.removeRedundantCopies(sets, monitor: monitor)
        }, then: { [weak self] result, _ in
            guard let self else { return }
            let message = "Deleted \(result.deleted) identical copies from Targets "
                + "(\(ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file)))."
                + (result.skipped.isEmpty ? "" : " \(result.skipped.count) kept because they changed, or deleting was stopped.")
            self.refreshInBackground { self.status = message }
        })
    }


    /// Lights, Darks, Dark Flats, Flats, Bias and Master* folders in the Capture Folder, never sorted into Targets.
    @Published var calibrationFolders: [SetAsideFolder] = []
    /// Plate-solve (astrometry) folders in the Capture Folder, never sorted into Targets.
    @Published var plateSolveFolders: [SetAsideFolder] = []

    enum SetAsideKind {
        case plateSolves, calibration

        var noun: String { self == .plateSolves ? "plate-solve folder" : "calibration folder" }

        var explanation: String {
            self == .plateSolves
                ? "Plate-solve frames (astrometry.jpeg) the telescope took while pointing and guiding are kept out of the Target Folder:"
                : "Lights, Darks, Dark Flats, Flats, Bias and Master* folders are kept out of the Target Folder:"
        }

        func folders(under root: URL) -> [SetAsideFolder] {
            self == .plateSolves ? CaptureSorter.plateSolveFolders(under: root) : CaptureSorter.calibrationFolders(under: root)
        }
    }

    /// Plate-solve moves with every object named, asking in one list for the sessions no folder names. Unchecked
    /// sessions are left out; nil when the user leaves them all.
    private func namedPlateSolveMoves(_ folders: [SetAsideFolder]) -> [CaptureSorter.PlateSolveMove]? {
        let moves = CaptureSorter.plateSolveMoves(folders, sourceRoot: URL(fileURLWithPath: sourcePath))
        let unnamed = Dictionary(grouping: moves.filter { $0.object == nil }, by: \.session)
        guard !unnamed.isEmpty else { return moves }
        let requests = unnamed.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { session -> NameRequest in
            let group = unnamed[session] ?? []
            return NameRequest(
                key: session,
                label: group.first?.path ?? session,
                detail: "\(group.count) folder(s) · \(group.reduce(0) { $0 + $1.images }) image(s)",
                suggestion: group.first?.sessionDate ?? "")
        }
        guard let names = askNames(
            title: "Name the \(requests.count) plate-solve session(s) with no object name",
            message: "No folder names a DSO or other celestial object for these plate solves. Each is filled in with its date; keep it, "
                + "pick an object already in Targets {year}, or type a name. They go to Targets {year}/{name}/\(CaptureSorter.plateSolvesFolderName). "
                + "Uncheck a session to leave it in the Capture Folder.",
            requests: requests,
            choices: Set(unnamed.values.joined().map(\.year)).flatMap { year in
                Self.folderNames(in: targetsRoot.appendingPathComponent("Targets \(year)", isDirectory: true))
            },
            okTitle: "Move All",
            cancelTitle: "Leave All Plate Solves"
        ) else { return nil }
        return moves.compactMap { move in
            guard move.object == nil else { return move }
            guard let name = names[move.session] else { return nil }
            var named = move
            named.object = name
            return named
        }
    }

    /// Asks whether to move, leave or delete one kind of set-aside folder, then runs `done`. Move copies the folders and
    /// adds them to the originals offered for deletion at the end of the sort.
    func askAboutSetAsideFolders(_ kind: SetAsideKind, then done: @escaping () -> Void) {
        let source = URL(fileURLWithPath: sourcePath)
        let folders = kind.folders(under: source)
        guard !folders.isEmpty else {
            done()
            return
        }
        let noun = folders.count == 1 ? kind.noun : kind.noun + "s"
        let shown = 10
        let lines = folders.prefix(shown).map { "• \($0.path): \(Self.describe([$0.images]))" }
        let alert = NSAlert()
        alert.messageText = "\(folders.count) \(noun) \(folders.count == 1 ? "was" : "were") not sorted"
        alert.informativeText = kind.explanation + "\n"
            + lines.joined(separator: "\n")
            + (folders.count > shown ? "\n…and \(folders.count - shown) more (\(Self.describe(folders.map(\.images))) in all)" : "")
            + (kind == .plateSolves
                ? "\n\nMove puts each one with its object's images in Targets {year}/{object}/\(CaptureSorter.plateSolvesFolderName)/{session}. "
                    + "Or leave them in the Capture Folder, or delete them (they go to the Trash)."
                : "\n\nMove them to a folder you choose, leave them in the Capture Folder, or delete them (they go to the Trash).")
        alert.addButton(withTitle: kind == .plateSolves ? "Move to Targets" : "Move…")
        alert.addButton(withTitle: "Leave")
        alert.addButton(withTitle: "Delete")
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        alert.buttons[2].hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)

        let paths = folders.map(\.path)
        let left = " Left \(folders.count) \(noun) in the Capture Folder."
        switch alert.runModal() {
        case .alertFirstButtonReturn where kind == .plateSolves:
            guard let moves = namedPlateSolveMoves(folders) else {
                status += left
                break
            }
            let targets = targetsRoot
            runTransfer("Copying plate solves", work: { monitor in
                CaptureSorter.copyPlateSolves(moves, sourceRoot: source, targetsRoot: targets, monitor: monitor)
            }, then: { [weak self] result, _ in
                guard let self else { return }
                self.pendingOriginals += result.copied
                self.status += " Copied \(result.copied.count) plate-solve folder(s) in with their images: Targets {year}/{object}/\(CaptureSorter.plateSolvesFolderName)."
                    + (result.failed.isEmpty ? "" : " \(result.failed.count) couldn't be copied.")
                self.next(done)
            })
            return
        case .alertFirstButtonReturn:
            let panel = NSOpenPanel()
            panel.title = "Where should the \(kind.noun)s go?"
            panel.message = "Each folder keeps its path from the Capture Folder, so folders with the same name don't collide."
            panel.prompt = "Move Here"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = libraryFolders[.originals] ?? source.deletingLastPathComponent()
            guard panel.runModal() == .OK, let destination = panel.url else {
                status += left
                break
            }
            runTransfer("Copying \(kind.noun)s", work: { monitor in
                CaptureSorter.copySetAsideFolders(paths, sourceRoot: source, to: destination, monitor: monitor)
            }, then: { [weak self] result, _ in
                guard let self else { return }
                self.pendingOriginals += result.copied
                self.status += " Copied \(result.copied.count) \(kind.noun)(s) to \(destination.path)."
                    + (result.failed.isEmpty ? "" : " \(result.failed.count) couldn't be copied.")
                self.next(done)
            })
            return
        case .alertThirdButtonReturn:
            let confirm = NSAlert()
            confirm.messageText = "Delete \(folders.count) \(noun)?"
            confirm.informativeText = "They go to the Trash with everything inside them."
            confirm.addButton(withTitle: "Delete")
            confirm.addButton(withTitle: "Cancel")
            confirm.buttons[0].hasDestructiveAction = true
            guard confirm.runModal() == .alertFirstButtonReturn else {
                status += left
                break
            }
            var result: FolderCleanup
            if kind == .plateSolves {
                result = CaptureSorter.trashCaptureFolders(names: paths, sourceRoot: source, disposable: [],
                                                           allowing: DeletePermissions(json: true, astrometry: true))
            } else {
                result = CaptureSorter.trashCaptureFolders(names: paths, sourceRoot: source,
                                                           disposable: CaptureSorter.calibrationDisposable, allowing: withoutAstrometry)
                let held = result.held
                result.removed += askToDeleteHeld(held, offerAstrometry: false) { allowing in
                    CaptureSorter.trashCaptureFolders(names: Array(held.keys), sourceRoot: source,
                                                      disposable: CaptureSorter.calibrationDisposable, allowing: allowing)
                }
            }
            status += " Deleted \(result.removed) \(kind.noun)(s)." + Self.describeKept(result.kept)
        default:
            status += left
        }
        plateSolveFolders = CaptureSorter.plateSolveFolders(under: source)
        calibrationFolders = CaptureSorter.calibrationFolders(under: source)
        next(done)
    }

    /// Capture folders a sort left behind because they still hold images, with counts by extension.
    @Published var keptFolders: [String: [String: Int]] = [:]
    @Published var showKeptFolders = false

    /// File types holding the leftovers that aren't checked under Files to Move.
    var keptUnselectedTypes: [SortFileType] {
        let extensions = Set(keptFolders.values.flatMap(\.keys))
        return SortFileType.allCases.filter { !fileTypes.contains($0) && !$0.extensions.isDisjoint(with: extensions) }
    }

    var keptFoldersMessage: String {
        let lines = keptFolders.keys.sorted().map { "• \($0): \(Self.describe([keptFolders[$0] ?? [:]]))" }
        let types = keptUnselectedTypes.map(\.label).joined(separator: ", ")
        return "Everything selected has been sorted out of:\n" + lines.joined(separator: "\n") + "\n\n"
            + (types.isEmpty ? "" : "\(types) isn't checked under Files to Move, so those images are still inside. ")
            + "Yes moves the folder and the images left in it to the Trash; you're asked about JSON files, and a folder holding other files "
            + "(e.g. .afphoto) is kept. No leaves it in the Capture Folder."
    }

    /// Capture folders with nothing left to sort for the checked types that still hold other images.
    var finishedCaptureNames: [String] {
        let root = URL(fileURLWithPath: sourcePath)
        let active = Set(entries.filter { $0.files > 0 }.map(\.captureFolder))
        return Dictionary(grouping: entries, by: \.captureFolder).compactMap { name, rows in
            guard !name.isEmpty, !active.contains(where: { $0.hasPrefix(name + "/") }) else { return nil }
            return rows.allSatisfy { $0.files == 0 } && CaptureSorter.holdsImages(root.appendingPathComponent(name)) ? name : nil
        }.sorted()
    }

    func askAboutFinishedFolders() {
        keptFolders = CaptureSorter.leftoverImages(captureNames: finishedCaptureNames, sourceRoot: URL(fileURLWithPath: sourcePath))
        showKeptFolders = !keptFolders.isEmpty
    }

    func deleteKeptFolders() {
        let names = Array(keptFolders.keys)
        keptFolders = [:]
        let source = URL(fileURLWithPath: sourcePath)
        let result = CaptureSorter.trashCaptureFolders(names: names, sourceRoot: source, allowing: withoutAstrometry)
        let removed = result.removed + askToDeleteHeld(result.held, offerAstrometry: false) { allowing in
            CaptureSorter.trashCaptureFolders(names: Array(result.held.keys), sourceRoot: source, allowing: allowing)
        }
        refreshInBackground { [weak self] in
            self?.status = "Moved \(removed) finished capture folder(s) to the Trash."
                + Self.describeKept(result.kept)
                + (removed + result.kept.count < names.count ? " \(names.count - removed - result.kept.count) kept." : "")
        }
    }

    /// The JSON setting, with astrometry never allowed: used where plate solves haven't been asked about.
    private var withoutAstrometry: DeletePermissions { DeletePermissions(json: deletePermissions.json) }

    private static func describeKept(_ kept: [String: [String: Int]]) -> String {
        let kept = kept.mapValues { $0.filter { !CaptureSorter.keepFolderExtensions.contains($0.key) } }.filter { !$0.value.isEmpty }
        guard !kept.isEmpty else { return "" }
        var totals: [String: Int] = [:]
        for counts in kept.values { totals.merge(counts, uniquingKeysWith: +) }
        let kinds = totals.sorted { $0.value > $1.value }.prefix(4).map { "\($0.value) .\($0.key)" }.joined(separator: ", ")
        return " \(kept.count) folder(s) kept because they hold other files (\(kinds))."
    }

    /// Folders held back only by JSON or astrometry files the settings don't allow deleting: asks with a checkbox for
    /// each kind, then deletes those folders the answer allows through `retry`. Returns how many were removed.
    private func askToDeleteHeld(_ held: [String: ProtectedFiles], offerAstrometry: Bool,
                                 retry: (DeletePermissions) -> FolderCleanup) -> Int {
        let outer = held.keys.filter { name in !held.keys.contains { name.hasPrefix($0 + "/") } }.sorted()
        let json = outer.reduce(0) { $0 + (held[$1]?.json ?? 0) }
        let astrometry = outer.reduce(0) { $0 + (held[$1]?.astrometry ?? 0) }
        let askJSON = json > 0 && !deletePermissions.json
        let askAstrometry = astrometry > 0 && offerAstrometry && !deletePermissions.astrometry
        guard askJSON || askAstrometry else { return 0 }

        let shown = 8
        let alert = NSAlert()
        alert.messageText = "\(outer.count) emptied folder(s) still hold JSON or plate-solve files"
        alert.informativeText = outer.prefix(shown).map { name in
            let files = held[name] ?? ProtectedFiles()
            return "• \(name): " + [files.json > 0 ? "\(files.json) JSON" : nil, files.astrometry > 0 ? "\(files.astrometry) astrometry" : nil]
                .compactMap { $0 }.joined(separator: ", ")
        }.joined(separator: "\n")
            + (outer.count > shown ? "\n…and \(outer.count - shown) more" : "")
            + "\n\nCheck what may be deleted with these folders. A folder holding anything left unchecked is kept."
        let jsonBox = NSButton(checkboxWithTitle: "Delete \(json) JSON file(s): observation, plan and session records", target: nil, action: nil)
        let astrometryBox = NSButton(checkboxWithTitle: "Delete \(astrometry) astrometry (plate-solve) file(s)", target: nil, action: nil)
        jsonBox.state = .off
        astrometryBox.state = .off
        let stack = NSStackView(views: [askJSON ? jsonBox : nil, askAstrometry ? astrometryBox : nil].compactMap { $0 })
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Delete Checked")
        alert.addButton(withTitle: "Keep All")
        alert.buttons[1].keyEquivalent = "\r"
        alert.buttons[0].keyEquivalent = ""
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return 0 }
        let allowing = DeletePermissions(
            json: deletePermissions.json || (askJSON && jsonBox.state == .on),
            astrometry: (deletePermissions.astrometry && offerAstrometry) || (askAstrometry && astrometryBox.state == .on)
        )
        return retry(allowing).removed
    }

    func keepFinishedFolders() {
        status = "Left \(keptFolders.count) finished capture folder(s) in the Capture Folder."
        keptFolders = [:]
    }

    func sortKeptTypes() {
        fileTypes.formUnion(keptUnselectedTypes)
        keptFolders = [:]
        if plannedCount > 0 { beginSortFlow() }
    }

    private static func describe<S: Sequence>(_ counts: S) -> String where S.Element == [String: Int] {
        let total = counts.reduce(into: [String: Int]()) { $0.merge($1, uniquingKeysWith: +) }
        return total.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key.uppercased())" }.joined(separator: ", ")
    }

    func openUserManual() {
        if let url = Bundle.main.url(forResource: "Smart-Telescope-Sort-User-Manual", withExtension: "pdf") {
            NSWorkspace.shared.open(url)
            return
        }
        let fallback = URL(fileURLWithPath: "/Volumes/Large Drive/Smart Telescope Sort program/App/Resources/Smart-Telescope-Sort-User-Manual.pdf")
        if FileManager.default.fileExists(atPath: fallback.path) {
            NSWorkspace.shared.open(fallback)
        } else {
            status = "User manual PDF was not found in the app bundle."
        }
    }
}

extension Notification.Name {
    static let showAssumptions = Notification.Name("SmartTelescopeSort.showAssumptions")
}

/// What the app takes for granted, shown when it opens and from the Help menu.
struct AssumptionsSheet: View {
    @Binding var showAtLaunch: Bool
    var close: () -> Void
    @State private var accepted = false
    @State private var alreadyAgreed = AgreementRecord.isAccepted
    @State private var agreedDate = AgreementRecord.acceptedDate

    private static let backupNotice = "A BACKUP is highly recommended, on a separate drive if possible. "
        + "You can delete it once you are satisfied all your data is moved."
    private static let disclaimer = "Big Sky Astro is not responsible for the loss of data. We have built in many safeguards to prevent it. "
        + "The user accepts all liability using this freeware."

    private let points = [
        "Capture Folder: where your images are. All subfolders are searched.",
        "Images move to the Target Folder by DSO or celestial name: Targets {year}/{object}.",
        "No object name found? Before sorting you name them all in one list. The date is the default.",
        "Dates come from folder names, else from the files.",
        "Only file types checked under Files to Move are moved (TIFF, JPG, FITS).",
        "Nothing is overwritten. A name used by another night gets a number: img-0001 2.tiff.",
        "Exact copies are marked Duplicate and deleted only if you say Yes.",
        "Not sorted: Targets {year} folders, thumbnails, auto-init frames.",
        "Emptied folders are deleted. JSON and astrometry files only if checked under OK to Delete or you allow it; folders with other files (e.g. .afphoto) are kept.",
        "After sorting, choose Move, Leave or Delete for plate solves, then for Lights, Darks, Dark Flats, Flats, Bias, Master*.",
        "Plate solves move in with their images: Targets {year}/{object}/Plate Solves. Unnamed ones are named in one list.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Before you sort").font(.title2.bold())
            VStack(alignment: .leading, spacing: 8) {
                ForEach(points, id: \.self) { point in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("•").foregroundStyle(.blue)
                        Text(point).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 14))
                }
            }
            notice(Self.backupNotice, ink: .red, paper: .yellow)
            notice(Self.disclaimer, ink: .black, paper: .red)
            if alreadyAgreed {
                Toggle(isOn: .constant(true)) {
                    Text("You have already agreed"
                         + (agreedDate.map { " on \($0.formatted(date: .long, time: .shortened))" } ?? ""))
                        .font(.system(size: 14, weight: .bold))
                }
                .toggleStyle(.checkbox)
                .disabled(true)
            } else {
                Toggle(isOn: $accepted) {
                    Text("I have read and accept the above").font(.system(size: 14, weight: .bold))
                }
                .toggleStyle(.checkbox)
            }
            HStack {
                Toggle("Show this when the app opens", isOn: $showAtLaunch)
                Spacer()
                Button("I Understand") {
                    if !alreadyAgreed {
                        try? AgreementRecord.record(terms: points + [Self.backupNotice, Self.disclaimer])
                    }
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!accepted && !alreadyAgreed)
            }
        }
        .padding(28)
        .frame(width: 820)
        .interactiveDismissDisabled()
    }

    private func notice(_ text: String, ink: Color, paper: Color) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(paper))
    }
}

struct ContentView: View {
    @StateObject private var model = SortViewModel()
    @AppStorage("SmartTelescopeSort.showAssumptionsAtLaunch") private var showAssumptionsAtLaunch = true
    @State private var showAssumptions = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            workspace
        }
        .background(Color(red: 0.02, green: 0.04, blue: 0.08))
        .foregroundStyle(Color(red: 0.92, green: 0.94, blue: 1.0))
        .onAppear {
            #if SCREENSHOTS
            if ScreenshotMode.isActive {
                ScreenshotMode.stage(model)
                return
            }
            #endif
            if showAssumptionsAtLaunch || !AgreementRecord.isAccepted {
                showAssumptions = true
            } else {
                model.start()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAssumptions)) { _ in
            showAssumptions = true
        }
        .sheet(isPresented: $showAssumptions, onDismiss: { model.start() }) {
            AssumptionsSheet(showAtLaunch: $showAssumptionsAtLaunch) { showAssumptions = false }
        }
        .confirmationDialog(
            "Create Targets folder?",
            isPresented: $model.showCreateConfirm,
            titleVisibility: .visible
        ) {
            Button("Create Targets \(model.pendingCreateYear ?? "")") {
                model.createMissingTarget()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create Targets \(model.pendingCreateYear ?? "") in your Target Folder? No files will be moved.")
        }
        .confirmationDialog(
            "Back up before sorting?",
            isPresented: $model.showBackupOffer,
            titleVisibility: .visible
        ) {
            Button("Yes, back up first") {
                model.backUpThenConfirmSort()
            }
            Button("No, sort without backup") {
                model.showSortConfirm = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.backupOfferMessage)
        }
        .confirmationDialog(
            "Sort eligible files?",
            isPresented: $model.showSortConfirm,
            titleVisibility: .visible
        ) {
            Button("Sort now", role: .destructive) {
                model.performSort()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if model.actionableCount == 0 {
                Text("No image files left to move. Delete \(model.spentCaptureNames.count) emptied capture folder(s) in the Capture Folder?")
            } else {
                Text("Copy \(model.summary.move) files into Targets {year}/{object}, checking each copy byte for byte. Nothing in Targets is overwritten. "
                     + "When all moves are done you're asked twice before the originals and emptied capture folders are deleted."
                     + (model.summary.duplicates > 0 ? " \(model.summary.duplicates) duplicate(s) already in Targets are left alone; you'll be asked about them next." : ""))
            }
        }
        .alert(
            model.keptFolders.count == 1 ? "Delete finished folder?" : "Delete \(model.keptFolders.count) finished folders?",
            isPresented: $model.showKeptFolders
        ) {
            Button("Yes", role: .destructive) { model.deleteKeptFolders() }
            if !model.keptUnselectedTypes.isEmpty {
                Button("Sort \(model.keptUnselectedTypes.map(\.label).joined(separator: ", ")) First") { model.sortKeptTypes() }
            }
            Button("No", role: .cancel) { model.keepFinishedFolders() }
        } message: {
            Text(model.keptFoldersMessage)
        }
        .alert("Delete duplicates?", isPresented: $model.showDuplicateConfirm) {
            Button("Yes", role: .destructive) { model.deleteDuplicates() }
            Button("No", role: .cancel) { model.keepDuplicates() }
        } message: {
            Text(model.duplicatePrompt)
        }
        .sheet(isPresented: $model.showPlanSheet) {
            PlanReviewSheet(model: model)
        }
        .sheet(isPresented: Binding(get: { model.backupProgress != nil }, set: { _ in })) {
            BackupProgressSheet(model: model)
        }
        .sheet(isPresented: Binding(get: { model.scanProgress != nil }, set: { _ in })) {
            ScanProgressSheet(model: model)
        }
        .sheet(isPresented: Binding(get: { model.transferProgress != nil }, set: { _ in })) {
            TransferProgressSheet(model: model)
        }
    }

    private struct TransferProgressSheet: View {
        @ObservedObject var model: SortViewModel

        var body: some View {
            let progress = model.transferProgress ?? TransferProgress(phase: "Starting")
            VStack(alignment: .leading, spacing: 12) {
                Text(model.transferExplanation?.title ?? (progress.deleting ? progress.phase : "Sorting: copy, check, then delete"))
                    .font(.title3.bold())
                Text(model.transferExplanation?.note ?? (progress.deleting
                     ? "You said Yes twice. Everything sorted is safe in Targets; these go to the Trash."
                     : "Copy then delete: each file is copied into the Target Folder and checked byte for byte against the original. "
                        + "Nothing is deleted now. When every move is done you're asked twice before the originals are deleted."))
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.10)))
                ProgressView(value: progress.fraction)
                HStack {
                    Text(progress.phase)
                    Spacer()
                    Text("\(progress.done) of \(progress.total)")
                }
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                Text(progress.item.isEmpty ? " " : progress.item)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Elapsed \(Self.clock(context.date.timeIntervalSince(model.transferStarted)))")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Stop", role: .cancel) { model.stopTransfer() }
                        .keyboardShortcut(.cancelAction)
                        .help(progress.deleting ? "Stop deleting; the rest of the originals are kept." : "Stop copying; originals are never deleted without asking.")
                }
            }
            .padding(24)
            .frame(width: 560)
            .interactiveDismissDisabled()
        }

        private static func clock(_ seconds: TimeInterval) -> String {
            let s = max(Int(seconds.rounded()), 0)
            return String(format: "%d:%02d", s / 60, s % 60)
        }
    }

    private struct ScanProgressSheet: View {
        @ObservedObject var model: SortViewModel

        var body: some View {
            let progress = model.scanProgress ?? ScanProgress(step: 1, phase: "Starting")
            VStack(alignment: .leading, spacing: 12) {
                Text("Scanning the Capture Folder").font(.title3.bold())
                Text(model.sourcePath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                HStack {
                    Text("Step \(progress.step) of \(ScanProgress.steps): \(progress.phase)")
                    Spacer()
                    Text(progress.countText)
                }
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                HStack {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Elapsed \(Self.clock(context.date.timeIntervalSince(model.scanStarted)))")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel Scan", role: .cancel) { model.cancelScan() }
                        .keyboardShortcut(.cancelAction)
                }
                Text("Nothing is moved while scanning.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(width: 540)
            .interactiveDismissDisabled()
        }

        private static func clock(_ seconds: TimeInterval) -> String {
            let s = max(Int(seconds.rounded()), 0)
            return String(format: "%d:%02d", s / 60, s % 60)
        }
    }

    private struct BackupProgressSheet: View {
        @ObservedObject var model: SortViewModel

        var body: some View {
            let progress = model.backupProgress ?? ArchiveProgress()
            VStack(alignment: .leading, spacing: 12) {
                Text("Backing up capture folders").font(.title3.bold())
                Text(model.backupTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressView(value: progress.fraction)
                HStack {
                    Text("\(Self.bytes(progress.bytesDone)) of \(Self.bytes(progress.bytesTotal))")
                    Spacer()
                    Text("\(progress.filesDone) of \(progress.filesTotal) files · \(Int(progress.fraction * 100))%")
                }
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                Text(progress.currentFile.isEmpty ? "Counting files…" : progress.currentFile)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(timing(at: context.date, fraction: progress.fraction))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel Backup", role: .cancel) { model.cancelBackup() }
                        .keyboardShortcut(.cancelAction)
                }
                Text("Nothing is moved until the backup finishes and you confirm the sort.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(width: 540)
            .interactiveDismissDisabled()
        }

        private func timing(at now: Date, fraction: Double) -> String {
            let elapsed = now.timeIntervalSince(model.backupStarted)
            var text = "Elapsed \(Self.clock(elapsed))"
            if fraction > 0.02, fraction < 1 {
                text += " · about \(Self.clock(elapsed * (1 - fraction) / fraction)) left"
            }
            return text
        }

        private static func clock(_ seconds: TimeInterval) -> String {
            let s = max(Int(seconds.rounded()), 0)
            return String(format: "%d:%02d", s / 60, s % 60)
        }

        private static func bytes(_ count: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
        }
    }

    private struct PlanReviewSheet: View {
        @ObservedObject var model: SortViewModel
        @Environment(\.dismiss) private var dismiss
        @State private var confirmDelete = false

        private var groups: [(folder: String, items: [SortPlanItem])] {
            Dictionary(grouping: model.planItems, by: \.captureFolder)
                .map { (folder: $0.key, items: $0.value) }
                .sorted { $0.folder < $1.folder }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("File plan").font(.title2.bold())
                        Text(model.telescopeKind.menuTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                Text("\(groups.count) capture folder(s) · \(model.planItems.count) files: \(model.summary.move) new · \(model.summary.duplicates) duplicate. Nothing has been moved yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if model.planItems.isEmpty {
                    Text("No file actions in this preview. Check the Capture Folder path and file types.")
                        .padding(.top, 24)
                    Spacer()
                } else {
                    PlanRow.header
                    List {
                        ForEach(groups, id: \.folder) { group in
                            Section {
                                ForEach(group.items) { PlanRow(item: $0) }
                            } header: {
                                HStack(spacing: 6) {
                                    Image(systemName: "folder.fill")
                                    Text(group.folder).font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    Spacer()
                                    Text(SortViewModel.statusText(group.items)).font(.system(size: 11))
                                }
                            }
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .frame(minHeight: 360)
                }

                if model.summary.duplicates > 0 {
                    HStack {
                        Image(systemName: "doc.on.doc").foregroundStyle(.orange)
                        Text("\(model.summary.duplicates) file(s) are byte-for-byte copies of files in Targets and are marked Duplicate. Sort leaves them in place.")
                            .font(.callout)
                        Spacer()
                        Button("Delete duplicates…") { confirmDelete = true }
                            .disabled(model.isBusy)
                    }
                }
            }
            .padding(20)
            .frame(minWidth: 1020, minHeight: 520)
            .alert("Delete duplicates?", isPresented: $confirmDelete) {
                Button("Yes", role: .destructive) { model.deleteDuplicates() }
                Button("No", role: .cancel) { model.keepDuplicates() }
            } message: {
                Text(model.duplicatePrompt)
            }
        }
    }

    private struct PlanRow: View {
        let item: SortPlanItem

        private static let dateFormat: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return f
        }()

        static var header: some View {
            HStack(spacing: 10) {
                Text("DSO / name").frame(width: 130, alignment: .leading)
                Text("Image file").frame(minWidth: 170, maxWidth: .infinity, alignment: .leading)
                Text("Date").frame(width: 120, alignment: .leading)
                Text("Target folder").frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                Text("Status").frame(width: 100, alignment: .leading)
            }
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
        }

        var body: some View {
            HStack(spacing: 10) {
                Text(item.object).fontWeight(.semibold).frame(width: 130, alignment: .leading)
                Text(item.source.lastPathComponent)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minWidth: 170, maxWidth: .infinity, alignment: .leading)
                    .help(item.source.path)
                Text(Self.dateFormat.string(from: item.date))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 120, alignment: .leading)
                Text(item.targetFolder)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                    .help(item.destination.path)
                Text(item.action.label)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 100, alignment: .leading)
            }
            .lineLimit(1)
        }

        private var color: Color {
            switch item.action {
            case .move: return .green
            case .duplicate: return .orange
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .center, spacing: 8) {
                if let logo = Self.bigSkyAstroLogo {
                    Link(destination: BigSkyAstroWebLinks.home) {
                        Image(nsImage: logo)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 250, height: 104)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .pointingHandCursor()
                    .padding(.top, 4)
                    .help("Open bigskyastro.com")
                }
                VStack(alignment: .center, spacing: 3) {
                    Text("Smart Telescope Sort")
                        .font(.system(size: 17, weight: .bold))
                    Text(model.lockedKind == nil
                         ? "Multi-brand Captures → Targets"
                         : "Independent app. Not affiliated with telescope makers.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 0.58, green: 0.65, blue: 0.78))
                }
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 2)

            VStack(alignment: .leading, spacing: 10) {
                Text("HOW IT WORKS")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(1.1)
                    .foregroundStyle(Color(red: 0.51, green: 0.58, blue: 0.71))
                    .frame(maxWidth: .infinity, alignment: .center)
                infoLine(icon: "folder", text: model.telescopeKind.dropHint + " The layout is detected; Targets {year} folders are skipped.")
                infoLine(icon: "line.3.horizontal.decrease.circle", text: "Pick a year, a month and the file types to move: TIFF, JPG/JPEG, FITS/FIT or All.")
                infoLine(icon: "list.bullet.rectangle", text: "Review file plan lists every file with its object, date and target folder.")
                infoLine(icon: "archivebox", text: "Optional Zip or Tarball backup. You name it, and a progress window shows it running.")
                infoLine(icon: "arrow.right.doc.on.clipboard", text: "Sort copies the checked file types into Targets {year}/{object} and checks each copy byte for byte. Nothing there is overwritten.")
                infoLine(icon: "doc.on.doc", text: "Files already in the Target Folder are marked Duplicate. Plate solves go to {object}/Plate Solves.")
                infoLine(icon: "trash", text: "Originals, then the processed capture folders, are deleted only after you say Yes twice.")
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.16, blue: 0.30).opacity(0.55))
            )

            Spacer()
            Button {
                model.openUserManual()
            } label: {
                Label("Open user manual (PDF)", systemImage: "book.pages")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(red: 0.55, green: 0.70, blue: 1.0))
            Button {
                SourceCodeCredit.openRepository()
            } label: {
                Label {
                    Text("Source code on GitHub")
                } icon: {
                    if let logo = Self.gitHubLogo {
                        Image(nsImage: logo).resizable().scaledToFit().frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                    }
                }
                .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(red: 0.55, green: 0.70, blue: 1.0))
            .help(BigSkyAstroWebLinks.sourceCode.absoluteString)
            appCard(title: "Astronomy Observation Planner", subtitle: "Mac App Store", icon: "macwindow",
                    url: BigSkyAstroWebLinks.observationPlanner)
            appCard(title: "Smart Telescope Planner", subtitle: "iPhone & iPad App Store", icon: "iphone",
                    url: BigSkyAstroWebLinks.telescopePlanner)
            Text("Nothing moves until you press Sort eligible files.")
                .font(.system(size: 10))
                .foregroundStyle(Color(red: 0.58, green: 0.65, blue: 0.78))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 290, alignment: .topLeading)
        .background(Color(red: 0.05, green: 0.09, blue: 0.18))
    }

    private static let bigSkyAstroLogo: NSImage? = Bundle.main.url(forResource: "BigSkyAstro-logo", withExtension: "png")
        .flatMap(NSImage.init(contentsOf:))

    private static let gitHubLogo: NSImage? = Bundle.main.url(forResource: "GitHub-logo", withExtension: "png")
        .flatMap(NSImage.init(contentsOf:))

    /// A BigSkyAstro app promoted as a filled card so it stands apart from the plain links.
    private func appCard(title: String, subtitle: String, icon: String, url: URL) -> some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.18)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 11.5, weight: .bold)).foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.78))
                }
                Spacer(minLength: 2)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.85))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.24, green: 0.42, blue: 0.95), Color(red: 0.42, green: 0.30, blue: 0.88)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.18))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
    }

    private func infoLine(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 0.55, green: 0.70, blue: 1.0))
                .frame(width: 16)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 0.72, green: 0.78, blue: 0.90))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CAPTURE LIBRARY")
                        .font(.system(size: 9, weight: .heavy))
                        .tracking(1.2)
                        .foregroundStyle(Color(red: 0.51, green: 0.58, blue: 0.71))
                    Text("Ready to review").font(.system(size: 24, weight: .bold))
                    Text(model.telescopeKind.menuTitle + (model.layoutDetected ? " · detected" : ""))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 0.55, green: 0.70, blue: 1.0))
                        .help(model.telescopeKind.compatibilityNote)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 4) {
                    statusLight(!model.hasCaptureFolder ? "No Capture Folder chosen"
                                : model.sourceAvailable ? "Capture Folder available" : "Capture Folder unavailable",
                                color: !model.hasCaptureFolder ? .red : model.sourceAvailable ? .green : .orange)
                    ForEach(LibraryFolder.allCases, id: \.self) { folder in
                        let chosen = model.libraryFolders[folder] != nil
                        statusLight("\(folder.title) \(chosen ? "selected" : "not selected")", color: chosen ? .green : .red)
                    }
                }
            }

            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Color(red: 0.45, green: 0.62, blue: 1.0))
                VStack(alignment: .leading, spacing: 2) {
                    Text("CAPTURE FOLDER · WHERE THE IMAGES ARE LOCATED")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Color(red: 0.51, green: 0.58, blue: 0.71))
                    Text(model.hasCaptureFolder ? model.sourcePath : "Not chosen — click Choose… to pick the folder where your images are")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(model.hasCaptureFolder ? Color(red: 0.92, green: 0.94, blue: 1.0) : Color(red: 0.90, green: 0.70, blue: 0.35))
                }
                Spacer()
                Button("Choose…") { model.chooseSourceFolder() }
                    .disabled(model.isBusy)
                    .buttonStyle(.bordered)
                Text("\(model.excluded) folders are skipped.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.90, green: 0.70, blue: 0.35))
            }
            .padding(.vertical, 8)

            ForEach(LibraryFolder.allCases, id: \.self) { folder in
                libraryRow(folder)
            }

            VStack(spacing: 0) {
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("DESTINATION").font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(Color(red: 0.51, green: 0.58, blue: 0.71))
                        Text("Choose a year and month").font(.system(size: 16, weight: .semibold))
                        Text("Objects decode into Targets {year}/{DSO} for the detected capture layout.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(red: 0.58, green: 0.65, blue: 0.78))
                    }
                    Spacer()
                    Picker("Year", selection: $model.selectedYear) {
                        Text("All years").tag("all")
                        ForEach(model.years, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 120)
                    .onChange(of: model.selectedYear) { _, _ in model.refreshInBackground() }

                    Picker("Month", selection: $model.selectedMonth) {
                        ForEach(model.months, id: \.id) { Text($0.title).tag($0.id) }
                    }
                    .frame(width: 140)
                    .onChange(of: model.selectedMonth) { _, _ in model.refreshInBackground() }

                    Button("Refresh preview") { model.refreshInBackground() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.30, green: 0.48, blue: 0.95))
                }
                .padding([.horizontal, .top], 16)
                .padding(.bottom, 8)

                HStack(spacing: 16) {
                    Text("FILES TO MOVE").font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Color(red: 0.51, green: 0.58, blue: 0.71))
                        .frame(width: 86, alignment: .leading)
                    ForEach(SortFileType.allCases) { type in
                        Toggle(type.label, isOn: Binding(
                            get: { model.fileTypes.contains(type) },
                            set: { on in
                                if on { model.fileTypes.insert(type) } else { model.fileTypes.remove(type) }
                            }
                        ))
                    }
                Toggle("All", isOn: Binding(
                    get: { model.fileTypes.count == SortFileType.allCases.count },
                    set: { on in model.fileTypes = on ? Set(SortFileType.allCases) : [] }
                ))
                Spacer()
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            HStack(spacing: 16) {
                Text("OK TO DELETE").font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color(red: 0.51, green: 0.58, blue: 0.71))
                    .frame(width: 86, alignment: .leading)
                Toggle("JSON", isOn: $model.deletePermissions.json)
                    .help("JSON files (observation, plan and session records) left in emptied capture folders.")
                Toggle("Astrometry", isOn: $model.deletePermissions.astrometry)
                    .help("Plate-solve files left in emptied capture folders. Never deleted when you choose to leave plate solves.")
                Text("Unchecked: you're asked before a folder holding them is deleted")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            HStack(spacing: 16) {
                Text("BACKUP").font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color(red: 0.51, green: 0.58, blue: 0.71))
                    .frame(width: 86, alignment: .leading)
                Picker("Backup", selection: Binding(
                    get: { model.backupFormat?.rawValue ?? "off" },
                    set: { model.backupFormat = BackupFormat(rawValue: $0) }
                )) {
                    Text("Off").tag("off")
                    ForEach(BackupFormat.allCases) { Text("\($0.label) (.\($0.fileExtension))").tag($0.rawValue) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 150)
                .help("What Yes makes when Sort asks about a backup: a zip (.zip) or tarball (.tar.gz) of the capture folders, or a folder copy when Off. Built into macOS — nothing to install.")
                Text(model.backupFormat == nil
                     ? "Sort asks; Yes makes a folder copy"
                     : "→ \(model.libraryFolders[.backup]?.path ?? "Backup Storage (asked when you sort)")")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.58, green: 0.65, blue: 0.78))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 16)
            .padding(.bottom, model.showArchiverLinks ? 6 : 16)

            if model.showArchiverLinks {
                HStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("Free Mac zip & tarball apps:").font(.system(size: 11))
                    ForEach(ArchiverLinks.all, id: \.title) { link in
                        Link(link.title, destination: link.url).font(.system(size: 11, weight: .semibold))
                    }
                    Spacer()
                }
                .padding([.horizontal, .bottom], 16)
            }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.09, green: 0.15, blue: 0.28).opacity(0.8))
            )

            if let year = model.missingYears.first {
                HStack {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Targets \(year) does not exist yet.").font(.system(size: 12, weight: .semibold))
                        Text("Create the matching target folder before sorting.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(red: 0.72, green: 0.64, blue: 0.49))
                    }
                    Spacer()
                    Button("Create Targets \(year)") {
                        model.pendingCreateYear = year
                        model.showCreateConfirm = true
                    }
                    .buttonStyle(.bordered)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.orange.opacity(0.4))
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                )
            }

            table
            stats
            planBar
            footer
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.04, green: 0.07, blue: 0.14))
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(model.entries.count) capture rows found")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(red: 0.90, green: 0.93, blue: 1.0))
                Spacer()
                Text("Target folder shows where the image files will be put")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.70, green: 0.76, blue: 0.88))
            }
            Table(model.entries) {
                TableColumn("Capture folder") { (entry: CaptureEntry) in
                    Text(entry.captureFolder.isEmpty ? URL(fileURLWithPath: model.sourcePath).lastPathComponent : entry.captureFolder)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(tableInk)
                        .lineLimit(1)
                }
                .width(min: 180, ideal: 240)
                TableColumn("Year") { Text($0.year).foregroundStyle(tableInk) }.width(50)
                TableColumn("Month") { Text($0.month).foregroundStyle(tableInk) }.width(50)
                TableColumn("DSO object") { (entry: CaptureEntry) in
                    if entry.needsObjectName {
                        Text("Ask when sorting")
                            .italic()
                            .foregroundStyle(.orange)
                            .help("No folder names a target. You'll be asked which object these images are of; the date \(entry.sessionDate) is the default.")
                    } else {
                        Text(entry.object).fontWeight(.semibold).foregroundStyle(tableInk)
                    }
                }
                .width(120)
                TableColumn("Img folders") { Text("\($0.imageFolders)").foregroundStyle(tableInk) }.width(70)
                TableColumn("Files") { Text("\($0.files)").foregroundStyle(tableInk) }.width(50)
                TableColumn("Status") { (entry: CaptureEntry) in
                    let text = model.entryStatus[entry.id] ?? ""
                    Text(text)
                        .fontWeight(text.contains("uplicate") ? .semibold : .regular)
                        .foregroundStyle(text.hasPrefix("Duplicate") || text.hasSuffix("duplicates") ? Color.orange : tableInk)
                        .help(text.contains("uplicate") ? "Already in Targets. You'll be asked before these are deleted." : "")
                }
                .width(min: 90, ideal: 130)
                TableColumn("Formats") {
                    Text($0.formats.joined(separator: ", ")).foregroundStyle(tableInk)
                }
                .width(90)
                TableColumn("Target folder") { (entry: CaptureEntry) in
                    Text("Targets \(entry.year)/\(entry.object)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tableDestination)
                        .lineLimit(1)
                        .help(entry.targetDirectory.path)
                }
                .width(min: 200, ideal: 300)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .foregroundStyle(tableInk)
            .colorScheme(.light)
            .frame(minHeight: 120, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func statusLight(_ text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11)).foregroundStyle(color)
        }
    }

    private func libraryRow(_ folder: LibraryFolder) -> some View {
        let url = model.libraryFolders[folder]
        return HStack {
            Image(systemName: folder == .originals ? "archivebox.fill" : "externaldrive.fill")
                .foregroundStyle(Color(red: 0.45, green: 0.62, blue: 1.0))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text((folder.title + (folder.caption.map { " · \($0)" } ?? "")).uppercased())
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color(red: 0.51, green: 0.58, blue: 0.71))
                Text(url?.path ?? (folder == .originals ? "Not set — Targets {year} go inside the Capture Folder" : "Not set"))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(url == nil ? Color(red: 0.90, green: 0.70, blue: 0.35) : Color(red: 0.92, green: 0.94, blue: 1.0))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if folder == .originals, let note = model.targetFolderNote {
                    Text(note.text)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(note.warning ? Color(red: 0.90, green: 0.70, blue: 0.35) : Color(red: 0.51, green: 0.58, blue: 0.71))
                        .lineLimit(2)
                }
            }
            Spacer()
            if url != nil {
                Text(model.savedDefaults.contains(folder) ? "Default" : "This session")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            if folder == .originals {
                Button("Remove Identical Copies…") { model.removeIdenticalCopiesInTargets() }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy || model.isBackingUp)
                    .help("Find images saved more than once in Targets {year}/{object} and, after you say Yes twice, keep one copy of each.")
            }
            Button("Change…") { model.chooseLibraryFolder(folder) }
                .buttonStyle(.bordered)
        }
    }

    private var tableInk: Color { Color(red: 0.08, green: 0.12, blue: 0.22) }
    private var tableDestination: Color { Color(red: 0.10, green: 0.28, blue: 0.62) }

    private var stats: some View {
        HStack(spacing: 18) {
            stat(value: "\(model.entries.count)", label: "folders ready to inspect")
            stat(value: "\(model.entries.reduce(0) { $0 + $1.files })", label: "image files to sort")
            HStack(spacing: 10) {
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(Color(red: 0.59, green: 0.68, blue: 1.0))
                Text("Nothing is overwritten; a clashing name gets a number.\nOnly byte-identical copies count as duplicates.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.56, green: 0.63, blue: 0.78))
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.08))
        )
    }

    private func stat(value: String, label: String) -> some View {
        HStack(spacing: 8) {
            Text(value).font(.system(size: 18, weight: .bold))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color(red: 0.56, green: 0.63, blue: 0.78))
        }
    }

    private var planBar: some View {
        HStack {
            if model.onlyFinishedFolders {
                Text("\(model.finishedCaptureNames.count) finished capture folder(s): nothing checked is left to sort, but other images remain.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.68, green: 0.74, blue: 0.88))
            } else if model.actionableCount == 0, !model.spentCaptureNames.isEmpty {
                Text("\(model.spentCaptureNames.count) emptied capture folder(s) ready to delete in the Capture Folder.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.68, green: 0.74, blue: 0.88))
            } else if model.plannedCount == 0, model.summary.duplicates > 0 {
                Text("All \(model.summary.duplicates) file(s) are duplicates already in Targets. Delete duplicates asks before removing anything.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.95, green: 0.72, blue: 0.40))
            } else {
                Text("\(model.plannedCount) files eligible: \(model.summary.move) to move."
                     + (model.summary.duplicates > 0 ? " \(model.summary.duplicates) duplicate(s) already in Targets." : ""))
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.68, green: 0.74, blue: 0.88))
            }
            Spacer()
            Button("Review file plan") { model.reviewFilePlan() }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.30, green: 0.48, blue: 0.95))
                .disabled(model.isBusy || (model.planItems.isEmpty && model.entries.isEmpty))
            Button(model.onlyFinishedFolders ? "Delete finished folders…"
                   : model.actionableCount == 0 && !model.spentCaptureNames.isEmpty ? "Remove empty captures"
                   : model.plannedCount == 0 && model.summary.duplicates > 0 ? "Delete duplicates…" : "Sort eligible files") {
                model.beginSortFlow()
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.30, green: 0.48, blue: 0.95))
            .disabled(!model.canSortOrCleanup || model.isBusy || model.isBackingUp)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.15, green: 0.22, blue: 0.40).opacity(0.55))
        )
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
            Text(model.status)
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 0.51, green: 0.58, blue: 0.71))
            Spacer()
        }
        .padding(.top, 4)
    }
}

private extension View {
    /// Shows the pointing-hand cursor over clickable links.
    func pointingHandCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
