using System.Globalization;
using System.IO;
using SmartTelescopeSort.App.Services;
using SmartTelescopeSort.Core.IO;
using SmartTelescopeSort.Core.Settings;
using SmartTelescopeSort.Core.Sorting;

namespace SmartTelescopeSort.App.ViewModels;

public sealed partial class MainViewModel
{
    // MARK: Backup

    private ArchiveJob? _backupJob;
    private ArchiveProgress? _backupProgress;

    public bool IsBackingUp => _backupJob is not null;

    public ArchiveProgress? BackupProgress
    {
        get => _backupProgress;
        private set => Set(ref _backupProgress, value);
    }

    public string BackupTitle { get; private set; } = "";
    public DateTime BackupStarted { get; private set; } = DateTime.Now;

    public void CancelBackup() => _backupJob?.Cancel();

    public string BackupOfferMessage
    {
        get
        {
            var destination = BackupFolderPath ?? "Backup Storage (you'll be asked where)";
            var kind = _backupFormat is { } f ? $"a {f.Label()} archive (.{f.FileExtension()})" : "a copy";
            return $"Yes saves {kind} of the capture folders in {destination} before anything moves. No sorts without a backup.";
        }
    }

    /// <summary>Objects being sorted plus the date and time, e.g. "MOON Backup 2026-10-03 15-27".</summary>
    public string SuggestedBackupName
    {
        get
        {
            var objects = _entries.Where(e => e.Files > 0).Select(e => e.Object).Distinct().OrderBy(o => o, StringComparer.Ordinal).ToList();
            var label = objects.Count == 0 ? "Captures" : objects.Count <= 3 ? string.Join(" ", objects) : $"{objects.Count} objects";
            return $"{label} Backup {DateTime.Now.ToString("yyyy-MM-dd HH-mm", CultureInfo.InvariantCulture)}";
        }
    }

    private string? AskBackupName(string kind, string destination)
    {
        var typed = Prompts.AskBackupName("Name this backup",
            $"{kind} of the capture folders will be saved in {destination}. A number is added if the name is already used.",
            SuggestedBackupName, CaptureSorter.DefaultBackupName);
        return typed is null ? null : CaptureSorter.BackupBaseName(typed);
    }

    // MARK: Sort flow

    /// <summary>Sort eligible files: finished folders, duplicates only, or the backup offer then the sort.</summary>
    public async Task BeginSortFlowAsync()
    {
        if (!CanSortOrCleanup || IsBackingUp) return;
        if (OnlyFinishedFolders)
        {
            await AskAboutFinishedFoldersAsync();
            return;
        }
        if (PlannedCount == 0 && _summary.Duplicates > 0)
        {
            await ConfirmDuplicatesAsync();
            return;
        }
        var answer = Prompts.Choose("Back up before sorting?", BackupOfferMessage,
            new[] { "Yes, back up first", "No, sort without backup", "Cancel" }, defaultIndex: 0, cancelIndex: 2);
        switch (answer)
        {
            case 0:
                var backedUp = _backupFormat is { } format ? await ArchiveAsync(format) : await CopyBackupAsync();
                if (backedUp) await ConfirmSortAsync();
                break;
            case 1:
                await ConfirmSortAsync();
                break;
        }
    }

    public async Task ConfirmDuplicatesAsync()
    {
        if (Prompts.Confirm("Delete duplicates?", DuplicatePrompt)) await DeleteDuplicatesAsync();
        else KeepDuplicates();
    }

    private async Task ConfirmSortAsync()
    {
        var message = ActionableCount == 0
            ? $"No image files left to move. Delete {SpentCaptureNames.Count} emptied capture folder(s) in the Capture Folder?"
            : $"Copy {_summary.Move} files into Targets {{year}}\\{{object}}, checking each copy byte for byte. Nothing in Targets is overwritten. "
              + "When all moves are done you're asked twice before the originals and emptied capture folders are deleted.";
        var answer = Prompts.Choose("Sort eligible files?", message, new[] { "Sort now", "Cancel" }, defaultIndex: 1, cancelIndex: 1, destructiveIndex: 0);
        if (answer == 0) await PerformSortAsync();
    }

