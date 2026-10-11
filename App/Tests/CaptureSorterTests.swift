import Foundation
import PDFKit

/// Images from any telescope or camera sort by the object their folders name, with no smart-telescope layout needed,
/// and frames inside calibration folders such as Light/ are set aside. Run with App/Tests/run-tests.sh.
@main
struct CaptureSorterTests {
    static func main() throws {
        let t = Checker()
        let scratch = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let base = scratch.appendingPathComponent("SmartTelescopeSort-Tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        try classicObjectFolders(t, base.appendingPathComponent("classic", isDirectory: true))
        try datedAndSoftwareFolders(t, base.appendingPathComponent("dated", isDirectory: true))
        try calibrationFoldersSetAside(t, base.appendingPathComponent("calibration", isDirectory: true))
        calibrationFolderNames(t)
        try observationFoldersAtTheTop(t, base.appendingPathComponent("top", isDirectory: true))
        try creditsMatchSpec(t, base.appendingPathComponent("credits", isDirectory: true))
        try untestedNoticeAndNoCopyright(t)

        print("\(t.passed) checks passed, \(t.failures.count) failed")
        if !t.failures.isEmpty { throw TestFailures(count: t.failures.count) }
    }

    struct TestFailures: Error {
        var count: Int
    }

    /// <Object>/<files> straight off a classic rig: no dates in folder names, so the year comes from the files.
    static func classicObjectFolders(_ t: Checker, _ base: URL) throws {
        let captures = base.appendingPathComponent("Captures", isDirectory: true)
        let targets = base.appendingPathComponent("Library", isDirectory: true)
        let f = Fixture(root: captures)
        let nov2025 = day(2025, 11, 3), aug2024 = day(2024, 8, 20)
        for name in ["Light_M31_300s_0001.fits", "Light_M31_300s_0002.fits", "M31_stacked.tif", "preview.jpg",
                     "notes.txt", "IMG_0001.CR2", "IMG_0002.NEF", "capture.ser", "capture.avi", "frame.xisf", "frame.fts", "frame.png"] {
            try f.file("M31/\(name)", modified: nov2025)
        }
        try f.file("NGC 7000/frame_0001.fit", modified: aug2024)

        t.expect(TelescopeKind.detect(in: captures) == nil, "classic object folders match no smart-telescope layout")

        CaptureSorter.sortExtensions = extensions(SortFileType.defaults)
        let rows = try byObject(CaptureSorter.scan(kind: .vaonis, sourceRoot: captures, targetsRoot: targets).entries)
        t.equal(rows.keys.sorted(), ["M31", "NGC-7000"], "objects from folder names")
        t.equal(rows["M31"]?.year, "2025", "M31 year from file dates")
        t.equal(rows["M31"]?.files, 3, "M31 sorts its FITS and TIFF files only")
        t.equal(rows["M31"]?.formats, ["FITS", "TIF"], "M31 formats")
        t.equal(rows["M31"]?.needsObjectName, false, "M31 is named by its folder")
        t.equal(rows["NGC-7000"]?.year, "2024", "NGC 7000 year from file dates")
        t.equal(rows["NGC-7000"]?.formats, ["FIT"], "NGC 7000 formats")

        let entries = Array(rows.values)
        let (plans, summary) = CaptureSorter.preview(entries: entries)
        t.equal(summary.move, 4, "four new files")
        t.equal(summary.duplicate, 0, "no duplicates")
        t.equal(Set(plans.map { CaptureSorter.relativePath(of: $0.destination, in: targets) }), [
            "Targets 2025/M31/Light_M31_300s_0001.fits",
            "Targets 2025/M31/Light_M31_300s_0002.fits",
            "Targets 2025/M31/M31_stacked.tif",
            "Targets 2024/NGC-7000/frame_0001.fit",
        ], "destinations")
        t.expect(Set(plans.map { $0.source.pathExtension.lowercased() }).isSubset(of: ["fits", "fit", "tif"]),
                 "RAW, video, XISF, FTS, PNG and other files are never in the plan")

        let copied = CaptureSorter.copySort(entries: entries, sourceRoot: captures, targetsRoot: targets)
        t.expect(copied.error == nil && copied.failed.isEmpty, "copy has no errors: \(copied.error ?? "") \(copied.failed)")
        t.equal(copied.copied.count, 4, "four files copied")
        for item in copied.copied {
            t.expect(FileManager.default.contentsEqual(atPath: item.original.path, andPath: item.copy.path),
                     "\(item.copy.lastPathComponent) copied byte for byte, original kept")
        }

        CaptureSorter.sortExtensions = extensions(SortFileType.allCases)
        let withJPG = try byObject(CaptureSorter.scan(kind: .seestar, sourceRoot: captures, targetsRoot: targets).entries)
        t.equal(withJPG["M31"]?.formats, ["FITS", "JPG", "TIF"], "JPG sorts once checked")
        CaptureSorter.sortExtensions = extensions(SortFileType.defaults)
    }

    /// Date and target folders as capture software writes them, a DSLR export, the Moon, and a folder naming no object.
    static func datedAndSoftwareFolders(_ t: Checker, _ base: URL) throws {
        let captures = base.appendingPathComponent("Captures", isDirectory: true)
        let targets = base.appendingPathComponent("Library", isDirectory: true)
        let f = Fixture(root: captures)
        try f.file("2026-10-07/M42/M42_0001.fits")
        try f.file("2026-10-07/M42/M42_0002.fits")
        try f.file("M81/2026-10-06/M81_0001.fits")
        try f.file("SharpCap Captures/2026-10-05/M27/22_15_03/Capture_00001.fits")
        try f.file("DSLR Export/M45/IMG_1234.tif", modified: day(2024, 1, 15))
        try f.file("Moon/2026-09-17/moon_001.tif")
        try f.file("Session 3/frame_0001.fits", modified: day(2026, 3, 1))

        t.expect(TelescopeKind.detect(in: captures) == nil, "dated classic folders match no smart-telescope layout")

        CaptureSorter.sortExtensions = extensions(SortFileType.defaults)
        let rows = try byObject(CaptureSorter.scan(kind: .dwarf, sourceRoot: captures, targetsRoot: targets).entries)
        t.equal(rows.keys.sorted(), ["M27", "M42", "M45", "M81", "MOON", "SESSION-3"], "objects")
        t.equal(rows["M42"]?.files, 2, "M42 files")
        t.equal(rows["M42"]?.session, "2026-10-07", "date folder above the object")
        t.equal(rows["M81"]?.session, "2026-10-06", "date folder below the object")
        t.equal(rows["M27"]?.captureFolder, "SharpCap Captures/2026-10-05/M27", "nearest folder naming the object")
        t.equal(rows["M27"]?.session, "2026-10-05", "date from a folder above the time folder")
        t.equal(rows["M45"]?.year, "2024", "no dated folder: year from the file date")
        t.equal(rows["MOON"]?.year, "2026", "solar-system name")
        t.equal(rows["SESSION-3"]?.needsObjectName, true, "a folder naming no object is named by the user")
        t.equal(rows["SESSION-3"]?.sessionDate, "2026-03-01", "date offered as its name")
        for (object, row) in rows where object != "SESSION-3" {
            t.equal(row.needsObjectName, false, "\(object) is named by a folder")
        }
    }

    /// Frames left in Light/, Dark/, Flat/, Bias/ or Master… folders are set aside, as for every layout; lights moved
    /// into the object folder sort.
    static func calibrationFoldersSetAside(_ t: Checker, _ base: URL) throws {
        let captures = base.appendingPathComponent("Captures", isDirectory: true)
        let f = Fixture(root: captures)
        try f.file("Light/M31/Light_M31_0001.fits")
        try f.file("M33/2026-10-01/LIGHT/M33_Light_0001.fits")
        try f.file("M33/2026-10-01/FLAT/M33_Flat_0001.fits")
        try f.file("M33/Darks/Dark_300s_0001.fits")
        try f.file("Bias/Bias_0001.fits")
        try f.file("Master Flats/MasterFlat_Ha.fits")
        try f.file("M31/Light_M31_0002.fits")

        CaptureSorter.sortExtensions = extensions(SortFileType.defaults)
        let entries = try CaptureSorter.scan(kind: .origin, sourceRoot: captures).entries
        t.equal(entries.map(\.object), ["M31"], "only the frame outside a calibration folder sorts")
        t.equal(entries.first.map { $0.sourceFiles.map { CaptureSorter.relativePath(of: $0, in: captures) } },
                ["M31/Light_M31_0002.fits"], "sorted file")

        let expected: Set<String> = ["Light", "M33/2026-10-01/LIGHT", "M33/2026-10-01/FLAT", "M33/Darks", "Bias", "Master Flats"]
        t.equal(Set(CaptureSorter.calibrationFolders(under: captures).map(\.path)), expected, "calibration folders set aside")
        let setAside = CaptureSorter.setAsideFolders(under: captures, monitor: nil)
        t.equal(Set(setAside.calibration.map(\.path)), expected, "scan's set-aside calibration folders")
        t.expect(setAside.plateSolves.isEmpty, "no plate solves")
    }

    static func calibrationFolderNames(_ t: Checker) {
        for name in ["Light", "Lights", "LIGHT", "Dark", "Darks", "Dark Flats", "Dark_Flats", "Flat", "Flats1x20", "Bias", "Biases", "Master Darks"] {
            t.expect(CaptureSorter.isCalibrationFolder(name), "\(name) is a calibration folder")
        }
        for name in ["M31", "NGC 7000", "Lighthouse", "Darkness", "2026-10-07", "SharpCap Captures"] {
            t.expect(!CaptureSorter.isCalibrationFolder(name), "\(name) is not a calibration folder")
        }
    }

    /// NN-observation folders copied straight into the Capture Folder are their own captures, not the Capture Folder;
    /// one with nothing left to sort stays in the scan but isn't listed.
    static func observationFoldersAtTheTop(_ t: Checker, _ base: URL) throws {
        let captures = base.appendingPathComponent("Captures", isDirectory: true)
        let f = Fixture(root: captures)
        try f.file("04-observation-m92/01-images-initial/M92_0001.fits", modified: day(2025, 10, 7))
        try f.file("04-observation-m92/Untitled.afphoto", modified: day(2025, 10, 7))
        try f.file("05-observation-m13/M13_0001.fits", modified: day(2025, 10, 7))
        try f.file("2026-09-14_07-20-55_plan_Demo_Night/01-observation-ngc7000/01-images-initial/NGC7000_0001.fits")
        try f.file("06-observation-m57/01-images-initial/capture.json", modified: day(2025, 10, 7))

        CaptureSorter.sortExtensions = extensions(SortFileType.defaults)
        let entries = try CaptureSorter.scan(kind: .vaonis, sourceRoot: captures).entries
        let rows = byObject(entries)
        t.equal(rows["M92"]?.captureFolder, "04-observation-m92", "top-level observation folder is its own capture")
        t.equal(rows["M13"]?.captureFolder, "05-observation-m13", "top-level observation folder without an images folder")
        t.equal(rows["NGC7000"]?.captureFolder, "2026-09-14_07-20-55_plan_Demo_Night", "a nested observation folder keeps its plan folder")
        t.equal(entries.filter { $0.captureFolder.isEmpty }.count, 0, "no row is labelled with the Capture Folder")
        t.equal(CaptureSorter.backupPaths(for: rows["M92"].map { [$0] } ?? [], sourceRoot: captures), ["04-observation-m92"],
                "a backup takes the whole observation folder, .afphoto included")

        t.equal(rows["M57"]?.files, 0, "an observation folder with nothing to sort still scans")
        let shown = CaptureSorter.rowsToShow(entries)
        t.equal(shown.map(\.object).sorted(), ["M13", "M92", "NGC7000"], "rows with no files aren't listed")
        t.expect(shown.allSatisfy { $0.files > 0 }, "every listed row has files")
    }

    static let creditsSpec = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STS_CREDITS_SPEC"]
        ?? "/Volumes/Large Drive/Marketing Field Data/Shared/Credits-Popup-Spec.md")

