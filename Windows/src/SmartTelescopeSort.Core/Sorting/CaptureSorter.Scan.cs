using System.Globalization;
using System.Text.RegularExpressions;
using SmartTelescopeSort.Core.IO;

namespace SmartTelescopeSort.Core.Sorting;

/// <summary>
/// The sorting rules of Telescope Data Sort for the Mac (CaptureSorter.swift), on Windows paths. Every layout is scanned
/// the same way; nothing is moved in one step: files are copied, checked byte for byte, and originals are deleted only
/// when the user agrees.
/// </summary>
public static partial class CaptureSorter
{
    private static PathRules R => PathRules.Host;

    /// <summary>Extensions the next scan sorts; set from the file-type checkboxes.</summary>
    public static HashSet<string> SortExtensions { get; set; } = SortFileTypes.ExtensionsOf(SortFileTypes.Defaults);

    /// <summary>Any of these left in a capture folder keeps it from being deleted, whether or not its type is being sorted.</summary>
    public static readonly IReadOnlySet<string> KeepFolderExtensions = new HashSet<string> { "tif", "tiff", "fit", "fits", "jpg", "jpeg", "png" };

    // Vaonis / Singularity
    [GeneratedRegex(@"^(?:\d+-)?observation[-_](.+)$", RegexOptions.IgnoreCase)]
    private static partial Regex Observation();

    [GeneratedRegex(@"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_observation[-_](.+)$", RegexOptions.IgnoreCase)]
    private static partial Regex DatedObservationCapture();

    [GeneratedRegex(@"^(?:\d+-)?images(?:[-_].+)?$", RegexOptions.IgnoreCase)]
    private static partial Regex ImagesFolder();

    // Origin: M31_2024-06-15 or M31-2024-06-15
    [GeneratedRegex(@"^(.+?)[_-](\d{4})-(\d{2})-(\d{2})(?:$|[_-].*)", RegexOptions.IgnoreCase)]
    private static partial Regex OriginDatedObject();

    // Generic leading date YYYY-MM-DD or YYYYMMDD
    [GeneratedRegex(@"^(\d{4})-(\d{2})-(\d{2})")]
    private static partial Regex LeadingIsoDate();

    [GeneratedRegex(@"^(\d{4})(\d{2})(\d{2})(?:[_-].*)?$")]
    private static partial Regex LeadingCompactDate();

    // Month first, year last: 4-19-2026, 10-7-2025, 04_05_2026
    [GeneratedRegex(@"^(\d{1,2})[-_.](\d{1,2})[-_.](\d{4})(?:$|\D)")]
    private static partial Regex MonthFirstDate();

    [GeneratedRegex(@"^\d{4}-\d{2}-\d{2}[_ T-](\d{2})[-:](\d{2})[-:](\d{2})")]
    private static partial Regex LeadingTimestamp();

    // Catalog designations (M31, NGC 7000, IC_1805, Sh2-155, Barnard150, C 2023 A3…) and solar-system targets.
    [GeneratedRegex(@"(?:^|[^A-Za-z])(?:M|NGC|IC|Sh2|Sh-2|SH2|C|B|Barnard|LDN|LBN|vdB|Abell|Arp|Mel|Cr|Collinder|UGC|PGC|Caldwell)[ _-]?\d+", RegexOptions.IgnoreCase)]
    private static partial Regex CatalogObject();

    [GeneratedRegex(@"(?:^|[^A-Za-z])(?:moon|sun|mercury|venus|mars|jupiter|saturn|uranus|neptune|pluto|comet)(?:$|[^A-Za-z])", RegexOptions.IgnoreCase)]
    private static partial Regex SolarSystemObject();

    // Lights, Darks, Dark Flats, Flats, Bias and Master… folders, including names like Flats1x20 or Dark_Flats.
    [GeneratedRegex(@"^(?:master|(?:lights?|darks?|dark[ _-]?flats?|flats?|bias(?:es)?)(?:$|[^a-z]))", RegexOptions.IgnoreCase)]
    private static partial Regex CalibrationFolderName();

