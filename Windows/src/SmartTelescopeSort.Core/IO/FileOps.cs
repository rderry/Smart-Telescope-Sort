using System.Runtime.InteropServices;

namespace SmartTelescopeSort.Core.IO;

public enum WalkAction
{
    Continue,
    SkipDescendants,
    Stop,
}

/// <summary>An item kept because the Recycle Bin can't take its long path and the user didn't agree to delete it permanently.</summary>
public sealed class LongPathKeptException(string path)
    : IOException($"{path} was kept: its path is too long for the Recycle Bin, and it was not agreed to delete it permanently.")
{
    public string Path { get; } = path;
}

/// <summary>Disk work shared by the sorter: walking folders, copying, comparing byte for byte, deleting, free space.</summary>
public static class FileOps
{
    /// <summary>
    /// Moves a file or folder to the Recycle Bin; returns false when it couldn't (no Recycle Bin on that drive, or not on
    /// Windows). The app sets this to the shell's Recycle Bin. Callers then delete outright, as the Mac app does on
    /// drives without a Trash.
    /// </summary>
    public static Func<string, bool> Recycle { get; set; } = _ => false;

    /// <summary>True for names the Mac's skipsHiddenFiles leaves out (".name") and, on Windows, Hidden or System items.</summary>
    public static bool IsHidden(FileSystemInfo info)
    {
        if (info.Name.StartsWith('.')) return true;
        try
        {
            return OperatingSystem.IsWindows() && (info.Attributes & (FileAttributes.Hidden | FileAttributes.System)) != 0;
        }
        catch (IOException)
        {
            return false;
        }
    }

    /// <summary>
    /// Depth-first walk below `root` (not including it), visiting each folder before what it holds, skipping hidden items and
    /// never following links or junctions. `visit` decides whether to go into each folder.
    /// </summary>
    public static void Walk(string root, Func<FileSystemInfo, WalkAction> visit)
    {
        var stack = new Stack<IEnumerator<FileSystemInfo>>();
        var start = Children(root);
        if (start is null) return;
        stack.Push(start);
        while (stack.Count > 0)
        {
            var entries = stack.Peek();
            if (!entries.MoveNext())
            {
                entries.Dispose();
                stack.Pop();
                continue;
            }
            var info = entries.Current;
            if (IsHidden(info)) continue;
            var action = visit(info);
            if (action == WalkAction.Stop)
            {
                foreach (var e in stack) e.Dispose();
                return;
            }
            if (action == WalkAction.Continue && info is DirectoryInfo dir && !IsLink(dir) && Children(dir.FullName) is { } kids)
                stack.Push(kids);
        }
    }

    private static IEnumerator<FileSystemInfo>? Children(string folder)
    {
        try
        {
            var dir = new DirectoryInfo(folder);
            if (!dir.Exists) return null;
            // Materialized so a folder that can't be read is skipped rather than ending the walk.
            return dir.EnumerateFileSystemInfos("*", new EnumerationOptions
            {
                IgnoreInaccessible = true,
                AttributesToSkip = 0,
                RecurseSubdirectories = false,
                ReturnSpecialDirectories = false,
            }).ToList().GetEnumerator();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            return null;
        }
    }

    public static bool IsLink(FileSystemInfo info)
    {
        try
        {
            return (info.Attributes & FileAttributes.ReparsePoint) != 0 || info.LinkTarget is not null;
        }
        catch (IOException)
        {
            return false;
        }
    }

    public static bool IsDirectory(string path) => Directory.Exists(path);

    public static bool Exists(string path) => Path.Exists(path);