    /// The Credits popup follows the shared spec: logo, the four people in order, then names-only data sources with
    /// GitHub, each catalog being one the sorter really recognizes in folder names.
    static func creditsMatchSpec(_ t: Checker, _ base: URL) throws {
        let expectedPeople = [
            "R Derry — Developer and Owner",
            "F Derry — Full Time Beta Tester",
            "Otto — Programming and Smoke Testing",
            "A Derry — Interface Consultant",
        ]
        t.equal(Credits.peopleLines, expectedPeople, "people lines and order")
        if let spec = try? String(contentsOf: creditsSpec, encoding: .utf8),
           let start = spec.range(of: "2. People"), let end = spec.range(of: "3. Data sources", range: start.upperBound..<spec.endIndex) {
            let fromSpec = spec[start.upperBound..<end.lowerBound]
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("- ") }
                .map { String($0.dropFirst(2)) }
            t.equal(Credits.peopleLines, fromSpec, "people lines match \(creditsSpec.lastPathComponent)")
        } else {
            t.expect(false, "spec readable with People and Data sources sections: \(creditsSpec.path)")
        }
        t.equal([Credits.peopleHeading, Credits.dataSourcesHeading], ["People", "Data sources"], "section order")

        let logo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/\(Credits.logoResource).png")
        t.expect(FileManager.default.fileExists(atPath: logo.path), "logo is bundled: \(logo.lastPathComponent)")