    [GeneratedRegex(@"^\d{4}-\d{2}-\d{2}(?:[_ T-]\d{2}[-:]\d{2}(?:[-:]\d{2})?)?[_ -]*")]
    private static partial Regex StripLeadingIso();

    [GeneratedRegex(@"^\d{1,2}[-_.]\d{1,2}[-_.]\d{4}[_ -]*")]
    private static partial Regex StripLeadingMonthFirst();

    [GeneratedRegex(@"[_ -]+\d{4}-\d{2}-\d{2}.*$")]
    private static partial Regex StripTrailingIso();

    [GeneratedRegex(@"[_ -]+\d{1,2}[-_.]\d{1,2}[-_.]\d{4}.*$")]
    private static partial Regex StripTrailingMonthFirst();

    [GeneratedRegex(@"[_-](stacked|stack|fit|fits|tiff?)$", RegexOptions.IgnoreCase)]
    private static partial Regex TrailingNoise();

    [GeneratedRegex(@"\s+")]
    private static partial Regex Whitespace();

    [GeneratedRegex(@" \d+$")]
    private static partial Regex NumberSuffix();

    [GeneratedRegex(@"^Targets \d{4}$")]
    private static partial Regex TargetsYear();

    [GeneratedRegex(@"^\d{4}$")]
    private static partial Regex FourDigits();

    private sealed class Bundle
    {
        public required string Capture { get; init; }
        public required string Object { get; init; }
        public required FolderDate Date { get; init; }
        public bool NeedsObjectName { get; init; }
        public int Folders { get; set; }
        public List<string> Files { get; } = new();
    }

    /// <summary>
    /// Every layout is searched the same way, to any depth below `sourceRoot`: observation folders first, then the
    /// nearest folder naming a target above any other image files. `kind` only labels the layout in the window.
    /// </summary>
    public static ScanResult Scan(TelescopeKind kind, string sourceRoot, string? targetsRoot = null, string? year = null,
                                  string? month = null, ScanMonitor? monitor = null) =>
        ScanCaptures(sourceRoot, targetsRoot ?? sourceRoot, year, month, monitor);

    private static ScanResult ScanCaptures(string sourceRoot, string targetsRoot, string? year, string? month, ScanMonitor? monitor)
    {
        if (!FileOps.Exists(sourceRoot)) return new ScanResult(Array.Empty<CaptureEntry>(), Array.Empty<string>(), "Targets …");

        var bundles = new Dictionary<string, Bundle>(StringComparer.Ordinal);
        void Add(string capture, string obj, IReadOnlyList<string> files, int folders, string datedBy, bool needsObjectName = false)
        {
            var date = NamedDate(datedBy, sourceRoot) ?? NewestDate(files.Count == 0 ? new[] { datedBy } : files);
            var key = $"{RelativePath(capture, sourceRoot)}|{obj}|{date.Session}";
            if (!bundles.TryGetValue(key, out var bundle))
            {
                bundle = new Bundle { Capture = capture, Object = obj, Date = date, NeedsObjectName = needsObjectName };
                bundles[key] = bundle;
            }
            bundle.Folders += folders;
            bundle.Files.AddRange(files);
        }

        var units = ObservationUnits(sourceRoot, monitor);
        monitor?.CheckCancelled();
        monitor?.Report(2, "Reading observation folders", total: units.Count, force: true);
        for (var index = 0; index < units.Count; index++)
        {
            monitor?.CheckCancelled();
            monitor?.Report(2, "Reading observation folders", index + 1, units.Count);
            var unit = units[index];
            var imageDirs = ImagesFolders(unit.Observation);
            var files = ImageFiles(imageDirs, unit.Observation);
            Add(unit.Capture, unit.Object, files, Math.Max(imageDirs.Count, 1), unit.Observation);
        }

        var claimed = new HashSet<string>(units.Select(u => Norm(u.Observation)), R.Comparer);
        var unclaimed = UnclaimedImageFiles(sourceRoot, claimed, monitor);
        monitor?.CheckCancelled();
        foreach (var (folder, files) in unclaimed)
        {
            var capture = CaptureFolder(folder, sourceRoot);
            var name = ObjectName(Path.GetFileName(capture));
            Add(capture, DsoName(name), files, 1, folder, needsObjectName: !NamesTarget(name));
        }

        var entries = new List<CaptureEntry>();
        var years = new HashSet<string>();
        foreach (var bundle in bundles.Values)
        {
            years.Add(bundle.Date.Year);
            if (year is not null && year != "all" && bundle.Date.Year != year) continue;
            if (month is not null && month != "all" && bundle.Date.Month != month) continue;
            var row = Entry(RelativePath(bundle.Capture, sourceRoot), bundle.Object, bundle.Date, bundle.Folders, bundle.Files, targetsRoot);
            entries.Add(row with { NeedsObjectName = bundle.NeedsObjectName });
        }

        entries.Sort((a, b) => CompareTuple(
            (a.Year, b.Year), (a.Month, b.Month), (a.CaptureFolder, b.CaptureFolder), (a.Object, b.Object), (a.Session, b.Session)));
        return new ScanResult(entries, years.OrderByDescending(y => y, StringComparer.Ordinal).ToList(), "Targets …");
    }

