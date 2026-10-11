using System.Collections.Concurrent;
using SmartTelescopeSort.Core.Common;
using SmartTelescopeSort.Core.IO;

namespace SmartTelescopeSort.Core.Sorting;

public static partial class CaptureSorter
{
    public const string PlateSolvesFolderName = "Plate Solves";

    private static readonly IReadOnlySet<string> CalibrationExtensions = new HashSet<string>(KeepFolderExtensions) { "xisf" };

    public static IReadOnlySet<string> CalibrationDisposable => CalibrationExtensions;

    /// <summary>Stops early when `monitor` is cancelled; the caller checks for that and drops the partial plan.</summary>
    public static (List<SortPlanItem> Plans, SortSummary Summary) Preview(IReadOnlyList<CaptureEntry> entries, ScanMonitor? monitor = null)
    {
        var plans = new List<SortPlanItem>();
        var summary = new SortSummary
        {
            CreateTargets = entries.Where(e => !e.TargetExists).Select(e => e.Year).Distinct().OrderBy(y => y, StringComparer.Ordinal).ToList(),
        };

        // Copies already anywhere in Targets {year}/{object}, and files this sort sends there, by DuplicateKey.
        var inTargets = new Dictionary<string, Dictionary<string, List<string>>>(R.Comparer);
        var planned = new Dictionary<string, Dictionary<string, List<string>>>(R.Comparer);
        var taken = new HashSet<string>(StringComparer.Ordinal);
        Dictionary<string, List<string>> Copies(string objectFolder)
        {
            var key = Norm(objectFolder);
            if (inTargets.TryGetValue(key, out var index)) return index;
            index = ImageFiles(objectFolder, KeepFolderExtensions).GroupBy(DuplicateKey).ToDictionary(g => g.Key, g => g.ToList());
            inTargets[key] = index;
            return index;
        }

        var work = entries.SelectMany(e => e.SourceFiles.Select(s => (Entry: e, Source: s)))
            .OrderBy(w => w.Entry.Session, StringComparer.Ordinal).ThenBy(w => w.Source, StringComparer.Ordinal).ToList();
        var bySource = new Dictionary<string, SortPlanItem>(StringComparer.Ordinal);
        monitor?.Report(4, "Comparing with Targets", total: work.Count, force: true);
        for (var index = 0; index < work.Count; index++)
        {
            if (monitor?.IsCancelled == true) break;
            monitor?.Report(4, "Comparing with Targets", index + 1, work.Count);
            var (entry, source) = work[index];
            var objectKey = Norm(entry.ObjectFolder);
            var name = DuplicateKey(source);
            SortAction action;
            string destination;
            if (Copies(entry.ObjectFolder).GetValueOrDefault(name)?.FirstOrDefault(c => Identical(source, c)) is { } copy)
            {
                action = SortAction.Duplicate;
                destination = copy;
            }
            else if (planned.GetValueOrDefault(objectKey)?.GetValueOrDefault(name)?.FirstOrDefault(p => Identical(source, p)) is { } earlier
                     && bySource.TryGetValue(earlier, out var item))
            {
                action = SortAction.Duplicate;
                destination = item.Destination;
            }
            else
            {
                action = SortAction.Move;
                destination = FreeDestination(source, entry.TargetDirectory, taken);
                taken.Add(Norm(destination).ToLowerInvariant());
                if (!planned.TryGetValue(objectKey, out var names)) planned[objectKey] = names = new Dictionary<string, List<string>>(StringComparer.Ordinal);
                if (!names.TryGetValue(name, out var list)) names[name] = list = new List<string>();
                list.Add(source);
            }
            if (action == SortAction.Move) summary.Move++;
            else summary.Duplicate++;
            var plan = new SortPlanItem
            {
                Source = source,
                Destination = destination,
                Action = action,
                EntryId = entry.Id,
                CaptureFolder = entry.CaptureFolder,
                Object = entry.Object,
                TargetFolder = $"Targets {entry.Year}{R.Separator}{entry.Object}",
                Date = FileOps.Modified(source),
            };
            plans.Add(plan);
            bySource.TryAdd(source, plan);
        }
        plans.Sort((a, b) => CompareTuple(
            (a.CaptureFolder, b.CaptureFolder), (a.Object, b.Object), (Path.GetFileName(a.Source), Path.GetFileName(b.Source))));
        return (plans, summary);
    }