    /// <summary>Zip or tarball backup of the capture folders into Backup Storage; true once it succeeds.</summary>
    private async Task<bool> ArchiveAsync(BackupFormat format)
    {
        if (BackupFolderPath is null) ChooseLibraryFolder(LibraryFolder.Backup, refresh: false);
        if (BackupFolderPath is not { } destination)
        {
            Status = "No Backup Storage location — nothing was moved.";
            return false;
        }
        if (IsBackingUp) return false;
        if (AskBackupName($"{format.Label()} (.{format.FileExtension()})", destination) is not { } name)
        {
            Status = "Backup cancelled — nothing was moved.";
            return false;
        }
        var source = SourcePath;
        var names = CaptureSorter.BackupPaths(_entries, source);
        var job = new ArchiveJob();
        _backupJob = job;
        OnPropertiesChanged(nameof(IsBackingUp), nameof(CanSort), nameof(CanChangeFolders));
        BackupStarted = DateTime.Now;
        BackupTitle = $"{name}.{format.FileExtension()} → {destination}";
        BackupProgress = new ArchiveProgress { CurrentFile = "" };
        Status = $"Creating {format.Label()} backup in {destination}…";
        try
        {
            string? archive;
            using (Prompts.ShowProgress(ProgressKind.Backup))
            {
                archive = await Task.Run(() => CaptureSorter.ArchiveCaptureFolders(names, source, destination, format, name, job,
                    progress => _dispatcher.BeginInvoke(() =>
                    {
                        if (_backupJob == job) BackupProgress = progress;
                    })));
            }
            BackupFailed = false;
            Status = archive is null ? "No capture folders to back up." : $"Backup complete: {Path.GetFileName(archive)} in {destination}";
            return true;
        }
        catch (ArchiveJob.CancelledException)
        {
            Status = "Backup cancelled — nothing was moved.";
            return false;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            BackupFailed = true;
            Status = $"Backup failed — nothing was moved. {e.Message}";
            return false;
        }
        finally
        {
            _backupJob = null;
            BackupProgress = null;
            OnPropertiesChanged(nameof(IsBackingUp), nameof(CanSort), nameof(CanChangeFolders));
        }
    }

    /// <summary>A plain folder copy, used when the backup format is Off.</summary>
    private async Task<bool> CopyBackupAsync()
    {
        if (BackupFolderPath is null) ChooseLibraryFolder(LibraryFolder.Backup, refresh: false);
        if (BackupFolderPath is not { } destination || AskBackupName("A folder copy", destination) is not { } name)
        {
            Status = "Backup cancelled — nothing was moved.";
            return false;
        }
        var entries = _entries;
        var source = SourcePath;
        IsBusy = true;
        try
        {
            var result = await Task.Run(() => CaptureSorter.BackupCaptureFolders(entries, source, destination, name));
            Status = $"Backup complete: {result.Folders} folders ({result.Files} image files) → {result.Destination}";
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Status = $"Backup failed: {e.Message}";
            return false;
        }
        finally
        {
            IsBusy = false;
        }
    }

    public async Task DeleteDuplicatesAsync()
    {
        var source = SourcePath;
        var duplicates = DuplicateItems;
        var (permanent, keptLong) = await AskAboutLongPathsAsync(duplicates.Select(i => i.Source).ToList());
        DuplicateCleanup result;
        using (FileOps.AllowPermanentDelete(permanent))
            result = CaptureSorter.DeleteDuplicates(duplicates, source, WithoutAstrometry);
        var removedHeld = AskToDeleteHeld(result.Held, offerAstrometry: false,
            allowing => CaptureSorter.RemoveSpentCaptureFolders(result.Held.Keys.ToList(), source, allowing));
        var changed = result.Skipped - keptLong;
        await RefreshAsync(() => Status =
            $"Deleted {result.Deleted} duplicate(s) from the Capture Folder and removed {result.RemovedFolders + removedHeld} emptied capture folder(s)."
            + (changed > 0 ? $" {changed} skipped because they changed since the preview." : "")
            + LongPathsKept(keptLong));
    }