    /// <summary>
    /// The rows the window lists: those with files to sort. Rows with none stay in the scan, since they mark capture
    /// folders a sort emptied or finished, which the app offers to remove.
    /// </summary>
    public static List<CaptureEntry> RowsToShow(IEnumerable<CaptureEntry> entries) => entries.Where(e => e.Files > 0).ToList();

    private static CaptureEntry Entry(string capture, string obj, FolderDate date, int imageFolders, IEnumerable<string> files, string targetsRoot)
    {
        var uniqueFiles = DedupeFiles(files);
        var yearFolder = Path.Combine(targetsRoot, $"Targets {date.Year}");
        return new CaptureEntry
        {
            CaptureFolder = capture,
            Year = date.Year,
            Month = date.Month,
            Object = obj,
            Session = date.Session,
            ImageFolders = imageFolders,
            Files = uniqueFiles.Count,
            Formats = Formats(uniqueFiles),
            YearFolder = yearFolder,
            TargetExists = Directory.Exists(yearFolder),
            SourceFiles = uniqueFiles,
        };
    }

    private sealed record ObservationUnit(string Capture, string Observation, string Object);

    /// <summary>
    /// Observation folders at any depth under `root`, whatever the folders above them are called.
    /// Targets {year} folders are not entered, and nothing inside an observation folder is searched again.
    /// An NN-observation folder straight in `root` is its own capture: the capture can't be `root` itself.
    /// </summary>
    private static List<ObservationUnit> ObservationUnits(string root, ScanMonitor? monitor = null)
    {
        var units = new List<ObservationUnit>();
        var rootPath = Norm(root);
        ObservationUnit? UnitFor(string folder)
        {
            var name = Path.GetFileName(folder);
            var match = DatedObservationCapture().Match(name);
            if (match.Success) return new ObservationUnit(folder, folder, DsoName(match.Groups[1].Value));
            match = Observation().Match(name);
            if (!match.Success) return null;
            var parent = R.Parent(folder);
            var capture = R.Comparer.Equals(Norm(parent), rootPath) ? folder : parent;
            return new ObservationUnit(capture, folder, DsoName(match.Groups[1].Value));
        }
        if (UnitFor(Norm(root)) is { } rootUnit) return new List<ObservationUnit> { new(root, root, rootUnit.Object) };

        var searched = 0;
        monitor?.Report(1, "Finding observation folders", force: true);
        FileOps.Walk(root, info =>
        {
            if (info is not DirectoryInfo) return WalkAction.Continue;
            if (monitor?.IsCancelled == true) return WalkAction.Stop;
            searched++;
            monitor?.Report(1, "Finding observation folders", searched);
            if (IsTargetsFolder(info.Name)) return WalkAction.SkipDescendants;
            if (UnitFor(info.FullName) is { } found)
            {
                units.Add(found);
                return WalkAction.SkipDescendants;
            }
            return WalkAction.Continue;
        });
        units.Sort((a, b) => string.CompareOrdinal(a.Observation, b.Observation));
        return units;
    }