    /// <summary>
    /// A file's name for finding copies: lowercased, without the " 2", " 3"… a clashing name was given, so
    /// "IMG_0001 2.jpg" is checked against "IMG_0001.jpg". Candidates are still compared byte for byte.
    /// </summary>
    public static string DuplicateKey(string path)
    {
        var baseName = NumberSuffix().Replace(BaseName(path), "");
        var ext = Extension(path);
        return (ext.Length == 0 ? baseName : baseName + "." + ext).ToLowerInvariant();
    }

    private static bool IsNumbered(string path) => NumberSuffix().IsMatch(BaseName(path));

    /// <summary>
    /// Byte-identical copies within each Targets {year}/{object} folder, Plate Solves left out: files whose names
    /// differ only by a " 2", " 3"… In each set the un-numbered, least nested file is kept.
    /// </summary>
    public static List<RedundantCopies> FindRedundantCopies(string targetsRoot, TransferMonitor? monitor = null)
    {
        int KeptFirst(string a, string b)
        {
            var c = (IsNumbered(a) ? 1 : 0).CompareTo(IsNumbered(b) ? 1 : 0);
            if (c != 0) return c;
            c = R.Depth(a).CompareTo(R.Depth(b));
            return c != 0 ? c : string.CompareOrdinal(a, b);
        }
        var objectFolders = FileOps.Subfolders(targetsRoot)
            .Where(f => TargetsYear().IsMatch(Path.GetFileName(f)))
            .SelectMany(FileOps.Subfolders)
            .OrderBy(f => f, StringComparer.Ordinal)
            .ToList();
        const string phase = "Finding identical copies in Targets";
        var found = new List<RedundantCopies>();
        for (var index = 0; index < objectFolders.Count; index++)
        {
            if (monitor?.IsCancelled == true) break;
            var folder = objectFolders[index];
            monitor?.Report(new TransferProgress(phase, index, objectFolders.Count, Path.GetFileName(folder)));
            var files = ImageFiles(folder, KeepFolderExtensions)
                .Where(f => !R.Split(R.RelativePath(f, folder)).SkipLast(1).Contains(PlateSolvesFolderName))
                .ToList();
            foreach (var named in files.GroupBy(f => $"{DuplicateKey(f)}|{FileOps.Size(f)}").Where(g => g.Count() > 1))
            {
                var sets = new List<List<string>>();
                foreach (var file in named.OrderBy(f => f, Comparer<string>.Create(KeptFirst)))
                {
                    var set = sets.FirstOrDefault(s => Identical(s[0], file));
                    if (set is not null) set.Add(file);
                    else sets.Add(new List<string> { file });
                }
                found.AddRange(sets.Where(s => s.Count > 1).Select(s => new RedundantCopies(s[0], s.Skip(1).ToList())));
            }
        }
        monitor?.Report(new TransferProgress(phase, objectFolders.Count, objectFolders.Count), force: true);
        return found.OrderBy(s => s.Keep, StringComparer.Ordinal).ToList();
    }

    /// <summary>
    /// Moves each extra copy to the Recycle Bin (deleting it outright on drives without one) after re-reading it byte
    /// for byte against the copy that's kept. Returns how many went, the bytes freed and the paths skipped.
    /// </summary>
    public static (int Deleted, long Bytes, List<string> Skipped) RemoveRedundantCopies(IReadOnlyList<RedundantCopies> sets, TransferMonitor? monitor = null)
    {
        var extras = sets.SelectMany(s => s.Extras.Select(e => (Keep: s.Keep, Extra: e))).ToList();
        const string phase = "Deleting identical copies in Targets";
        var deleted = 0;
        long bytes = 0;
        var skipped = new List<string>();
        for (var index = 0; index < extras.Count; index++)
        {
            if (monitor?.IsCancelled == true)
            {
                skipped.AddRange(extras.Skip(index).Select(e => e.Extra));
                break;
            }
            var (keep, extra) = extras[index];
            monitor?.Report(new TransferProgress(phase, index, extras.Count, Path.GetFileName(extra), Deleting: true));
            var fileSize = FileOps.Size(extra);
            if (!File.Exists(keep) || !Identical(extra, keep, cached: false))
            {
                skipped.Add(extra);
                continue;
            }
            try
            {
                FileOps.TrashOrDelete(extra);
                deleted++;
                bytes += fileSize;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                skipped.Add(extra);
            }
        }
        monitor?.Report(new TransferProgress(phase, extras.Count, extras.Count, Deleting: true), force: true);
        return (deleted, bytes, skipped);
    }