    public void KeepDuplicates() =>
        Status = $"Kept {_summary.Duplicates} duplicate(s) in the Capture Folder. They stay marked Duplicate, and their capture folders stay until they are deleted.";

    private async Task PerformSortAsync()
    {
        var rows = _entries;
        if (rows.Any(e => e.NeedsObjectName && e.Files > 0))
        {
            if (AskObjectNames(rows) is not { } named)
            {
                Status = "Sort cancelled — nothing was moved.";
                return;
            }
            rows = named;
        }
        await SortAsync(rows);
    }

    /// <summary>
    /// Names every row whose folders don't name an object, all in one list. Unchecked rows are left out, so their files
    /// stay in the Capture Folder; null when the user cancels the sort.
    /// </summary>
    private List<CaptureEntry>? AskObjectNames(IReadOnlyList<CaptureEntry> rows)
    {
        var unnamed = rows.Where(e => e.NeedsObjectName && e.Files > 0).ToList();
        var groups = unnamed.GroupBy(e => e.CaptureFolder).ToDictionary(g => g.Key, g => g.ToList());
        var requests = groups.Keys.OrderBy(k => k, Core.Common.NaturalComparer.Instance).Select(key =>
        {
            var group = groups[key];
            return new NameRequest(key, key.Length == 0 ? R.LastComponent(SourcePath) : key,
                $"{group.Sum(e => e.Files)} image(s) · {R.LastComponent(group[0].YearFolder)}", group[0].SessionDate, group[0].Object);
        }).ToList();
        var choices = unnamed.Select(e => e.YearFolder).Distinct().SelectMany(FolderNames).ToList();
        var names = Prompts.AskNames($"Name the {requests.Count} folder(s) with no object name",
            "No folder names a DSO or other celestial object for these images. Each is filled in with its date; keep it, "
            + "pick an object already in Targets {year}, or type a name. Uncheck a folder to leave its images in the Capture Folder.",
            requests, SortedChoices(choices), "Sort All", "Cancel Sort");
        if (names is null) return null;
        var result = new List<CaptureEntry>();
        foreach (var row in rows)
        {
            if (!row.NeedsObjectName || row.Files == 0) result.Add(row);
            else if (names.TryGetValue(row.CaptureFolder, out var name)) result.Add(row.Named(name));
        }
        return result;
    }

    private static IReadOnlyList<string> SortedChoices(IEnumerable<string> choices) =>
        choices.Distinct().OrderBy(c => c, Core.Common.NaturalComparer.Instance).ToList();

    private static IEnumerable<string> FolderNames(string parent)
    {
        try
        {
            return new DirectoryInfo(parent).EnumerateDirectories()
                .Where(d => !FileOps.IsHidden(d)).Select(d => d.Name).ToList();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return Array.Empty<string>();
        }
    }

    /// <summary>A typed object name made safe for a folder: no slashes or colons, no surrounding spaces or dots.</summary>
    public static string FolderName(string typed) => WindowsNames.Safe(typed);

    // MARK: Transfers

    private TransferProgress? _transferProgress;

    public TransferProgress? TransferProgress
    {
        get => _transferProgress;
        private set => Set(ref _transferProgress, value);
    }

    /// <summary>Title and note for the transfer window when the job isn't a sort.</summary>
    public (string Title, string Note)? TransferExplanation { get; private set; }

    public DateTime TransferStarted { get; private set; } = DateTime.Now;

    private TransferMonitor? _transferMonitor;
    private int _transferGeneration;

    /// <summary>Copied and checked during this sort. Deleted only when the user says Yes twice once every move is done.</summary>
    private List<CopiedItem> _pendingOriginals = new();