    /// <summary>
    /// Image files of the checked types under `root` outside Targets {year} and outside the `skipping` folders, grouped by
    /// the folder that holds them. Files with no dated or observation folder above them still get sorted this way.
    /// </summary>
    private static List<(string Folder, List<string> Files)> UnclaimedImageFiles(string root, IReadOnlySet<string> skipping, ScanMonitor? monitor = null)
    {
        var byFolder = new Dictionary<string, (string Folder, List<string> Files)>(R.Comparer);
        var searched = 0;
        monitor?.Report(3, "Finding other images", force: true);
        FileOps.Walk(root, info =>
        {
            if (info is DirectoryInfo)
            {
                if (monitor?.IsCancelled == true) return WalkAction.Stop;
                searched++;
                monitor?.Report(3, "Finding other images", searched);
                var name = info.Name;
                if (IsTargetsFolder(name) || IsSetupFolder(name) || IsCalibrationFolder(name) || skipping.Contains(Norm(info.FullName)))
                    return WalkAction.SkipDescendants;
                return WalkAction.Continue;
            }
            if (!SortExtensions.Contains(Extension(info.Name).ToLowerInvariant())) return WalkAction.Continue;
            var folder = R.Parent(info.FullName);
            var key = Norm(folder);
            if (!byFolder.TryGetValue(key, out var group))
            {
                group = (folder, new List<string>());
                byFolder[key] = group;
            }
            group.Files.Add(info.FullName);
            return WalkAction.Continue;
        });
        return byFolder.Values.OrderBy(g => g.Folder, StringComparer.Ordinal).ToList();
    }

    internal static bool NamesTarget(string name) => CatalogObject().IsMatch(name) || SolarSystemObject().IsMatch(name);

    /// <summary>
    /// The capture a folder of image files belongs to: the nearest folder at or above it, up to `root`, that names a
    /// deep-sky or solar-system target; else the nearest one below `root` that isn't a date or a word like lights or
    /// raw; else the folder itself.
    /// </summary>
    private static string CaptureFolder(string folder, string root)
    {
        var rootPath = Norm(root);
        string? named = null;
        var url = Norm(folder);
        while (R.IsSameOrInside(url, rootPath))
        {
            if (NamesTarget(ObjectName(R.LastComponent(url)))) return url;
            if (R.AreSame(url, rootPath) || R.IsRoot(url)) break;
            if (named is null && !IsGenericFolderName(R.LastComponent(url))) named = url;
            url = R.Parent(url);
        }
        return named ?? folder;
    }

    private static readonly HashSet<string> GenericFolderNames = new()
    {
        "light", "lights", "raw", "raws", "image", "images", "img", "sub", "subs", "frame", "frames", "capture", "captures",
        "fit", "fits", "tif", "tiff", "jpg", "jpeg", "stack", "stacked", "output", "user", "data", "files",
        "dark", "darks", "flat", "flats", "bias",
    };

    /// <summary>Folder names that say nothing about the target: dates and numbers, image or frame folders.</summary>
    private static bool IsGenericFolderName(string name)
    {
        var lower = name.ToLowerInvariant();
        return GenericFolderNames.Contains(lower) || ImagesFolder().IsMatch(name) || !lower.Any(char.IsLetter);
    }

    /// <summary>
    /// Folders of frames that aren't target images: thumbnails, the telescope's auto-init shots, and the plate-solve
    /// frames taken while pointing and guiding (NN-pointing-astrometry, NN-post-guiding-astrometry…).
    /// </summary>
    private static bool IsSetupFolder(string name)
    {
        var lower = name.ToLowerInvariant();
        return lower == "thumbnail" || lower == "thumbnails" || lower.EndsWith("_thumbnail", StringComparison.Ordinal)
            || lower.Contains("auto-init") || IsPlateSolveFolder(name);
    }

    public static bool IsCalibrationFolder(string name) => CalibrationFolderName().IsMatch(name);