    /// <summary>`folder`/`source`'s name, or "name 2.ext", "name 3.ext"… when a different file already holds it.</summary>
    private static string FreeDestination(string source, string folder, IReadOnlySet<string> taken)
    {
        var baseName = BaseName(source);
        var ext = Extension(source);
        var candidate = Path.Combine(folder, Path.GetFileName(source));
        var number = 2;
        while (FileOps.Exists(candidate) || taken.Contains(Norm(candidate).ToLowerInvariant()))
        {
            candidate = Path.Combine(folder, ext.Length == 0 ? $"{baseName} {number}" : $"{baseName} {number}.{ext}");
            number++;
        }
        return candidate;
    }

    private static readonly ConcurrentDictionary<string, bool> IdenticalCache = new(StringComparer.Ordinal);

    /// <summary>
    /// Same bytes. FITS frames of one camera are all the same size, so size alone proves nothing. Answers are
    /// remembered while both files keep their size and date, so a refresh doesn't re-read them; `cached: false`
    /// always reads, for the check just before a file is deleted.
    /// </summary>
    private static bool Identical(string a, string b, bool cached = true)
    {
        if (R.AreSame(a, b)) return false;
        var size = FileOps.Size(a);
        if (size < 0 || size != FileOps.Size(b)) return false;
        var key = $"{a}|{b}|{size}|{FileOps.Modified(a).Ticks}|{FileOps.Modified(b).Ticks}";
        if (cached && IdenticalCache.TryGetValue(key, out var known)) return known;
        var same = FileOps.ContentsEqual(a, b);
        IdenticalCache[key] = same;
        return same;
    }

    /// <summary>
    /// Deletes source files that are already in Targets (to the Recycle Bin when the drive has one), then removes capture
    /// folders left with no TIFF/FITS. Each file is re-compared byte for byte with its Targets copy first.
    /// </summary>
    public static DuplicateCleanup DeleteDuplicates(IReadOnlyList<SortPlanItem> items, string sourceRoot, DeletePermissions allowing = default)
    {
        var result = new DuplicateCleanup();
        foreach (var item in items.Where(i => i.IsDuplicate))
        {
            if (!File.Exists(item.Source) || !File.Exists(item.Destination) || !Identical(item.Source, item.Destination, cached: false))
            {
                result.Skipped++;
                continue;
            }
            try
            {
                FileOps.TrashOrDelete(item.Source);
                result.Deleted++;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                result.Skipped++;
            }
        }
        var cleanup = RemoveSpentCaptureFolders(
            items.Where(i => i.IsDuplicate).Select(i => i.CaptureFolder).Distinct().ToList(), Norm(sourceRoot), allowing);
        result.RemovedFolders = cleanup.Removed;
        result.Held = cleanup.Held;
        return result;
    }

    public static string CreateTargetsFolder(string year, string targetsRoot)
    {
        if (!FourDigits().IsMatch(year)) throw new ArgumentException("A target year must be four digits.");
        var target = Path.Combine(targetsRoot, $"Targets {year}");
        Directory.CreateDirectory(target);
        return target;
    }

    /// <summary>
    /// Copies every file the plan moves into Targets {year}/{object} and checks each copy byte for byte. Nothing is
    /// deleted: the originals stay until the user agrees, at the end of the sort, to delete them.
    /// </summary>
    public static CopyResult CopySort(IReadOnlyList<CaptureEntry> entries, string sourceRoot, string? targetsRoot = null, TransferMonitor? monitor = null)
    {
        targetsRoot ??= sourceRoot;
        var (plans, summary) = Preview(entries);
        var moves = plans.Where(p => p.Action == SortAction.Move).ToList();
        var result = new CopyResult();
        try
        {
            foreach (var year in summary.CreateTargets) CreateTargetsFolder(year, targetsRoot);
            CheckFreeSpace(moves.Select(m => m.Source).ToList(), targetsRoot);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            result.Error = e.Message;
            return result;
        }
        for (var index = 0; index < moves.Count; index++)
        {
            if (monitor?.IsCancelled == true) break;
            var item = moves[index];
            monitor?.Report(new TransferProgress("Copying images", index, moves.Count, Path.GetFileName(item.Source)));
            var folder = R.Parent(item.Destination);
            var destination = FileOps.Exists(item.Destination)
                ? FreeDestination(item.Destination, folder, new HashSet<string>())
                : item.Destination;
            try
            {
                Directory.CreateDirectory(folder);
                FileOps.CopyFile(item.Source, destination);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                // Only a partial copy this sort started is removed; a file that was already there is never touched.
                if (e is not IOException { HResult: var h } || !IsAlreadyExists(h)) TryDelete(destination);
                result.Failed.Add(Path.GetFileName(item.Source));
                continue;
            }
            if (Identical(item.Source, destination, cached: false))
            {
                result.Copied.Add(new CopiedItem(item.Source, destination, false));
            }
            else
            {
                TryDelete(destination);
                result.Failed.Add(Path.GetFileName(item.Source));
            }
        }
        monitor?.Report(new TransferProgress("Copying images", moves.Count, moves.Count), force: true);
        return result;
    }

