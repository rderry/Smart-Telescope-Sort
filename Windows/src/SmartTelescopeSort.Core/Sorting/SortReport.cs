namespace SmartTelescopeSort.Core.Sorting;

/// <summary>
/// A dry-run (or copy-sort) report in plain sorted lines with "/" separators, the same format as
/// tools/mac-golden/GoldenReport.swift prints from the Mac sorter, so the two can be compared on any machine.
/// </summary>
public static class SortReport
{
    public static List<string> Lines(string source, string targets, IEnumerable<SortFileType> types, bool sort = false)
    {
        CaptureSorter.SortExtensions = SortFileTypes.ExtensionsOf(types);
        var lines = new List<string> { $"layout {TelescopeKinds.Detect(source)?.RawValue() ?? "none"}" };
        var entries = CaptureSorter.Scan(TelescopeKind.Vaonis, source, targets).Entries;
        foreach (var e in entries)
            lines.Add($"entry {Slashes(e.CaptureFolder)}|{e.Year}|{e.Month}|{e.Object}|{e.Session}|{e.ImageFolders}|{e.Files}|"
                      + $"{string.Join(',', e.Formats)}|{(e.NeedsObjectName ? "true" : "false")}");
        var (plans, _) = CaptureSorter.Preview(entries);
        foreach (var p in plans)
            lines.Add($"plan {Relative(p.Source, source)}|{Relative(p.Destination, targets)}|{(p.Action == SortAction.Move ? "move" : "duplicate")}");
        var setAside = CaptureSorter.SetAsideFolders(source, null);
        foreach (var f in setAside.Calibration) lines.Add($"calibration {Slashes(f.Path)}|{Counts(f.Images)}");
        foreach (var f in setAside.PlateSolves) lines.Add($"platesolve {Slashes(f.Path)}|{Counts(f.Images)}");
        foreach (var m in CaptureSorter.PlateSolveMoves(setAside.PlateSolves, source))
            lines.Add($"psmove {Slashes(m.Path)}|{m.Object ?? "-"}|{m.Year}|{m.Session}|{Slashes(m.Subpath)}|{m.Images}");
        if (sort)
        {
            var result = CaptureSorter.CopySort(entries, source, targets);
            foreach (var c in result.Copied) lines.Add($"copied {Relative(c.Original, source)}|{Relative(c.Copy, targets)}");
            foreach (var f in result.Failed) lines.Add($"failed {f}");
            if (result.Error is { } error) lines.Add($"error {error}");
        }
        lines.Sort(StringComparer.Ordinal);
        return lines;
    }

    private static string Slashes(string path) => path.Replace('\\', '/');

    private static string Relative(string path, string root) => Slashes(CaptureSorter.RelativePath(path, root));

    private static string Counts(IReadOnlyDictionary<string, int> images) =>
        string.Join(',', images.Keys.OrderBy(k => k, StringComparer.Ordinal).Select(k => $"{k}={images[k]}"));
}