    /// <summary>True when a folder between `base` and `file` holds setup or calibration frames rather than target images.</summary>
    private static bool IsSetupOrCalibrationFile(string file, string below)
    {
        var relative = R.RelativePath(R.Parent(file), below);
        if (R.AreSame(R.Parent(file), below)) return false;
        return R.Split(relative).Any(n => IsSetupFolder(n) || IsCalibrationFolder(n));
    }

    /// <summary>Folders of plate-solve frames the telescope took while pointing and guiding (01-pointing-astrometry…).</summary>
    public static bool IsPlateSolveFolder(string name) => name.ToLowerInvariant().Contains("astrometry");

    /// <summary>A folder name without vendor prefixes or the dates around it: "2025-01-04 M42" and "M42_2025-01-04" give "M42".</summary>
    internal static string ObjectName(string folderName)
    {
        var name = StripVendorNoise(folderName);
        name = StripLeadingIso().Replace(name, "");
        name = StripLeadingMonthFirst().Replace(name, "");
        name = StripTrailingIso().Replace(name, "");
        name = StripTrailingMonthFirst().Replace(name, "");
        return name.Length == 0 ? folderName : name;
    }

    private static bool IsTargetsFolder(string name) => name.ToLowerInvariant().StartsWith("targets ", StringComparison.Ordinal);

    /// <summary>`path` as a path under `root` ("" for `root` itself); just its last name when it is outside `root`.</summary>
    public static string RelativePath(string path, string root) => R.RelativePath(path, root);

    private static string Norm(string path) => R.Normalize(path);

    private readonly record struct FolderDate(string Year, string Month, string Session);

    /// <summary>The date named by `folder` or the nearest folder above it, up to and including `root`.</summary>
    private static FolderDate? NamedDate(string folder, string root)
    {
        var rootPath = Norm(root);
        var url = Norm(folder);
        while (true)
        {
            if (FolderDateFromName(R.LastComponent(url)) is { } date) return date;
            if (R.AreSame(url, rootPath) || R.IsRoot(url) || !R.IsSameOrInside(url, rootPath)) return null;
            url = R.Parent(url);
        }
    }

    private static FolderDate NewestDate(IEnumerable<string> files)
    {
        var dates = files.Select(FileOps.Modified).Where(d => d > DateTime.MinValue).ToList();
        var newest = dates.Count > 0 ? dates.Max() : DateTime.Now;
        var year = newest.Year.ToString(CultureInfo.InvariantCulture);
        var month = newest.Month.ToString("00", CultureInfo.InvariantCulture);
        return new FolderDate(year, month, $"{year}-{month}-{newest.Day.ToString("00", CultureInfo.InvariantCulture)}");
    }

    /// <summary>
    /// The date in a folder name with the year first (2026-04-20…, 20260420) or last (4-19-2026), or an
    /// Object_YYYY-MM-DD name. A number on its own, such as 2025 or the 2024 in NGC2024, is not a date.
    /// </summary>
    private static FolderDate? FolderDateFromName(string name)
    {
        static FolderDate? Checked(string year, string month, string day)
        {
            if (year.Length != 4 || !int.TryParse(month, NumberStyles.None, CultureInfo.InvariantCulture, out var m) || m is < 1 or > 12
                || !int.TryParse(day, NumberStyles.None, CultureInfo.InvariantCulture, out var d) || d is < 1 or > 31) return null;
            var mm = m.ToString("00", CultureInfo.InvariantCulture);
            return new FolderDate(year, mm, $"{year}-{mm}-{d.ToString("00", CultureInfo.InvariantCulture)}");
        }

        var match = LeadingIsoDate().Match(name);
        if (match.Success && Checked(match.Groups[1].Value, match.Groups[2].Value, match.Groups[3].Value) is { } iso)
        {
            var time = LeadingTimestamp().Match(name);
            return time.Success
                ? iso with { Session = $"{iso.Session}_{time.Groups[1].Value}-{time.Groups[2].Value}-{time.Groups[3].Value}" }
                : iso;
        }
        match = LeadingCompactDate().Match(name);
        if (match.Success && Checked(match.Groups[1].Value, match.Groups[2].Value, match.Groups[3].Value) is { } compact) return compact;
        match = MonthFirstDate().Match(name);
        if (match.Success && Checked(match.Groups[3].Value, match.Groups[1].Value, match.Groups[2].Value) is { } monthFirst) return monthFirst;
        match = OriginDatedObject().Match(name);
        if (match.Success && Checked(match.Groups[2].Value, match.Groups[3].Value, match.Groups[4].Value) is { } origin) return origin;
        return null;
    }

