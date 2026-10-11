using SmartTelescopeSort.Core.IO;

namespace SmartTelescopeSort.Core.Sorting;

/// <summary>One capture folder, object and session found by a scan: a row in the main window.</summary>
public sealed record CaptureEntry
{
    public string Id => $"{CaptureFolder}|{Object}|{Session}|{Year}-{Month}";

    /// <summary>Relative to the Capture Folder ("" for files lying in the Capture Folder itself).</summary>
    public required string CaptureFolder { get; init; }

    public required string Year { get; init; }

    public required string Month { get; init; }

    public required string Object { get; init; }

    /// <summary>
    /// The night or observation these files came from (2025-10-10_07-49-28, or 2025-10-10 when no time is known).
    /// Every session numbers its frames from IMG_0001 again, so a name another night already used gets a number added.
    /// </summary>
    public required string Session { get; init; }

    public int ImageFolders { get; init; }

    public int Files { get; init; }

    public IReadOnlyList<string> Formats { get; init; } = Array.Empty<string>();

    /// <summary>Targets {year}.</summary>
    public required string YearFolder { get; init; }

    public bool TargetExists { get; init; }

    public IReadOnlyList<string> SourceFiles { get; init; } = Array.Empty<string>();

    /// <summary>No folder above these files names a target; Object is only the folder's name and the user is asked at sort time.</summary>
    public bool NeedsObjectName { get; init; }

    public string ObjectFolder => Path.Combine(YearFolder, WindowsNames.SafeSegment(Object));

    /// <summary>Targets {year}/{object}.</summary>
    public string TargetDirectory => ObjectFolder;

    /// <summary>The session's day, YYYY-MM-DD: the name offered when no folder names the object.</summary>
    public string SessionDate => Session.Length > 10 ? Session[..10] : Session;

    /// <summary>The same row sorted into Targets {year}/`name` instead.</summary>
    public CaptureEntry Named(string name) => this with { Object = name, NeedsObjectName = false };
}

public enum SortAction
{
    /// <summary>New to Targets. Nothing in Targets is ever overwritten; a different file holding the name gets " 2" added.</summary>
    Move,

    /// <summary>Byte-for-byte the same as Destination, already in Targets or moved there by this sort.</summary>
    Duplicate,
}

public sealed record SortPlanItem
{
    public string Id => Source;

    public required string Source { get; init; }

    public required string Destination { get; init; }

    public required SortAction Action { get; init; }

    public required string EntryId { get; init; }

    public required string CaptureFolder { get; init; }

    public required string Object { get; init; }

    public required string TargetFolder { get; init; }

    public DateTime Date { get; init; }

    public string ActionLabel => Action == SortAction.Move ? "New" : "Duplicate";

    /// <summary>Never moved, only deleted when the user says yes.</summary>
    public bool IsDuplicate => Action == SortAction.Duplicate;
}

public sealed class SortSummary
{
    public int Move { get; set; }

    public int Duplicate { get; set; }

    public List<string> CreateTargets { get; set; } = new();

    public int RemovedFolders { get; set; }

    public int Duplicates => Duplicate;
}

/// <summary>Image types the user can choose to sort.</summary>
public enum SortFileType
{
    Tiff,
    Jpeg,
    Fits,
}

public static class SortFileTypes
{
    public static readonly SortFileType[] All = { SortFileType.Tiff, SortFileType.Jpeg, SortFileType.Fits };
    public static readonly SortFileType[] Defaults = { SortFileType.Tiff, SortFileType.Fits };

    public static string RawValue(this SortFileType type) => type switch
    {
        SortFileType.Tiff => "tiff",
        SortFileType.Jpeg => "jpeg",
        _ => "fits",
    };

    public static SortFileType? FromRaw(string raw) => raw switch
    {
        "tiff" => SortFileType.Tiff,
        "jpeg" => SortFileType.Jpeg,
        "fits" => SortFileType.Fits,
        _ => null,
    };

    public static string Label(this SortFileType type) => type switch
    {
        SortFileType.Tiff => "TIFF",
        SortFileType.Jpeg => "JPG / JPEG",
        _ => "FITS / FIT",
    };

    public static IReadOnlySet<string> Extensions(this SortFileType type) => type switch
    {
        SortFileType.Tiff => new HashSet<string> { "tif", "tiff" },
        SortFileType.Jpeg => new HashSet<string> { "jpg", "jpeg" },
        _ => new HashSet<string> { "fit", "fits" },
    };

    public static HashSet<string> ExtensionsOf(IEnumerable<SortFileType> types)
    {
        var set = new HashSet<string>();
        foreach (var type in types) set.UnionWith(type.Extensions());
        return set;
    }
}

