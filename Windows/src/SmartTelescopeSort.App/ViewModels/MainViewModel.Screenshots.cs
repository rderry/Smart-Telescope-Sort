using System.IO;
using SmartTelescopeSort.App.Services;
using SmartTelescopeSort.Core.Sorting;

namespace SmartTelescopeSort.App.ViewModels;

public sealed partial class MainViewModel
{
    /// <summary>Puts mid-run numbers in a progress window for `--capture` screenshots (the Mac's ScreenshotMode.stage).</summary>
    internal void StageProgress(ProgressKind kind)
    {
        switch (kind)
        {
            case ProgressKind.Scan:
                ScanStarted = DateTime.Now.AddSeconds(-7);
                ScanProgress = new ScanProgress(3, "Reading capture folders", 14, 21);
                break;
            case ProgressKind.Backup:
                var destination = BackupFolderPath ?? Path.Combine(Path.GetTempPath(), "Backups");
                BackupStarted = DateTime.Now.AddSeconds(-42);
                BackupTitle = $"{SuggestedBackupName}.tar.gz → {destination}";
                BackupProgress = new ArchiveProgress
                {
                    BytesDone = 1_288_490_189,
                    BytesTotal = 2_147_483_648,
                    FilesDone = 31,
                    FilesTotal = 51,
                    CurrentFile = @"2025-10-10_07-49-28_observation-M31\01-images-initial\IMG_0031.tif",
                };
                break;
            default:
                TransferExplanation = null;
                TransferStarted = DateTime.Now.AddSeconds(-18);
                TransferProgress = new TransferProgress("Copying images", 34, 51, @"Targets 2025\M31\IMG_0034.tif");
                break;
        }
    }

    internal void ClearStagedProgress()
    {
        ScanProgress = null;
        BackupProgress = null;
        TransferProgress = null;
    }
}