    /// <summary>ERROR_FILE_EXISTS / ERROR_ALREADY_EXISTS on Windows, EEXIST elsewhere.</summary>
    private static bool IsAlreadyExists(int hresult) => (hresult & 0xFFFF) is 80 or 183 or 17;

    private static void TryDelete(string path)
    {
        try
        {
            if (FileOps.Exists(path)) FileOps.Delete(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }

    /// <summary>Throws when the Target Folder's drive hasn't room for `files` plus 100 MB.</summary>
    private static void CheckFreeSpace(IReadOnlyList<string> files, string targetsRoot)
    {
        if (files.Count == 0) return;
        if (FileOps.AvailableBytes(targetsRoot) is not { } available) return;
        var needed = files.Sum(f => Math.Max(FileOps.Size(f), 0));
        if (needed + 100_000_000 <= available) return;
        throw new IOException($"Not enough free space on the Target Folder's drive: copying needs {ByteSize.Format(needed)}, "
            + $"and {ByteSize.Format(available)} is free. Nothing was copied or deleted.");
    }

    /// <summary>Moves folders to the Recycle Bin, or deletes them outright on drives without one. Returns how many went and the paths skipped.</summary>
    public static (int Deleted, List<string> Skipped) TrashFolders(IReadOnlyList<string> folders, TransferMonitor? monitor = null)
    {
        var deleted = 0;
        var skipped = new List<string>();
        for (var index = 0; index < folders.Count; index++)
        {
            if (monitor?.IsCancelled == true)
            {
                skipped.AddRange(folders.Skip(index));
                break;
            }
            monitor?.Report(new TransferProgress("Deleting capture folders", index, folders.Count, Path.GetFileName(folders[index]), Deleting: true));
            try
            {
                FileOps.TrashOrDelete(folders[index]);
                deleted++;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                skipped.Add(folders[index]);
            }
        }
        monitor?.Report(new TransferProgress("Deleting capture folders", folders.Count, folders.Count, Deleting: true), force: true);
        return (deleted, skipped);
    }

    /// <summary>
    /// Moves originals to the Recycle Bin (deleting them outright on drives without one) once their copies are confirmed
    /// to still be in place. Returns how many were deleted and the paths skipped.
    /// </summary>
    public static (int Deleted, List<string> Skipped) DeleteOriginals(IReadOnlyList<CopiedItem> items, TransferMonitor? monitor = null)
    {
        var deleted = 0;
        var skipped = new List<string>();
        for (var index = 0; index < items.Count; index++)
        {
            if (monitor?.IsCancelled == true)
            {
                skipped.AddRange(items.Skip(index).Select(i => i.Original));
                break;
            }
            var item = items[index];
            monitor?.Report(new TransferProgress("Deleting originals", index, items.Count, Path.GetFileName(item.Original), Deleting: true));
            if (!FileOps.Exists(item.Original) || !FileOps.Exists(item.Copy) || (!item.IsFolder && FileOps.Size(item.Original) != FileOps.Size(item.Copy)))
            {
                skipped.Add(item.Original);
                continue;
            }
            try
            {
                FileOps.TrashOrDelete(item.Original);
                deleted++;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                skipped.Add(item.Original);
            }
        }
        monitor?.Report(new TransferProgress("Deleting originals", items.Count, items.Count, Deleting: true), force: true);
        return (deleted, skipped);
    }

    /// <summary>
    /// Sends capture folders to the Recycle Bin (removing them if the drive has none) with the images inside them.
    /// `disposable` lists the extensions the user agreed to delete; JSON and astrometry files need `allowing`, and a
    /// folder holding any other file is kept.
    /// </summary>
    public static FolderCleanup TrashCaptureFolders(IReadOnlyList<string> names, string sourceRoot, IReadOnlySet<string>? disposable = null,
                                                    DeletePermissions allowing = default) =>
        CleanUp(names, sourceRoot, disposable ?? KeepFolderExtensions, allowing, trash: true);

    private static FolderCleanup CleanUp(IReadOnlyList<string> names, string sourceRoot, IReadOnlySet<string> disposable, DeletePermissions allowing, bool trash)
    {
        var result = new FolderCleanup();
        foreach (var name in DeepestFirst(names))
        {
            if (CaptureFolderPath(name, sourceRoot) is not { } folder || !Directory.Exists(folder)) continue;
            var left = ProtectedFilesIn(folder, disposable);
            if (left.Other.Count > 0)
            {
                result.Kept[name] = left.Other;
                continue;
            }
            if (left.BlockedBy(allowing))
            {
                result.Held[name] = left;
                continue;
            }
            try
            {
                if (trash) FileOps.TrashOrDelete(folder);
                else FileOps.Delete(folder);
                result.Removed++;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
            }
        }
        return result;
    }

    /// <summary>
    /// Counts the files under `folder` that deleting it would take, apart from those with a `disposable` extension.
    /// Hidden files such as Thumbs.db or desktop.ini don't count.
    /// </summary>
    public static ProtectedFiles ProtectedFilesIn(string folder, IReadOnlySet<string>? disposable = null)
    {
        disposable ??= new HashSet<string>();
        var found = new ProtectedFiles();
        var baseFolder = Norm(folder);
        var inPlateSolve = R.LastComponent(baseFolder).ToLowerInvariant().Contains("astrometry");
        FileOps.Walk(baseFolder, info =>
        {
            if (info is not FileInfo) return WalkAction.Continue;
            var name = info.Name.ToLowerInvariant();
            var ext = Extension(info.Name).ToLowerInvariant();
            var folders = R.RelativePath(R.Parent(info.FullName), baseFolder);
            if (R.AreSame(R.Parent(info.FullName), baseFolder)) folders = "";
            if (inPlateSolve || name.StartsWith("astrometry", StringComparison.Ordinal) || folders.ToLowerInvariant().Contains("astrometry"))
                found.Astrometry++;
            else if (ext == "json")
                found.Json++;
            else if (!disposable.Contains(ext))
            {
                var key = ext.Length == 0 ? "(no extension)" : ext;
                found.Other[key] = found.Other.GetValueOrDefault(key) + 1;
            }
            return WalkAction.Continue;
        });
        return found;
    }

    /// <summary>Image files still inside each capture folder that survived a sort, counted by lowercased extension.</summary>
    public static Dictionary<string, Dictionary<string, int>> LeftoverImages(IReadOnlyList<string> captureNames, string sourceRoot)
    {
        var kept = new Dictionary<string, Dictionary<string, int>>(StringComparer.Ordinal);
        foreach (var name in captureNames.Distinct())
        {
            if (CaptureFolderPath(name, sourceRoot) is not { } folder) continue;
            var files = ImageFiles(folder, KeepFolderExtensions);
            // Offering to delete this folder would take the plate solves or calibration frames the user chose to leave.
            if (files.Count == 0 || CalibrationFolders(folder).Count > 0 || PlateSolveFolders(folder).Count > 0) continue;
            kept[name] = CountByExtension(files);
        }
        return kept;
    }

    /// <summary>True while any TIFF, FITS, JPG or PNG is left under the folder, sorted type or not.</summary>
    public static bool HoldsImages(string folder) => ImageFiles(folder, KeepFolderExtensions).Count > 0;

    /// <summary>
    /// Removes capture folders a sort emptied. A folder holding any image or other file stays; one holding only JSON or
    /// astrometry files stays unless `allowing` permits them, and is listed in Held so the user can be asked.
    /// </summary>
    public static FolderCleanup RemoveSpentCaptureFolders(IReadOnlyList<string> captureNames, string sourceRoot, DeletePermissions allowing = default) =>
        CleanUp(captureNames, sourceRoot, new HashSet<string>(), allowing, trash: false);

    private static Dictionary<string, int> CountByExtension(IEnumerable<string> files)
    {
        var counts = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var file in files)
        {
            var ext = Extension(file).ToLowerInvariant();
            counts[ext] = counts.GetValueOrDefault(ext) + 1;
        }
        return counts;
    }
}