    private static string StripVendorNoise(string raw)
    {
        var s = raw;
        var lower = s.ToLowerInvariant();
        foreach (var prefix in new[] { "seestar_", "seestar-", "dwarf_", "dwarf-", "dwarf3_", "origin_", "origin-" })
        {
            if (!lower.StartsWith(prefix, StringComparison.Ordinal)) continue;
            s = s[prefix.Length..];
            break;
        }
        var noise = TrailingNoise().Match(s);
        if (noise.Success) s = s.Remove(noise.Index, noise.Length);
        return s;
    }

    // MARK: - Vaonis helpers

    private static List<string> ImagesFolders(string observationFolder)
    {
        var folders = new List<string>();
        var observationPath = Norm(observationFolder);
        FileOps.Walk(observationFolder, info =>
        {
            if (info is not DirectoryInfo) return WalkAction.Continue;
            var name = info.Name;
            if (Observation().IsMatch(name) && !R.AreSame(R.Parent(info.FullName), observationPath)) return WalkAction.SkipDescendants;
            if (ImagesFolder().IsMatch(name)) folders.Add(info.FullName);
            return WalkAction.Continue;
        });
        folders.Sort(StringComparer.Ordinal);
        return folders;
    }

    private static List<string> ImageFiles(IReadOnlyList<string> imageFolders, string observationFolder)
    {
        var files = imageFolders.Count == 0 ? ImageFiles(observationFolder) : imageFolders.SelectMany(f => ImageFiles(f)).ToList();
        return files.Where(f => !IsSetupOrCalibrationFile(f, observationFolder)).ToList();
    }

    internal static List<string> ImageFiles(string folder, IReadOnlySet<string>? extensions = null)
    {
        extensions ??= SortExtensions;
        var files = new List<string>();
        FileOps.Walk(folder, info =>
        {
            if (info is FileInfo && extensions.Contains(Extension(info.Name).ToLowerInvariant())) files.Add(info.FullName);
            return WalkAction.Continue;
        });
        files.Sort(StringComparer.Ordinal);
        return files;
    }

    private static List<string> DedupeFiles(IEnumerable<string> files)
    {
        var seen = new HashSet<string>(R.Comparer);
        var unique = new List<string>();
        foreach (var file in files.OrderBy(f => f, StringComparer.Ordinal))
            if (seen.Add(Norm(file))) unique.Add(file);
        return unique;
    }

    private static List<string> Formats(IReadOnlyCollection<string> files) =>
        files.Count == 0 ? new List<string>() : files.Select(f => Extension(f).ToUpperInvariant()).Distinct().OrderBy(f => f, StringComparer.Ordinal).ToList();

    internal static string DsoName(string raw) =>
        WindowsNames.SafeSegment(Whitespace().Replace(raw.Trim(), "-").ToUpperInvariant());

    /// <summary>The extension after the last dot of a file name, without the dot ("" when none), like URL.pathExtension.</summary>
    public static string Extension(string path)
    {
        var name = Path.GetFileName(path);
        var dot = name.LastIndexOf('.');
        return dot > 0 && dot < name.Length - 1 ? name[(dot + 1)..] : "";
    }

    /// <summary>The file name without its extension, like URL.deletingPathExtension().lastPathComponent.</summary>
    public static string BaseName(string path)
    {
        var name = Path.GetFileName(path);
        var ext = Extension(name);
        return ext.Length == 0 ? name : name[..(name.Length - ext.Length - 1)];
    }

    private static int CompareTuple(params (string A, string B)[] pairs)
    {
        foreach (var (a, b) in pairs)
        {
            var c = string.CompareOrdinal(a, b);
            if (c != 0) return c;
        }
        return 0;
    }
}