    public void StopTransfer() => _transferMonitor?.Cancel();

    /// <summary>Runs `work` off the UI thread with the transfer window up; returns its result and whether the user stopped it.</summary>
    private async Task<(T Result, bool Stopped)> RunTransferAsync<T>(string phase, Func<TransferMonitor, T> work, bool deleting = false,
                                                                    (string Title, string Note)? explanation = null)
    {
        TransferExplanation = explanation;
        var generation = ++_transferGeneration;
        var monitor = new TransferMonitor(progress => _dispatcher.BeginInvoke(() =>
        {
            if (generation == _transferGeneration && TransferProgress is not null) TransferProgress = progress;
        }));
        _transferMonitor = monitor;
        IsBusy = true;
        TransferStarted = DateTime.Now;
        TransferProgress = new TransferProgress(phase, Deleting: deleting);
        try
        {
            T result;
            using (Prompts.ShowProgress(ProgressKind.Transfer))
            {
                result = await Task.Run(() => work(monitor));
            }
            return (result, monitor.IsCancelled);
        }
        finally
        {
            TransferProgress = null;
            _transferMonitor = null;
            IsBusy = false;
        }
    }

    /// <summary>
    /// Asked separately, after the usual Yes/No questions, about anything the Recycle Bin can't take because its path is
    /// 260 characters or longer, since deleting it would be permanent. Keep Them is the default. Returns the items that
    /// may be deleted permanently, and how many are kept instead.
    /// </summary>
    private async Task<(IReadOnlyList<string> Permanent, int Kept)> AskAboutLongPathsAsync(IReadOnlyList<string> candidates)
    {
        var found = await Task.Run(() => candidates.Distinct(StringComparer.OrdinalIgnoreCase)
            .Select(path => (Item: path, Long: FileOps.TooLongForRecycleBin(path)))
            .Where(x => x.Long.Count > 0)
            .ToList());
        if (found.Count == 0) return (Array.Empty<string>(), 0);
        var paths = found.SelectMany(x => x.Long).ToList();
        var folders = found.Count(x => !x.Long.Contains(x.Item, StringComparer.OrdinalIgnoreCase));
        const int shown = 8;
        var answer = Prompts.Choose(
            paths.Count == 1 ? "1 item can't go to the Recycle Bin" : $"{paths.Count} items can't go to the Recycle Bin",
            "Their paths are 260 characters or longer, more than the Recycle Bin can take. Deleting them would delete them "
            + "permanently: they could not be restored from the Recycle Bin.\n\n"
            + string.Join("\n", paths.Take(shown).Select(p => "• " + p))
            + (paths.Count > shown ? $"\n…and {paths.Count - shown} more" : "")
            + (folders == 0 ? "" : $"\n\nThey are inside {folders} folder(s) that would be deleted. Keep Them keeps those folders whole; "
                                   + "Delete Permanently deletes those folders and everything in them for good.")
            + "\n\nKeep Them leaves these where they are; everything else still goes to the Recycle Bin. Delete Permanently deletes them for good.",
            new[] { "Keep Them", "Delete Permanently" }, defaultIndex: 0, cancelIndex: 0, destructiveIndex: 1);
        return answer == 1 ? (found.Select(x => x.Item).ToList(), 0) : (Array.Empty<string>(), found.Count);
    }

    private static Func<TransferMonitor, T> Permitting<T>(IReadOnlyList<string> permanent, Func<TransferMonitor, T> work) => monitor =>
    {
        using (FileOps.AllowPermanentDelete(permanent)) return work(monitor);
    };

    private static string LongPathsKept(int kept) =>
        kept == 0 ? "" : $" {kept} item(s) with paths too long for the Recycle Bin were kept.";