    /// <summary>The visible folders directly inside `folder`.</summary>
    public static List<string> Subfolders(string folder)
    {
        var found = new List<string>();
        try
        {
            foreach (var dir in new DirectoryInfo(folder).EnumerateDirectories())
                if (!IsHidden(dir)) found.Add(dir.FullName);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
        return found;
    }

    public static long Size(string path)
    {
        try
        {
            var info = new FileInfo(path);
            return info.Exists ? info.Length : -1;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return -1;
        }
    }

    /// <summary>Local modification time; DateTime.MinValue when it can't be read (the Mac's distantPast).</summary>
    public static DateTime Modified(string path)
    {
        try
        {
            if (File.Exists(path)) return File.GetLastWriteTime(path);
            if (Directory.Exists(path)) return Directory.GetLastWriteTime(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
        return DateTime.MinValue;
    }

    /// <summary>Copies a file without ever replacing one, keeping its modification time. Throws when `destination` exists.</summary>
    public static void CopyFile(string source, string destination)
    {
        File.Copy(source, destination, overwrite: false);
        try
        {
            File.SetLastWriteTimeUtc(destination, File.GetLastWriteTimeUtc(source));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }

    /// <summary>Copies a folder and everything in it, hidden files included, to `destination`, which must not exist.</summary>
    public static void CopyDirectory(string source, string destination)
    {
        if (Path.Exists(destination)) throw new IOException($"{destination} already exists.");
        Directory.CreateDirectory(destination);
        foreach (var info in new DirectoryInfo(source).EnumerateFileSystemInfos())
        {
            var target = Path.Combine(destination, info.Name);
            if (info is DirectoryInfo dir)
            {
                if (IsLink(dir)) continue;
                CopyDirectory(dir.FullName, target);
            }
            else
            {
                CopyFile(info.FullName, target);
            }
        }
        try
        {
            Directory.SetLastWriteTimeUtc(destination, Directory.GetLastWriteTimeUtc(source));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }

    /// <summary>
    /// Same bytes, or for folders the same names holding the same bytes all the way down (the Mac's contentsEqual).
    /// </summary>
    public static bool ContentsEqual(string a, string b)
    {
        try
        {
            if (File.Exists(a) && File.Exists(b)) return SameBytes(a, b);
            if (!Directory.Exists(a) || !Directory.Exists(b)) return false;
            var left = new DirectoryInfo(a).EnumerateFileSystemInfos().ToDictionary(i => i.Name, StringComparer.Ordinal);
            var right = new DirectoryInfo(b).EnumerateFileSystemInfos().ToDictionary(i => i.Name, StringComparer.Ordinal);
            if (left.Count != right.Count) return false;
            foreach (var (name, info) in left)
            {
                if (!right.TryGetValue(name, out var other)) return false;
                if (info is DirectoryInfo != other is DirectoryInfo) return false;
                if (!ContentsEqual(info.FullName, other.FullName)) return false;
            }
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private static bool SameBytes(string a, string b)
    {
        using var left = new FileStream(a, FileMode.Open, FileAccess.Read, FileShare.Read, 1, FileOptions.SequentialScan);
        using var right = new FileStream(b, FileMode.Open, FileAccess.Read, FileShare.Read, 1, FileOptions.SequentialScan);
        if (left.Length != right.Length) return false;
        var x = new byte[1 << 20];
        var y = new byte[1 << 20];
        while (true)
        {
            var n = left.ReadAtLeast(x, x.Length, throwOnEndOfStream: false);
            var m = right.ReadAtLeast(y, n, throwOnEndOfStream: false);
            if (n != m) return false;
            if (n == 0) return true;
            if (!x.AsSpan(0, n).SequenceEqual(y.AsSpan(0, m))) return false;
        }
    }

    /// <summary>
    /// Sends a file or folder to the Recycle Bin, or deletes it outright where there is none (the Mac's trashItem, then
    /// removeItem). Read-only files are deleted too, as on the Mac. Throws when it can't be removed, and throws
    /// <see cref="LongPathKeptException"/> for an item the Recycle Bin can't take because of a long path unless the user
    /// agreed, inside <see cref="AllowPermanentDelete"/>, to delete it permanently.
    /// </summary>
    public static void TrashOrDelete(string path)
    {
        if (TooLongForRecycleBin(path).Count > 0 && PermanentDeletes.Value?.Contains(FullPath(path)) != true)
            throw new LongPathKeptException(path);
        if (Recycle(path) && !Path.Exists(path)) return;
        Delete(path);
    }

    /// <summary>The Recycle Bin goes through shell paths, which stop at MAX_PATH: 260 characters with the terminator.</summary>
    public const int RecycleBinPathLimit = 260;

    private static readonly AsyncLocal<HashSet<string>?> PermanentDeletes = new();

    private static StringComparer PathComparer => OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;

    private static string FullPath(string path) => Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));

    private static bool IsTooLong(string fullPath) =>
        fullPath.StartsWith(@"\\?\", StringComparison.Ordinal) || fullPath.Length >= RecycleBinPathLimit;

    /// <summary>
    /// What at `path` the Recycle Bin can't take because its full path is 260 characters or longer, so deleting it would
    /// delete it permanently: `path` itself, or for a folder the outermost such items inside it. Empty when it can go.
    /// </summary>
    public static List<string> TooLongForRecycleBin(string path)
    {
        var found = new List<string>();
        string full;
        try
        {
            full = FullPath(path);
        }
        catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return found;
        }
        if (IsTooLong(full))
        {
            if (Path.Exists(full)) found.Add(full);
            return found;
        }
        if (!Directory.Exists(full)) return found;
        var pending = new Stack<string>();
        pending.Push(full);
        while (pending.Count > 0)
        {
            IEnumerable<FileSystemInfo> entries;
            try
            {
                entries = new DirectoryInfo(pending.Pop()).EnumerateFileSystemInfos("*", new EnumerationOptions
                {
                    IgnoreInaccessible = true,
                    AttributesToSkip = 0,
                }).ToList();
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                continue;
            }
            foreach (var entry in entries)
            {
                if (IsTooLong(entry.FullName)) found.Add(entry.FullName);
                else if (entry is DirectoryInfo dir && !IsLink(dir)) pending.Push(dir.FullName);
            }
        }
        found.Sort(StringComparer.Ordinal);
        return found;
    }

    /// <summary>
    /// Lets <see cref="TrashOrDelete"/> delete `paths` permanently when the Recycle Bin can't take them because of a long
    /// path, until the returned scope is disposed. Applies to the current thread and the work it awaits.
    /// </summary>
    public static IDisposable AllowPermanentDelete(IEnumerable<string> paths)
    {
        var previous = PermanentDeletes.Value;
        var allowed = new HashSet<string>(previous ?? Enumerable.Empty<string>(), PathComparer);
        foreach (var path in paths) allowed.Add(FullPath(path));
        PermanentDeletes.Value = allowed;
        return new PermanentDeleteScope(previous);
    }

    private sealed class PermanentDeleteScope(HashSet<string>? previous) : IDisposable
    {
        public void Dispose() => PermanentDeletes.Value = previous;
    }

    /// <summary>Deletes outright (the Mac's removeItem), clearing read-only attributes first.</summary>
    public static void Delete(string path)
    {
        if (Directory.Exists(path))
        {
            foreach (var file in new DirectoryInfo(path).EnumerateFiles("*", SearchOption.AllDirectories))
                if (file.IsReadOnly) file.IsReadOnly = false;
            Directory.Delete(path, recursive: true);
        }
        else if (File.Exists(path))
        {
            var info = new FileInfo(path);
            if (info.IsReadOnly) info.IsReadOnly = false;
            info.Delete();
        }
        else
        {
            throw new FileNotFoundException("Nothing to delete.", path);
        }
    }

    /// <summary>Bytes free for this user on the drive holding `path`, or null when it can't be told.</summary>
    public static long? AvailableBytes(string path)
    {
        try
        {
            if (OperatingSystem.IsWindows())
            {
                var folder = path;
                while (!Directory.Exists(folder) && Path.GetDirectoryName(folder) is { } parent) folder = parent;
                if (!folder.EndsWith('\\')) folder += "\\";
                return GetDiskFreeSpaceEx(folder, out var available, out _, out _) ? (long)available : null;
            }
            var full = Path.GetFullPath(path);
            var drive = DriveInfo.GetDrives()
                .Where(d => d.IsReady && full.StartsWith(d.Name, StringComparison.Ordinal))
                .MaxBy(d => d.Name.Length);
            return drive?.AvailableFreeSpace;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return null;
        }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetDiskFreeSpaceEx(string directory, out ulong available, out ulong total, out ulong free);
}