/// <summary>Archive formats for the backup made before a sort.</summary>
public enum BackupFormat
{
    Zip,
    Tarball,
}

public static class BackupFormats
{
    public static readonly BackupFormat[] All = { BackupFormat.Zip, BackupFormat.Tarball };

    public static string RawValue(this BackupFormat format) => format == BackupFormat.Zip ? "zip" : "tarball";

    public static BackupFormat? FromRaw(string? raw) => raw switch
    {
        "zip" => BackupFormat.Zip,
        "tarball" => BackupFormat.Tarball,
        _ => null,
    };

    public static string Label(this BackupFormat format) => format == BackupFormat.Zip ? "Zip" : "Tarball";

    public static string FileExtension(this BackupFormat format) => format == BackupFormat.Zip ? "zip" : "tar.gz";
}

public struct ArchiveProgress
{
    public long BytesDone { get; set; }

    public long BytesTotal { get; set; }

    public int FilesDone { get; set; }

    public int FilesTotal { get; set; }

    public string CurrentFile { get; set; }

    public readonly double Fraction => BytesTotal > 0 ? Math.Min((double)BytesDone / BytesTotal, 1) : 0;
}

public sealed class DuplicateCleanup
{
    public int Deleted { get; set; }

    public int Skipped { get; set; }

    public int RemovedFolders { get; set; }

    /// <summary>Emptied capture folders kept because they hold JSON or astrometry files not yet allowed to be deleted.</summary>
    public Dictionary<string, ProtectedFiles> Held { get; set; } = new();
}

/// <summary>Which protected files a folder may be deleted with. Off by default, so the user is asked first.</summary>
public readonly record struct DeletePermissions(bool Json = false, bool Astrometry = false);

/// <summary>What is left in a folder that's about to be deleted, apart from the files that deletion is meant to remove.</summary>
public sealed class ProtectedFiles
{
    public int Json { get; set; }

    /// <summary>Plate-solve files: named astrometry.*, or inside a folder whose name contains "astrometry".</summary>
    public int Astrometry { get; set; }

    /// <summary>Anything else, e.g. .afphoto or .seq, by lowercased extension. A folder holding these is never deleted.</summary>
    public Dictionary<string, int> Other { get; set; } = new();

    public bool BlockedBy(DeletePermissions permissions) =>
        (Json > 0 && !permissions.Json) || (Astrometry > 0 && !permissions.Astrometry);
}

/// <summary>
/// The outcome of deleting folders: those removed, those held back for JSON or astrometry files, and those kept because
/// they hold other files.
/// </summary>
public sealed class FolderCleanup
{
    public int Removed { get; set; }

    public Dictionary<string, ProtectedFiles> Held { get; set; } = new();

    public Dictionary<string, Dictionary<string, int>> Kept { get; set; } = new();
}

/// <summary>An original that has been copied and checked byte for byte; it is deleted only when the user agrees.</summary>
public sealed record CopiedItem(string Original, string Copy, bool IsFolder);

/// <summary>Byte-identical copies of one file inside a Targets {year}/{object} folder: the one kept and the extras.</summary>
public sealed record RedundantCopies(string Keep, IReadOnlyList<string> Extras);

public sealed class CopyResult
{
    public List<CopiedItem> Copied { get; } = new();

    public List<string> Failed { get; } = new();

    public string? Error { get; set; }
}

/// <summary>A folder kept out of Targets and offered for Move, Leave or Delete after a sort: plate solves or calibration frames.</summary>
public sealed record SetAsideFolder(string Path, IReadOnlyDictionary<string, int> Images)
{
    public string Id => Path;
}

public sealed record BackupSummary(int Folders, int Files, string Destination);

/// <summary>Where one plate-solve folder goes when moved: Targets {year}/{object}/Plate Solves/{session}/{subpath}.</summary>
public sealed record PlateSolveMove
{
    /// <summary>Relative to the Capture Folder.</summary>
    public required string Path { get; init; }

    /// <summary>From the observation or target-named folder above; null when none names one, and the user is asked.</summary>
    public string? Object { get; init; }

    public required string Year { get; init; }

    public required string Session { get; init; }

    /// <summary>
    /// The folders below the observation folder, e.g. 10-pointing-bad-registration/01-pointing-astrometry; just the
    /// folder's own name when nothing above names an object.
    /// </summary>
    public required string Subpath { get; init; }

    public int Images { get; init; }

    public string SessionDate => Session.Length > 10 ? Session[..10] : Session;
}

public sealed record ScanResult(IReadOnlyList<CaptureEntry> Entries, IReadOnlyList<string> Years, string Excluded);
