import SwiftUI
import AppKit

@MainActor
final class SortViewModel: ObservableObject {
    /// Detected from the Source Captures folder on every refresh, unless the build is locked to one layout.
    @Published var telescopeKind: TelescopeKind {
        didSet { UserDefaults.standard.set(telescopeKind.rawValue, forKey: TelescopeKind.storageKey) }
    }
    @Published var layoutDetected = false
    @Published var fileTypes: Set<SortFileType> = Set(SortFileType.defaults) {
        didSet {
            UserDefaults.standard.set(fileTypes.map(\.rawValue).sorted(), forKey: Self.fileTypesKey)
            refresh()
        }
    }
    private static let fileTypesKey = "SmartTelescopeSort.fileTypes"
    /// Zip or tarball made before a sort; nil turns the archive backup off.
    @Published var backupFormat: BackupFormat? = nil {
        didSet { UserDefaults.standard.set(backupFormat?.rawValue ?? "off", forKey: Self.backupFormatKey) }
    }
    private static let backupFormatKey = "SmartTelescopeSort.backupFormat"
    @Published var backupFailed = false
    /// Set while a zip or tarball backup runs; drives the progress sheet.
    @Published var backupProgress: ArchiveProgress?
    @Published var backupTitle = ""
    private(set) var backupStarted = Date()
    private var backupJob: ArchiveJob?
    var isBackingUp: Bool { backupJob != nil }

    /// Offer free archiver apps when the built-in one is missing or a backup just failed.
    var showArchiverLinks: Bool { !BackupFormat.systemArchiverAvailable || backupFailed }
    @Published var libraryFolders: [LibraryFolder: URL] = [:]
    @Published var savedDefaults: Set<LibraryFolder> = []
    private var sessionFolders: [String: URL] = [:]
    private var askedThisSession: Set<String> = []
    private var processingIndex: [String: URL] = [:]
    @Published var sourcePath = CaptureSorter.defaultSource.path
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

