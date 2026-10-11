using System.Formats.Tar;
using System.Globalization;
using System.IO.Compression;
using SmartTelescopeSort.Core.IO;

namespace SmartTelescopeSort.Core.Sorting;

public static partial class CaptureSorter
{
    public static List<SetAsideFolder> PlateSolveFolders(string root) => SetAsideFolders(root, IsPlateSolveFolder);

    /// <summary>The outermost calibration folders under `root` that hold images, outside Targets {year}.</summary>
    public static List<SetAsideFolder> CalibrationFolders(string root) => SetAsideFolders(root, IsCalibrationFolder);

    /// <summary>Plate-solve and calibration folders in one walk of `root`, for the scan.</summary>
    public static (List<SetAsideFolder> PlateSolves, List<SetAsideFolder> Calibration) SetAsideFolders(string root, ScanMonitor? monitor)
    {
        var plateSolves = new List<SetAsideFolder>();
        var calibration = new List<SetAsideFolder>();
        var searched = 0;
        monitor?.Report(5, "Finding plate solves and calibration folders", force: true);
        var found = SetAsideFolders(root, n => IsCalibrationFolder(n) || IsPlateSolveFolder(n), () =>
        {
            searched++;
            monitor?.Report(5, "Finding plate solves and calibration folders", searched);
            return monitor?.IsCancelled != true;
        });
        foreach (var folder in found)
        {
            if (IsCalibrationFolder(R.LastComponent(folder.Path))) calibration.Add(folder);
            else plateSolves.Add(folder);
        }
        return (plateSolves, calibration);
    }

    /// <summary>`onFolder` is called for each folder walked; returning false stops the walk.</summary>
    private static List<SetAsideFolder> SetAsideFolders(string root, Func<string, bool> matches, Func<bool>? onFolder = null)
    {
        var found = new List<SetAsideFolder>();
        FileOps.Walk(root, info =>
        {
            if (info is not DirectoryInfo) return WalkAction.Continue;
            if (onFolder?.Invoke() == false) return WalkAction.Stop;
            var name = info.Name;
            if (IsTargetsFolder(name)) return WalkAction.SkipDescendants;
            if (!matches(name)) return WalkAction.Continue;
            var files = ImageFiles(info.FullName, CalibrationExtensions);
            if (files.Count > 0) found.Add(new SetAsideFolder(RelativePath(info.FullName, root), CountByExtension(files)));
            return WalkAction.SkipDescendants;
        });
        found.Sort((a, b) => string.CompareOrdinal(a.Path, b.Path));
        return found;
    }

    /// <summary>
    /// Copies set-aside folders into `destination`, each keeping its path from the Capture Folder so folders with the
    /// same name don't collide. The originals stay until the user agrees to delete them.
    /// </summary>
    public static CopyResult CopySetAsideFolders(IReadOnlyList<string> paths, string sourceRoot, string destination, TransferMonitor? monitor = null)
    {
        var result = new CopyResult();
        var folders = Outermost(paths);
        for (var index = 0; index < folders.Count; index++)
        {
            if (monitor?.IsCancelled == true) break;
            var path = folders[index];
            monitor?.Report(new TransferProgress("Copying folders", index, folders.Count, path));
            if (CopyFolder(path, sourceRoot, R.Combine(destination, path)) is { } item) result.Copied.Add(item);
            else result.Failed.Add(path);
        }
        return result;
    }

    /// <summary>
    /// Copies one folder under the Capture Folder to `target`, adding a number when that path is taken, and checks the
    /// copy matches the original file for file. A copy that doesn't match is removed. Refuses to copy a folder into itself.
    /// </summary>
    private static CopiedItem? CopyFolder(string path, string sourceRoot, string target)
    {
        if (CaptureFolderPath(path, sourceRoot) is not { } folder || !FileOps.Exists(folder) || R.IsSameOrInside(target, folder)) return null;
        if (FileOps.Exists(target)) target = UnusedPath(R.Parent(target), R.LastComponent(target), null);
        try
        {
            Directory.CreateDirectory(R.Parent(target));
            FileOps.CopyDirectory(folder, target);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            TryDelete(target);
            return null;
        }
        if (!FileOps.ContentsEqual(folder, target))
        {
            TryDelete(target);
            return null;
        }
        return new CopiedItem(folder, target, true);
    }