    /// <summary>
    /// Copy then delete: copies and checks every file, asks about plate solves and calibration folders, and only then
    /// offers to delete the originals.
    /// </summary>
    private async Task SortAsync(IReadOnlyList<CaptureEntry> rows)
    {
        var source = SourcePath;
        var targets = TargetsRoot;
        var sorted = rows.Select(r => r.CaptureFolder).ToList();
        _pendingOriginals = new List<CopiedItem>();
        var (result, stopped) = await RunTransferAsync("Copying images", monitor => CaptureSorter.CopySort(rows, source, targets, monitor));
        if (result.Error is { } error)
        {
            Status = error;
            return;
        }
        _pendingOriginals = result.Copied.ToList();
        Status = $"Copied {result.Copied.Count} image file(s) into Targets {{year}}\\{{object}}, each checked byte for byte."
                 + (result.Failed.Count == 0 ? "" : $" {result.Failed.Count} couldn't be copied and stay where they are.")
                 + (stopped ? " Copying was stopped early." : "");
        if (!stopped)
        {
            await AskAboutSetAsideFoldersAsync(SetAsideKind.PlateSolves);
            await AskAboutSetAsideFoldersAsync(SetAsideKind.Calibration);
        }
        await AskToDeleteOriginalsAsync(sorted);
    }

    /// <summary>Once every move is done: asks twice before deleting the originals that were copied, then tidies emptied folders.</summary>
    private async Task AskToDeleteOriginalsAsync(List<string> sorted)
    {
        var items = _pendingOriginals;
        _pendingOriginals = new List<CopiedItem>();
        if (items.Count == 0)
        {
            await FinishCleanupAsync(sorted, originalsDeleted: true);
            return;
        }
        var files = items.Count(i => !i.IsFolder);
        var folders = items.Count - files;
        var what = string.Join(" and ", new[]
        {
            files > 0 ? $"{files} image file(s)" : null,
            folders > 0 ? $"{folders} plate-solve or calibration folder(s)" : null,
        }.OfType<string>());

        if (!Prompts.Confirm("All moves are done. Delete the original folders and files?",
                $"{what} were copied and each copy was checked byte for byte against its original. The originals are still in the Capture Folder.\n\n"
                + "Yes deletes the originals. No keeps them; the next scan marks them Duplicate.")
            || !Prompts.Confirm("Are you sure?",
                $"This moves {what} from the Capture Folder to the Recycle Bin (or deletes them outright on a drive without one). "
                + "The copies in the Target Folder are not touched."))
        {
            Status += $" Kept the originals of {what} in the Capture Folder.";
            await FinishCleanupAsync(sorted, originalsDeleted: false);
            return;
        }
        var (permanent, keptLong) = await AskAboutLongPathsAsync(items.Select(i => i.Original).ToList());
        var (result, _) = await RunTransferAsync("Deleting originals",
            Permitting(permanent, monitor => CaptureSorter.DeleteOriginals(items, monitor)), deleting: true);
        var changed = result.Skipped.Count - keptLong;
        Status += $" Deleted {result.Deleted} original(s)."
                  + (changed <= 0 ? "" : $" {changed} kept because they or their copies changed, or deleting was stopped.")
                  + LongPathsKept(keptLong);
        await FinishCleanupAsync(sorted, originalsDeleted: true);
    }

    /// <summary>
    /// Removes capture folders the sort left empty, rescans the Capture Folder and, when the originals were deleted,
    /// offers to delete the processed capture folders and everything left in them.
    /// </summary>
    private async Task FinishCleanupAsync(List<string> sorted, bool originalsDeleted)
    {
        if (originalsDeleted)
        {
            var plateSolvesGone = CaptureSorter.PlateSolveFolders(SourcePath).Count == 0;
            var spent = CaptureSorter.RemoveSpentCaptureFolders(sorted, SourcePath, new DeletePermissions(_deleteJson, _deleteAstrometry && plateSolvesGone));
            if (spent.Removed > 0) Status += $" Removed {spent.Removed} emptied capture folder(s).";
        }
        var message = Status;
        await RefreshAsync(() => Status = message);
        if (originalsDeleted) await AskToDeleteProcessedFoldersAsync(sorted);
    }