    /// Where Targets {year} folders live: the chosen Original Targets folder (or its parent when a Targets {year}
    /// folder itself was picked), else the Source Captures folder.
    var targetsRoot: URL {
        guard let url = libraryFolders[.originals] else { return URL(fileURLWithPath: sourcePath) }
        if url.lastPathComponent.range(of: #"^Targets \d{4}$"#, options: .regularExpression) != nil {
            return url.deletingLastPathComponent()
        }
        return url
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
        let start = libraryFolders[folder] ?? (folder == .originals
            ? URL(fileURLWithPath: sourcePath)
            : URL(fileURLWithPath: sourcePath).deletingLastPathComponent())
        guard let choice = folder.ask(startingAt: start) else {
            if libraryFolders[folder] == nil {
                status = folder == .originals
                    ? "Original Targets not set — Targets {year} folders stay inside Source Captures."
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
        refresh()
        status = "\(folder.title): \(choice.url.path)" + (choice.saveAsDefault ? " (saved as default)" : " (this session only)")
    }

    /// The processing folder for an object, matched by name without regard to case, spaces or dashes.
    func processingFolder(for object: String) -> URL? {
        processingIndex[Self.matchKey(object)]
    }

    private static func matchKey(_ name: String) -> String {
        name.uppercased().replacingOccurrences(of: #"[\s_-]"#, with: "", options: .regularExpression)
    }

    private func indexProcessingFolders() {
        processingIndex = [:]
        guard let root = libraryFolders[.processing],
              let kids = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        for kid in kids where (try? kid.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            processingIndex[Self.matchKey(kid.lastPathComponent)] = kid
        }
    }

    var missingYears: [String] {
        Array(Set(entries.filter { !$0.targetExists }.map(\.year))).sorted()
    }

    var plannedCount: Int { summary.move + summary.replace }
    var actionableCount: Int { summary.move + summary.replace + summary.duplicates }

    var duplicateItems: [SortPlanItem] { planItems.filter(\.isDuplicate) }

    var duplicatePrompt: String {
        let folders = Set(duplicateItems.map(\.captureFolder)).count
        var text = "\(summary.duplicates) image file(s) in \(folders) capture folder(s) are already in Targets"
        if summary.older > 0 {
            text += " (\(summary.duplicate) identical, \(summary.older) older than the Targets copy)"
        }
        return text + ". Delete them from Captures? They go to the Trash, the Targets copies are not touched, and capture folders left with no TIFF/FITS are removed."
    }

    static func statusText(_ items: [SortPlanItem]) -> String {
        let duplicates = items.filter(\.isDuplicate).count
        if duplicates == items.count {
            return duplicates == 1 ? "Duplicate" : "\(duplicates) duplicates"
        }
        let new = items.filter { $0.action == .move }.count
        let newer = items.filter { $0.action == .replace }.count
        var parts: [String] = []
        if new > 0 { parts.append("\(new) new") }
        if newer > 0 { parts.append("\(newer) newer") }
        if duplicates > 0 { parts.append("\(duplicates) duplicate") }
        return parts.joined(separator: " · ")
    }

    var spentCaptureNames: [String] {
        let grouped = Dictionary(grouping: entries, by: \.captureFolder)
        let root = URL(fileURLWithPath: sourcePath)
        return grouped.compactMap { name, rows in
            rows.allSatisfy { $0.files == 0 } && !CaptureSorter.holdsImages(root.appendingPathComponent(name)) ? name : nil
        }.sorted()
    }

    var canSortOrCleanup: Bool {
        actionableCount > 0 || !spentCaptureNames.isEmpty || !finishedCaptureNames.isEmpty
    }

    /// Nothing to move or remove except finished folders still holding unticked image types.
    var onlyFinishedFolders: Bool {
        actionableCount == 0 && spentCaptureNames.isEmpty && !finishedCaptureNames.isEmpty
    }

    func refresh() {
        isBusy = true
        defer { isBusy = false }
        let root = URL(fileURLWithPath: sourcePath)
        do {
            let year = selectedYear == "all" ? nil : selectedYear
            let month = selectedMonth == "all" ? nil : selectedMonth
            CaptureSorter.sortExtensions = fileTypes.reduce(into: []) { $0.formUnion($1.extensions) }
            if lockedKind == nil {
                let detected = TelescopeKind.detect(in: root)
                layoutDetected = detected != nil
                if let detected, detected != telescopeKind { telescopeKind = detected }
            }
            let result = try CaptureSorter.scan(
                kind: telescopeKind,
                sourceRoot: root,
                targetsRoot: targetsRoot,
                year: year,
                month: month
            )
            indexProcessingFolders()
            entries = result.entries
            years = result.years
            excluded = result.excluded
            sourceAvailable = FileManager.default.fileExists(atPath: root.path)
            let preview = CaptureSorter.preview(entries: entries)
            summary = preview.summary
            planItems = preview.plans
            entryStatus = Dictionary(grouping: planItems, by: \.entryID).mapValues(Self.statusText)
            status = !sourceAvailable ? "Source unavailable."
                : fileTypes.isEmpty ? "Tick at least one file type to move."
                : "Preview ready for \(telescopeKind.menuTitle) (\(fileTypesSummary)) — no files have been moved."
            if selectedYear != "all", !years.contains(selectedYear), let first = years.first {
                selectedYear = first
            }
        } catch {
            status = error.localizedDescription
            entries = []
            summary = SortSummary()
            planItems = []
            entryStatus = [:]
        }
    }

    /// Opens the per-folder file list (does not move files).
    func reviewFilePlan() {
        refresh()
        if planItems.isEmpty, entries.isEmpty {
            status = "No plan yet — choose a Source Captures folder that holds telescope session folders, then try again."
            return
        }
        showPlanSheet = true
    }

    func chooseSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: sourcePath)
        panel.message = "Choose the Captures folder that holds your telescope's session folders"
        if panel.runModal() == .OK, let url = panel.url {
            sourcePath = url.path
            refresh()
        }
    }

    func createMissingTarget() {
        guard let year = pendingCreateYear ?? missingYears.first else { return }
        do {
            let created = try CaptureSorter.createTargetsFolder(year: year, targetsRoot: targetsRoot)
            status = "Created \(created.path). No capture files were moved."
            refresh()
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
        if let format = backupFormat {
            Task { await archiveThenConfirmSort(format) }
            return
        }
        showBackupOffer = true
    }

    /// Zip and/or tarball backup of the capture folders into Backup Storage; the sort is only offered once it succeeds.
    func archiveThenConfirmSort(_ format: BackupFormat) async {
        guard BackupFormat.systemArchiverAvailable else {
            backupFailed = true
            status = "This Mac's built-in archiver (/usr/bin/tar) is missing — nothing was moved. Use one of the free archivers below, or turn the backup off."
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
        let names = Array(Set(entries.map(\.captureFolder)))
        let source = URL(fileURLWithPath: sourcePath)
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

    /// Asks about duplicates once the dialog that triggered this has closed; SwiftUI shows one at a time.
    private func askAboutDuplicatesLater() {
        guard summary.duplicates > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.showDuplicateConfirm = true
        }
    }

    func deleteDuplicates() {
        isBusy = true
        defer { isBusy = false }
        let result = CaptureSorter.deleteDuplicates(duplicateItems, sourceRoot: URL(fileURLWithPath: sourcePath))
        refresh()
        status = "Deleted \(result.deleted) duplicate(s) from Captures and removed \(result.removedFolders) emptied capture folder(s)."
            + (result.skipped > 0 ? " \(result.skipped) skipped because they changed since the preview." : "")
    }

    func keepDuplicates() {
        status = "Kept \(summary.duplicates) duplicate(s) in Captures. They stay marked Duplicate, and their capture folders stay until they are deleted."
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
            status = "Backup complete: \(result.folders) folders (\(result.files) TIFF/FITS) → \(result.destination.path)"
            showSortConfirm = true
        } catch {
            status = "Backup failed: \(error.localizedDescription)"
        }
    }

    func performSort() {
        isBusy = true
        defer { isBusy = false }
        do {
            let source = URL(fileURLWithPath: sourcePath)
            let sorted = entries.map(\.captureFolder)
            let result = try CaptureSorter.performSort(entries: entries, sourceRoot: source, targetsRoot: targetsRoot)
            refresh()
            let kept = CaptureSorter.leftoverImages(captureNames: sorted, sourceRoot: source)
            status = "Sort complete: \(result.move) moved, \(result.replace) replaced, \(result.removedFolders) capture folders removed."
                + (kept.isEmpty ? "" : " \(kept.count) left in place holding \(Self.describe(kept.values)).")
                + (summary.duplicates > 0 ? " \(summary.duplicates) duplicate(s) left in Captures." : "")
            if summary.duplicates > 0 {
                askAboutDuplicatesLater()
            } else if !kept.isEmpty {
                keptFolders = kept
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.showKeptFolders = true }
            }
        } catch {
            status = error.localizedDescription
        }
    }

    /// Capture folders a sort left behind because they still hold images, with counts by extension.
    @Published var keptFolders: [String: [String: Int]] = [:]
    @Published var showKeptFolders = false

    /// File types holding the leftovers that aren't ticked under Files to Move.
    var keptUnselectedTypes: [SortFileType] {
        let extensions = Set(keptFolders.values.flatMap(\.keys))
        return SortFileType.allCases.filter { !fileTypes.contains($0) && !$0.extensions.isDisjoint(with: extensions) }
    }

    var keptFoldersMessage: String {
        let lines = keptFolders.keys.sorted().map { "• \($0): \(Self.describe([keptFolders[$0] ?? [:]]))" }
        let types = keptUnselectedTypes.map(\.label).joined(separator: ", ")
        return "Everything selected has been sorted out of:\n" + lines.joined(separator: "\n") + "\n\n"
            + (types.isEmpty ? "" : "\(types) isn't ticked under Files to Move, so those images are still inside. ")
            + "Yes moves the folder and everything left in it to the Trash. No leaves it in Captures."
    }

    /// Capture folders with nothing left to sort for the ticked types that still hold other images.
    var finishedCaptureNames: [String] {
        let root = URL(fileURLWithPath: sourcePath)
        return Dictionary(grouping: entries, by: \.captureFolder).compactMap { name, rows in
            rows.allSatisfy { $0.files == 0 } && CaptureSorter.holdsImages(root.appendingPathComponent(name)) ? name : nil
        }.sorted()
    }

    func askAboutFinishedFolders() {
        keptFolders = CaptureSorter.leftoverImages(captureNames: finishedCaptureNames, sourceRoot: URL(fileURLWithPath: sourcePath))
        showKeptFolders = !keptFolders.isEmpty
    }

    func deleteKeptFolders() {
        let names = Array(keptFolders.keys)
        keptFolders = [:]
        let removed = CaptureSorter.trashCaptureFolders(names: names, sourceRoot: URL(fileURLWithPath: sourcePath))
        refresh()
        status = "Moved \(removed) finished capture folder(s) to the Trash."
            + (removed < names.count ? " \(names.count - removed) couldn't be removed." : "")
    }

    func keepFinishedFolders() {
        status = "Left \(keptFolders.count) finished capture folder(s) in Captures."
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

struct ContentView: View {
    @StateObject private var model = SortViewModel()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            workspace
        }
        .background(Color(red: 0.02, green: 0.04, blue: 0.08))
        .foregroundStyle(Color(red: 0.92, green: 0.94, blue: 1.0))
        .onAppear {
            model.refresh()
            model.askLibraryFoldersIfNeeded()
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
            Text("Create Targets \(model.pendingCreateYear ?? "") under your Captures folder? No files will be moved.")
        }
        .confirmationDialog(
            "Back up before sorting?",
            isPresented: $model.showBackupOffer,
            titleVisibility: .visible
        ) {
            Button("Back up first…") {
                model.chooseBackupLocationAndRun()
            }
            Button("Sort without backup", role: .destructive) {
                model.showSortConfirm = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Recommended: copy the capture folders to a backup location first.")
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
                Text("No TIFF/FITS left to move. Delete \(model.spentCaptureNames.count) emptied capture folder(s) at the Captures root?")
            } else {
                Text("Move \(model.summary.move) new files and replace \(model.summary.replace) older Targets files. Emptied capture folders will be deleted."
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
                Text("\(groups.count) capture folder(s) · \(model.planItems.count) files: \(model.summary.move) new · \(model.summary.replace) newer · \(model.summary.duplicates) duplicate. Nothing has been moved yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if model.planItems.isEmpty {
                    Text("No TIFF/FITS actions in this preview. Check the Source Captures path and file types.")
                        .padding(.top, 24)
                    Spacer()
                } else {
                    PlanRow.header
                    List {
                        ForEach(groups, id: \.folder) { group in
                            Section {
                                ForEach(group.items) { PlanRow(item: $0, processing: model.processingFolder(for: $0.object)) }
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
                        Text("\(model.summary.duplicates) file(s) are already in Targets and are marked Duplicate or Older copy. Sort leaves them in place.")
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
        let processing: URL?

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
                Text("Processing").frame(width: 120, alignment: .leading)
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
                Text(processing.map { "✓ \($0.lastPathComponent)" } ?? "—")
                    .font(.system(size: 11))
                    .foregroundStyle(processing == nil ? Color.secondary : Color.green)
                    .frame(width: 120, alignment: .leading)
                    .help(processing?.path ?? "No folder for this object in Processing Targets yet")
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
            case .replace: return .blue
            case .duplicate: return .orange
            case .older: return .gray
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                if let logo = Self.bigSkyAstroLogo {
                    Button { NSWorkspace.shared.open(BigSkyAstroWebLinks.home) } label: {
                        Image(nsImage: logo)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                    .help("BigSkyAstro — bigskyastro.com")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Smart Telescope Sort")
                        .font(.system(size: 17, weight: .bold))
                    Text(model.lockedKind == nil
                         ? "Multi-brand Captures → Targets"
                         : "Independent app. Not affiliated with telescope makers.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 0.58, green: 0.65, blue: 0.78))
                }
            }
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 10) {
                Text("HOW IT WORKS")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(1.1)
                    .foregroundStyle(Color(red: 0.51, green: 0.58, blue: 0.71))
                infoLine(icon: "folder", text: model.telescopeKind.dropHint + " The layout is detected; Targets {year} folders are skipped.")
                infoLine(icon: "line.3.horizontal.decrease.circle", text: "Pick a year, a month and the file types to move: TIFF, JPG/JPEG, FITS/FIT or All.")
                infoLine(icon: "list.bullet.rectangle", text: "Review file plan lists every file with its object, date and target folder.")
                infoLine(icon: "archivebox", text: "Optional Zip or Tarball backup. You name it, and a progress window shows it running.")
                infoLine(icon: "arrow.right.doc.on.clipboard", text: "Sort moves the ticked file types into Targets {year}/{object}. A newer copy replaces an older one.")
                infoLine(icon: "doc.on.doc", text: "Files already in Targets are marked Duplicate. You're asked Yes/No before they go to the Trash.")
                infoLine(icon: "trash", text: "Emptied capture folders are removed. A folder still holding unticked images asks Yes/No first.")
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
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(red: 0.55, green: 0.70, blue: 1.0))
            Button {
                NSWorkspace.shared.open(BigSkyAstroWebLinks.sourceCode)
            } label: {
                Label("Source code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
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
                HStack(spacing: 8) {
                    Circle().fill(model.sourceAvailable ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(model.sourceAvailable ? "Source available" : "Source unavailable")
                        .font(.system(size: 11))
                        .foregroundStyle(model.sourceAvailable ? Color.green : Color.orange)
                }
            }

            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Color(red: 0.45, green: 0.62, blue: 1.0))
                VStack(alignment: .leading, spacing: 2) {
                    Text("SOURCE CAPTURES")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Color(red: 0.51, green: 0.58, blue: 0.71))
                    Text(model.sourcePath)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                }
                Spacer()
                Button("…") { model.chooseSourceFolder() }
                    .buttonStyle(.bordered)
                Text("\(model.excluded) skipped as sources.")
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
                    .onChange(of: model.selectedYear) { _, _ in model.refresh() }

                    Picker("Month", selection: $model.selectedMonth) {
                        ForEach(model.months, id: \.id) { Text($0.title).tag($0.id) }
                    }
                    .frame(width: 140)
                    .onChange(of: model.selectedMonth) { _, _ in model.refresh() }

                    Button("Refresh preview") { model.refresh() }
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
                .help("Zip (.zip) or tarball (.tar.gz) of the capture folders before sorting. Built into macOS — nothing to install.")
                Text(model.backupFormat == nil
                     ? "Sort offers a folder copy instead"
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
                Text("Destination shows where TIFF/FITS files will move")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.70, green: 0.76, blue: 0.88))
            }
            Table(model.entries) {
                TableColumn("Capture folder") { (entry: CaptureEntry) in
                    Text(entry.captureFolder)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(tableInk)
                        .lineLimit(1)
                }
                .width(min: 180, ideal: 240)
                TableColumn("Year") { Text($0.year).foregroundStyle(tableInk) }.width(50)
                TableColumn("Month") { Text($0.month).foregroundStyle(tableInk) }.width(50)
                TableColumn("DSO object") {
                    Text($0.object).fontWeight(.semibold).foregroundStyle(tableInk)
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
                TableColumn("Destination") { (entry: CaptureEntry) in
                    Text("Targets \(entry.year)/\(entry.object)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tableDestination)
                        .help(entry.targetDirectory.path)
                }
                .width(min: 160, ideal: 200)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .foregroundStyle(tableInk)
            .colorScheme(.light)
            .frame(minHeight: 120, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func libraryRow(_ folder: LibraryFolder) -> some View {
        let url = model.libraryFolders[folder]
        return HStack {
            Image(systemName: folder == .originals ? "archivebox.fill" : folder == .processing ? "slider.horizontal.3" : "externaldrive.fill")
                .foregroundStyle(Color(red: 0.45, green: 0.62, blue: 1.0))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.title.uppercased())
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color(red: 0.51, green: 0.58, blue: 0.71))
                Text(url?.path ?? (folder == .originals ? "Not set — Targets {year} stay inside Source Captures" : "Not set"))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(url == nil ? Color(red: 0.90, green: 0.70, blue: 0.35) : Color(red: 0.92, green: 0.94, blue: 1.0))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if url != nil {
                Text(model.savedDefaults.contains(folder) ? "Default" : "This session")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
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
                Text("Replace only when newer.\nExisting target files are kept unless the source is newer.")
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
                Text("\(model.finishedCaptureNames.count) finished capture folder(s): nothing ticked is left to sort, but other images remain.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.68, green: 0.74, blue: 0.88))
            } else if model.actionableCount == 0, !model.spentCaptureNames.isEmpty {
                Text("\(model.spentCaptureNames.count) emptied capture folder(s) ready to delete at the Captures root.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.68, green: 0.74, blue: 0.88))
            } else if model.plannedCount == 0, model.summary.duplicates > 0 {
                Text("All \(model.summary.duplicates) file(s) are duplicates already in Targets. Delete duplicates asks before removing anything.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.95, green: 0.72, blue: 0.40))
            } else {
                Text("\(model.plannedCount) files eligible: \(model.summary.move) new moves, \(model.summary.replace) newer replacements."
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