    public static List<PlateSolveMove> PlateSolveMoves(IReadOnlyList<SetAsideFolder> folders, string sourceRoot)
    {
        var rootPath = Norm(sourceRoot);
        return folders.Select(folder =>
        {
            var url = Norm(R.Combine(sourceRoot, folder.Path));
            string? obj = null;
            var below = new List<string> { R.LastComponent(url) };
            var cursor = R.Parent(url);
            while (R.IsSameOrInside(cursor, rootPath))
            {
                var name = R.LastComponent(cursor);
                var match = DatedObservationCapture().Match(name);
                if (!match.Success) match = Observation().Match(name);
                if (match.Success)
                {
                    obj = DsoName(match.Groups[1].Value);
                    break;
                }
                if (NamesTarget(ObjectName(name)))
                {
                    obj = DsoName(ObjectName(name));
                    break;
                }
                if (R.AreSame(cursor, rootPath)) break;
                below.Insert(0, name);
                cursor = R.Parent(cursor);
            }
            var files = ImageFiles(url, CalibrationExtensions);
            var date = NamedDate(url, sourceRoot) ?? NewestDate(files.Count == 0 ? new[] { url } : files);
            return new PlateSolveMove
            {
                Path = folder.Path,
                Object = obj,
                Year = date.Year,
                Session = date.Session,
                Subpath = obj is null ? R.LastComponent(url) : string.Join(R.Separator, below),
                Images = folder.Images.Values.Sum(),
            };
        }).ToList();
    }

    /// <summary>
    /// Copies named plate-solve folders in with their object's images: Targets {year}/{object}/Plate Solves/{session}/{subpath}
    /// under `targetsRoot`. {session} is dropped when the object was named after it. The originals stay until the user
    /// agrees to delete them.
    /// </summary>
    public static CopyResult CopyPlateSolves(IReadOnlyList<PlateSolveMove> moves, string sourceRoot, string targetsRoot, TransferMonitor? monitor = null)
    {
        var result = new CopyResult();
        for (var index = 0; index < moves.Count; index++)
        {
            if (monitor?.IsCancelled == true) break;
            var move = moves[index];
            monitor?.Report(new TransferProgress("Copying plate solves", index, moves.Count, move.Path));
            if (move.Object is not { } obj) continue;
            var target = Path.Combine(targetsRoot, $"Targets {move.Year}", WindowsNames.SafeSegment(obj), PlateSolvesFolderName);
            if (move.Session != obj) target = Path.Combine(target, move.Session);
            target = R.Combine(target, move.Subpath);
            if (CopyFolder(move.Path, sourceRoot, target) is { } item) result.Copied.Add(item);
            else result.Failed.Add(move.Path);
        }
        return result;
    }

    public static string DefaultBackupName =>
        "TelescopeDataSort-Backup-" + DateTime.Now.ToString("yyyy-MM-dd'T'HH-mm-ss", CultureInfo.InvariantCulture);

    /// <summary>A name the user typed, made safe for a file name (no slashes, colons or archive extension); blank gives the default.</summary>
    public static string BackupBaseName(string? requested)
    {
        var name = (requested ?? "").Trim();
        foreach (var c in name.Where(WindowsNames.IsInvalidChar).Distinct().ToList()) name = name.Replace(c, '-');
        foreach (var suffix in new[] { ".tar.gz", ".tgz", ".zip" })
            if (name.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) name = name[..^suffix.Length];
        name = WindowsNames.TrimDotsAndWhitespace(name);
        if (name.Length > 0 && WindowsNames.IsReserved(name)) name += "_";
        return name.Length == 0 ? DefaultBackupName : name[..Math.Min(name.Length, 200)];
    }