    /// <summary>
    /// After the rescan: offers to delete the capture folders this sort processed and all the data left in them, asking
    /// Yes/No twice. Never offers the Capture Folder itself, a folder holding Targets, the Target Folder or Backup Storage,
    /// or a folder still holding images that aren't in Targets yet.
    /// </summary>
    private async Task AskToDeleteProcessedFoldersAsync(List<string> sorted)
    {
        var source = R.Normalize(SourcePath);
        var guarded = new[] { TargetsRoot, TargetFolderPath, BackupFolderPath }.OfType<string>().Select(R.Normalize).ToList();
        var unsorted = _planItems.Where(p => p.Action == SortAction.Move).Select(p => p.CaptureFolder).ToHashSet();
        var stillUnsorted = 0;
        var names = CaptureSorter.Outermost(sorted).Where(name =>
        {
            if (name.Length == 0) return false;
            var path = R.Combine(source, name);
            if (!FileOps.Exists(path) || guarded.Any(g => R.IsSameOrInside(g, path))) return false;
            if (unsorted.Any(u => u.Length > 0 && R.IsSameOrInside(R.Combine(source, u), path)))
            {
                stillUnsorted++;
                return false;
            }
            return true;
        }).ToList();
        var keptNote = stillUnsorted > 0 ? $" {stillUnsorted} processed folder(s) kept because they still hold images not in Targets yet." : "";
        if (names.Count == 0)
        {
            Status += keptNote;
            return;
        }
        var contents = names.Select(n => CaptureSorter.ProtectedFilesIn(R.Combine(source, n))).ToList();
        var total = new ProtectedFiles();
        foreach (var files in contents)
        {
            total.Json += files.Json;
            total.Astrometry += files.Astrometry;
            foreach (var (ext, count) in files.Other) total.Other[ext] = total.Other.GetValueOrDefault(ext) + count;
        }
        var fileCount = total.Json + total.Astrometry + total.Other.Values.Sum();
        const int shown = 10;
        var lines = names.Zip(contents).Take(shown).Select(p => $"• {p.First}: {Describe(p.Second)}");

        var kept = " Kept the processed capture folders." + keptNote;
        if (!Prompts.Confirm($"Processing is done. Delete the {names.Count} capture folder(s) and their data?",
                "The Capture Folder was scanned again. Everything sorted is in Targets {year}. Left in these folders:\n"
                + string.Join("\n", lines)
                + (names.Count > shown ? $"\n…and {names.Count - shown} more" : "")
                + $"\n\nIn all: {Describe(total)}.{keptNote}\n\nYes deletes these folders and everything in them. No keeps them.")
            || !Prompts.Confirm("Are you sure?",
                $"This moves {names.Count} folder(s) and {fileCount} file(s) ({Describe(total)}) from the Capture Folder to the Recycle Bin, "
                + "or deletes them outright on a drive without one. Your sorted images in Targets are not touched."))
        {
            Status += kept;
            return;
        }
        var paths = names.Select(n => R.Combine(source, n)).ToList();
        var (permanent, keptLong) = await AskAboutLongPathsAsync(paths);
        var (result, _) = await RunTransferAsync("Deleting capture folders",
            Permitting(permanent, monitor => CaptureSorter.TrashFolders(paths, monitor)), deleting: true);
        var failed = result.Skipped.Count - keptLong;
        var message = Status + $" Deleted {result.Deleted} processed capture folder(s)."
                      + (failed <= 0 ? "" : $" {failed} couldn't be deleted.") + LongPathsKept(keptLong) + keptNote;
        await RefreshAsync(() => Status = message);
    }

