#if SCREENSHOTS
import AppKit
import SwiftUI

/// Stages App Store screenshots from demo folders. Compiled only into the screenshot build (-D SCREENSHOTS),
/// driven by environment variables from App/Screenshots/capture-screenshots.sh.
@MainActor
enum ScreenshotMode {
    private static let env = ProcessInfo.processInfo.environment

    static var isActive: Bool { env["STS_SHOT"] != nil }

    /// The terms shot shows the first-launch agreement, unchecked, whatever this Mac has recorded.
    nonisolated static var showsNewUserTerms: Bool { ProcessInfo.processInfo.environment["STS_SHOT"] == "terms" }

    static func stage(_ model: SortViewModel) {
        guard let shot = env["STS_SHOT"] else { return }
        for (folder, name) in [(LibraryFolder.originals, "STS_ORIGINALS"), (.backup, "STS_BACKUP")] {
            if let path = env[name] { model.libraryFolders[folder] = URL(fileURLWithPath: path) }
        }
        if let types = env["STS_TYPES"] {
            model.fileTypes = Set(types.split(separator: ",").compactMap { SortFileType(rawValue: String($0)) })
        }
        if let format = env["STS_FORMAT"] { model.backupFormat = BackupFormat(rawValue: format) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.isVisible }),
               let frame = env["STS_FRAME"].map(NSRectFromString) {
                window.setFrame(frame, display: true)
                let screenHeight = window.screen?.frame.height ?? 0
                let f = window.frame
                let topLeft = "\(Int(f.minX)),\(Int(screenHeight - f.maxY)),\(Int(f.width)),\(Int(f.height))"
                if let frameFile = env["STS_FRAME_FILE"] {
                    try? topLeft.write(toFile: frameFile, atomically: true, encoding: .utf8)
                }
            }
        }
        model.refreshInBackground {
            switch shot {
            case "plan":
                model.reviewFilePlan()
            case "backup":
                let destination = model.libraryFolders[.backup]?.path ?? ""
                model.backupStarted = Date().addingTimeInterval(-38)
                model.backupTitle = "\(model.suggestedBackupName).tar.gz → \(destination)"
                model.backupProgress = ArchiveProgress(
                    bytesDone: 1_310_000_000, bytesTotal: 2_050_000_000, filesDone: 241, filesTotal: 382,
                    currentFile: "2026-09-12_01-40-22_observation_NGC7023/img-0241r.fits")
            case "copy":
                model.transferStarted = Date().addingTimeInterval(-74)
                model.transferProgress = TransferProgress(
                    phase: "Copying images", done: 148, total: 231,
                    item: "2026-09-12_01-40-22_observation_NGC7023/01-images-initial/img-0148r.fits")
            case "terms":
                NotificationCenter.default.post(name: .showAssumptions, object: nil)
            case "finished":
                model.keptFolders = ["2026-09-12_01-40-22_observation_NGC7023": ["jpg": 6]]
                model.showKeptFolders = true
            case "credit":
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { SourceCodeCredit.openRepository() }
            default:
                break
            }
        }
    }
}
#endif