    /// <summary>`base` plus `ext` in `parent`, numbered " 2", " 3"… when that name is taken.</summary>
    public static string UnusedPath(string parent, string baseName, string? ext)
    {
        var suffix = ext is null ? "" : "." + ext;
        var candidate = Path.Combine(parent, baseName + suffix);
        var number = 2;
        while (FileOps.Exists(candidate))
        {
            candidate = Path.Combine(parent, $"{baseName} {number}{suffix}");
            number++;
        }
        return candidate;
    }

    /// <summary>A folder copy of the rows' capture folders in a new, named folder inside `destinationParent`.</summary>
    public static BackupSummary BackupCaptureFolders(IReadOnlyList<CaptureEntry> entries, string sourceRoot, string destinationParent, string? name = null)
    {
        var destination = UnusedPath(destinationParent, BackupBaseName(name), null);
        Directory.CreateDirectory(destination);
        var folders = 0;
        var files = 0;
        foreach (var path in BackupPaths(entries, sourceRoot))
        {
            if (CaptureFolderPath(path, sourceRoot) is not { } source || !FileOps.Exists(source)) continue;
            var isDir = Directory.Exists(source);
            var target = R.Combine(destination, path);
            if (FileOps.Exists(target)) FileOps.Delete(target);
            Directory.CreateDirectory(R.Parent(target));
            if (isDir)
            {
                FileOps.CopyDirectory(source, target);
                folders++;
                files += ImageFiles(target, KeepFolderExtensions).Count;
            }
            else
            {
                FileOps.CopyFile(source, target);
                files++;
            }
        }
        return new BackupSummary(folders, files, destination);
    }

    /// <summary>
    /// What a backup of these rows copies, relative to `sourceRoot`: each capture folder, or the image files
    /// themselves for rows found loose in the source folder. Paths inside another listed path are dropped.
    /// </summary>
    public static List<string> BackupPaths(IReadOnlyList<CaptureEntry> entries, string sourceRoot)
    {
        var paths = new List<string>();
        foreach (var entry in entries)
        {
            if (entry.CaptureFolder.Length == 0) paths.AddRange(entry.SourceFiles.Select(f => RelativePath(f, sourceRoot)));
            else paths.Add(entry.CaptureFolder);
        }
        return Outermost(paths);
    }

    public static List<string> Outermost(IEnumerable<string> paths)
    {
        var kept = new List<string>();
        foreach (var path in paths.Distinct().OrderBy(p => p, StringComparer.Ordinal))
        {
            if (path.Length == 0) continue;
            if (kept.Any(k => R.IsSameOrInside(path, k) && !string.Equals(R.Normalize(path), R.Normalize(k), R.Comparison))) continue;
            kept.Add(path);
        }
        return kept;
    }

    /// <summary>
    /// A capture path under `sourceRoot`; null for the source folder itself, Targets {year}, a path that climbs out with
    /// "..", or a rooted path (a drive letter, UNC share or leading slash would escape the Capture Folder).
    /// </summary>
    internal static string? CaptureFolderPath(string name, string sourceRoot) => CaptureFolderPath(name, sourceRoot, R);

    internal static string? CaptureFolderPath(string name, string sourceRoot, PathRules rules)
    {
        if (rules.IsRooted(name) || (rules.IsWindows && name.Contains(':'))) return null;
        var parts = rules.Split(name);
        if (parts.Length == 0 || parts.Any(p => p == "." || p == ".." || IsTargetsFolder(p))) return null;
        return rules.Combine(sourceRoot, name);
    }