    private static string Describe(ProtectedFiles files)
    {
        var parts = new[] { files.Json > 0 ? $"{files.Json} JSON" : null, files.Astrometry > 0 ? $"{files.Astrometry} plate-solve" : null }
            .OfType<string>()
            .Concat(files.Other.OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => $"{p.Value} {p.Key.ToUpperInvariant()}"))
            .ToList();
        return parts.Count == 0 ? "empty folders only" : string.Join(", ", parts);
    }

    // MARK: Identical copies in Targets

    /// <summary>
    /// Finds byte-identical numbered copies ("IMG_0001 2.jpg"…) in each Targets {year}\{object} folder, lists them and
    /// asks Yes/No twice before moving the extras to the Recycle Bin. One copy of each file is always kept.
    /// </summary>
    public async Task RemoveIdenticalCopiesInTargetsAsync()
    {
        var targets = TargetsRoot;
        var (sets, stopped) = await RunTransferAsync("Finding identical copies in Targets",
            monitor => CaptureSorter.FindRedundantCopies(targets, monitor),
            explanation: ("Finding identical copies in Targets",
                "Each Targets {year}\\{object} folder is searched for files whose names differ only by a number "
                + "and whose bytes are the same. Nothing is deleted now; you're asked twice first."));
        if (stopped)
        {
            Status = "Stopped looking for identical copies in Targets. Nothing was deleted.";
            return;
        }
        if (sets.Count == 0)
        {
            Status = $"No identical copies found in {Path.Combine(targets, "Targets {year}")}.";
            Prompts.Inform("No identical copies in Targets", "Every image in each Targets {year}\\{object} folder is different from the others.");
            return;
        }
        var extras = sets.SelectMany(s => s.Extras).ToList();
        var size = Core.Common.ByteSize.Format(extras.Sum(e => Math.Max(FileOps.Size(e), 0)));
        var byObject = sets.GroupBy(s => string.Join("\\", R.Split(R.RelativePath(s.Keep, targets)).Take(2)))
            .Select(g => (Key: g.Key, Count: g.Sum(s => s.Extras.Count)))
            .OrderByDescending(p => p.Count).ThenBy(p => p.Key, StringComparer.Ordinal).ToList();
        const int shown = 10;
        var lines = byObject.Take(shown).Select(p => $"• {p.Key}: {p.Count} extra");
        var example = sets[0];
        var kept = $"Kept all {extras.Count} identical copies in Targets.";
        if (!Prompts.Confirm($"Delete {extras.Count} identical copies in Targets?",
                "Earlier sorts gave clashing names a number, so some images were saved more than once. These files are byte-for-byte "
                + "the same as another file in the same object folder; one copy of each is kept, the un-numbered one when there is one.\n\n"
                + string.Join("\n", lines)
                + (byObject.Count > shown ? $"\n…and {byObject.Count - shown} more folders" : "")
                + $"\n\nFor example {Path.GetFileName(example.Keep)} is kept and {string.Join(", ", example.Extras.Select(Path.GetFileName))} go.\n\n"
                + $"In all: {extras.Count} extra copies of {sets.Count} file(s), {size}.\n\nYes deletes the extra copies. No keeps everything.")
            || !Prompts.Confirm("Are you sure?",
                $"This moves {extras.Count} file(s) ({size}) from the Target Folder to the Recycle Bin, or deletes them outright on a drive "
                + "without one. Each is read again and compared byte for byte with the copy that's kept just before it goes. The kept copies are not touched."))
        {
            Status = kept;
            return;
        }
        var (permanent, keptLong) = await AskAboutLongPathsAsync(extras);
        var (result, _) = await RunTransferAsync("Deleting identical copies in Targets",
            Permitting(permanent, monitor => CaptureSorter.RemoveRedundantCopies(sets, monitor)),
            deleting: true,
            explanation: ("Deleting identical copies in Targets",
                "You said Yes twice. One copy of each image stays in Targets; the extra copies go to the Recycle Bin."));
        var changed = result.Skipped.Count - keptLong;
        var message = $"Deleted {result.Deleted} identical copies from Targets ({Core.Common.ByteSize.Format(result.Bytes)})."
                      + (changed <= 0 ? "" : $" {changed} kept because they changed, or deleting was stopped.")
                      + LongPathsKept(keptLong);
        await RefreshAsync(() => Status = message);
    }
}