        t.equal(Credits.dataSources.first, "GitHub (open source, MIT license)", "GitHub listed first, with the MIT license")
        for line in Credits.peopleLines + Credits.dataSources {
            let lower = line.lowercased()
            t.expect(!["http", "://", "www.", ".com", ".org", "@"].contains { lower.contains($0) }, "no link in \"\(line)\"")
        }
        t.equal(Set(Credits.dataSources).count, Credits.dataSources.count, "no repeated data sources")

        let samples = [
            "Messier catalog": "M 31", "New General Catalogue (NGC)": "NGC 891", "Index Catalogue (IC)": "IC 1396",
            "Sharpless catalog (Sh2)": "Sh2-155", "Barnard catalog": "Barnard 33", "Lynds Dark Nebulae (LDN)": "LDN 1622",
            "Lynds Bright Nebulae (LBN)": "LBN 437", "van den Bergh catalog (vdB)": "vdB 142", "Abell catalog": "Abell 2151",
            "Arp Atlas of Peculiar Galaxies": "Arp 273", "Melotte catalog": "Mel 111", "Collinder catalog": "Collinder 399",
            "Uppsala General Catalogue (UGC)": "UGC 12158", "Principal Galaxies Catalogue (PGC)": "PGC 2557",
            "Caldwell catalog": "Caldwell 14",
        ]
        t.equal(Set(Credits.dataSources.dropFirst()), Set(samples.keys), "every listed catalog has a sample designation")
        let captures = base.appendingPathComponent("Captures", isDirectory: true)
        let f = Fixture(root: captures)
        for folder in samples.values {
            try f.file("\(folder)/frame_0001.fits", modified: day(2026, 1, 10))
        }
        CaptureSorter.sortExtensions = extensions(SortFileType.defaults)
        let entries = try CaptureSorter.scan(kind: .vaonis, sourceRoot: captures).entries
        t.equal(entries.count, samples.count, "one row per catalog folder")
        for entry in entries {
            t.expect(!entry.needsObjectName, "\(entry.captureFolder) is recognized as a catalog object")
        }
    }

    static func byObject(_ entries: [CaptureEntry]) -> [String: CaptureEntry] {
        Dictionary(entries.map { ($0.object, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func extensions(_ types: [SortFileType]) -> Set<String> {
        types.reduce(into: []) { $0.formUnion($1.extensions) }
    }

    /// The bold notice opens the main window and page 1 of the manual; no "© 2026 BigSkyAstro" line is left anywhere.
    static func untestedNoticeAndNoCopyright(_ t: Checker) throws {
        let notice = "This has not been tested with other telescopes, but there is no reason it will not work with almost any data that it supports!"
        t.equal(TelescopeKind.untestedNotice, notice, "notice wording")

        let program = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = program.appendingPathComponent("App", isDirectory: true)
        let view = try String(contentsOf: app.appendingPathComponent("Sources/ContentView.swift"), encoding: .utf8)
        if let at = view.range(of: "Text(TelescopeKind.untestedNotice)") {
            let next = view[at.upperBound...].prefix(120)
            t.expect(next.contains(".bold()"), "the notice is bold")
            t.expect(view[..<at.lowerBound].hasSuffix("var body: some View {\n        VStack(spacing: 0) {\n            "),
                     "the notice is the first thing in the main window")
        } else {
            t.expect(false, "ContentView shows TelescopeKind.untestedNotice")
        }

        let sources = try FileManager.default.contentsOfDirectory(at: app.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let checked = sources + ["Scripts/build-user-manual.py", "Info.plist", "Info-macOS15.plist", "macos15-installer/README.txt"]
            .map { app.appendingPathComponent($0) } + [program.appendingPathComponent("AppStore/ASC-Listing-Copy.md")]
        for file in checked where FileManager.default.fileExists(atPath: file.path) {
            let text = try String(contentsOf: file, encoding: .utf8)
            t.expect(!text.contains("©") && !text.contains("2026 BigSkyAstro"), "no copyright line in \(file.lastPathComponent)")
        }

        let pdf = app.appendingPathComponent("Resources/Telescope-Data-Sort-User-Manual.pdf")
        guard let manual = PDFDocument(url: pdf), let first = manual.page(at: 0)?.string else {
            t.expect(false, "manual PDF readable: \(pdf.path)")
            return
        }
        let flat = { (s: String) in s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        t.expect(flat(first).contains(notice), "manual page 1 has the notice")
        if let styled = manual.page(at: 0)?.attributedString,
           case let at = (styled.string as NSString).range(of: "This has not been tested"), at.location != NSNotFound,
           let font = styled.attribute(.font, at: at.location, effectiveRange: nil) as? NSFont {
            t.expect(font.fontName.contains("Bold"), "manual notice is bold: \(font.fontName)")
        } else {
            t.expect(false, "manual notice font readable")
        }
        t.expect(!(manual.string ?? "").contains("©"), "manual has no copyright line")
        t.expect((manual.string ?? "").contains("Open-source freeware"), "manual says Open-source freeware")
    }

    /// Noon local time, so the year can't shift with the time zone.
    static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}

struct Fixture {
    let root: URL

    /// Writes a small file whose bytes are its own path, so no two fixtures are identical.
    func file(_ path: String, modified: Date? = nil) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(path.utf8).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }
}

final class Checker {
    var passed = 0
    var failures: [String] = []

    func expect(_ ok: Bool, _ what: String, line: Int = #line) {
        if ok {
            passed += 1
        } else {
            failures.append(what)
            print("FAIL (line \(line)): \(what)")
        }
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ what: String, line: Int = #line) {
        expect(actual == expected, "\(what): got \(actual), expected \(expected)", line: line)
    }
}