    /// <summary>Deepest paths first, so a capture inside another capture is handled before its parent.</summary>
    private static List<string> DeepestFirst(IEnumerable<string> names) =>
        names.Distinct().OrderByDescending(n => R.Split(n).Length).ThenByDescending(n => n, StringComparer.Ordinal).ToList();

    /// <summary>
    /// Writes a zip or tarball (.tar.gz) holding the named capture folders with .NET's own archivers, fastest compression,
    /// nothing to install. Returns the archive, or null when there was nothing to back up. Cancel deletes the partial archive.
    /// </summary>
    public static string? ArchiveCaptureFolders(IReadOnlyList<string> names, string sourceRoot, string destinationParent, BackupFormat format,
                                                string? name = null, ArchiveJob? job = null, Action<ArchiveProgress>? progress = null)
    {
        var folders = Outermost(names).Where(n => CaptureFolderPath(n, sourceRoot) is { } p && FileOps.Exists(p)).ToList();
        if (folders.Count == 0) return null;
        var archive = UnusedPath(destinationParent, BackupBaseName(name), format.FileExtension());

        // Entry name (forward slashes) → full path; folders get an entry of their own, as tar writes them.
        var entries = new List<(string Entry, string Path, bool IsDir, long Size)>();
        foreach (var folder in folders)
        {
            var item = R.Combine(sourceRoot, folder);
            var entryRoot = string.Join('/', R.Split(folder));
            if (File.Exists(item))
            {
                entries.Add((entryRoot, item, false, FileOps.Size(item)));
                continue;
            }
            entries.Add((entryRoot + "/", item, true, 0));
            foreach (var info in new DirectoryInfo(item).EnumerateFileSystemInfos("*", SearchOption.AllDirectories))
            {
                if (info.Name.StartsWith("._", StringComparison.Ordinal) || info.Name == ".DS_Store") continue;
                var relative = entryRoot + "/" + string.Join('/', R.Split(R.RelativePath(info.FullName, item)));
                if (info is DirectoryInfo) entries.Add((relative + "/", info.FullName, true, 0));
                else entries.Add((relative, info.FullName, false, ((FileInfo)info).Length));
            }
        }
        var state = new ArchiveProgress
        {
            BytesTotal = entries.Sum(e => e.Size),
            FilesTotal = entries.Count(e => !e.IsDir),
            CurrentFile = "",
        };
        progress?.Invoke(state);

        try
        {
            using (var output = new FileStream(archive, FileMode.CreateNew, FileAccess.Write))
            {
                if (format == BackupFormat.Zip)
                {
                    using var zip = new ZipArchive(output, ZipArchiveMode.Create);
                    foreach (var entry in entries)
                    {
                        job?.CheckCancelled();
                        if (entry.IsDir)
                        {
                            zip.CreateEntry(entry.Entry);
                            continue;
                        }
                        state.CurrentFile = entry.Entry;
                        progress?.Invoke(state);
                        zip.CreateEntryFromFile(entry.Path, entry.Entry, CompressionLevel.Fastest);
                        state.BytesDone += entry.Size;
                        state.FilesDone++;
                    }
                }
                else
                {
                    using var gzip = new GZipStream(output, CompressionLevel.Fastest);
                    using var tar = new TarWriter(gzip, TarEntryFormat.Pax);
                    foreach (var entry in entries)
                    {
                        job?.CheckCancelled();
                        if (!entry.IsDir)
                        {
                            state.CurrentFile = entry.Entry;
                            progress?.Invoke(state);
                        }
                        tar.WriteEntry(entry.Path, entry.Entry.TrimEnd('/'));
                        if (entry.IsDir) continue;
                        state.BytesDone += entry.Size;
                        state.FilesDone++;
                    }
                }
            }
            progress?.Invoke(state);
            return archive;
        }
        catch (ArchiveJob.CancelledException)
        {
            TryDelete(archive);
            throw;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            TryDelete(archive);
            throw new IOException($"{format.Label()} backup failed: {e.Message}", e);
        }
    }
}
