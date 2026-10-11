using System.IO;

namespace SmartTelescopeSort.App.Shell;

/// <summary>
/// Command-line options. None are needed for normal use; they let tests and screenshots run against scratch folders.
/// <list type="bullet">
/// <item><c>--captures &lt;folder&gt;</c>, <c>--targets &lt;folder&gt;</c>, <c>--backup &lt;folder&gt;</c>: folders for this session only.</item>
/// <item><c>--data-dir &lt;folder&gt;</c> (or STS_DATA_DIR): where settings and the terms record live instead of %LOCALAPPDATA%.</item>
/// <item><c>--capture &lt;folder&gt;</c> [<c>--size WxH</c>]: renders the window and dialogs to PNG files there, then exits.</item>
/// <item><c>--auto-sort &lt;log&gt;</c>: scans and sorts with scripted answers (never deleting originals unless
/// <c>--delete-originals</c>; items too long for the Recycle Bin are kept unless <c>--delete-long-paths</c>), writes the
/// log, then exits.</item>
/// </list>
/// </summary>
public sealed class StartupOptions
{
    public string? Captures { get; private init; }
    public string? Targets { get; private init; }
    public string? Backup { get; private init; }
    public string DataDir { get; private init; } = "";
    public string? CaptureFolder { get; private init; }
    public int? Width { get; private init; }
    public int? Height { get; private init; }
    public string? AutoSortLog { get; private init; }
    public bool DeleteOriginals { get; private init; }
    public bool DeleteLongPaths { get; private init; }

    /// <summary>Settings are not written to the user's folder during screenshots or scripted runs without --data-dir.</summary>
    public bool IsAutomation => CaptureFolder is not null || AutoSortLog is not null;

    public static StartupOptions Parse(IReadOnlyList<string> args)
    {
        string? Value(string name)
        {
            for (var i = 0; i < args.Count - 1; i++)
                if (string.Equals(args[i], name, StringComparison.OrdinalIgnoreCase)) return args[i + 1];
            return null;
        }

        bool Flag(string name) => args.Any(a => string.Equals(a, name, StringComparison.OrdinalIgnoreCase));

        int? width = null, height = null;
        if (Value("--size") is { } size && size.Split('x', 'X') is [var w, var h] && int.TryParse(w, out var pw) && int.TryParse(h, out var ph))
        {
            width = pw;
            height = ph;
        }
        var capture = Value("--capture");
        var autoSort = Value("--auto-sort");
        var dataDir = Value("--data-dir") ?? Environment.GetEnvironmentVariable("STS_DATA_DIR");
        if (string.IsNullOrWhiteSpace(dataDir))
            dataDir = capture is not null || autoSort is not null
                ? Path.Combine(Path.GetTempPath(), "SmartTelescopeSort-automation")
                : Core.Settings.SettingsStore.DefaultFolder;
        return new StartupOptions
        {
            Captures = Value("--captures"),
            Targets = Value("--targets"),
            Backup = Value("--backup"),
            DataDir = dataDir,
            CaptureFolder = capture,
            Width = width,
            Height = height,
            AutoSortLog = autoSort,
            DeleteOriginals = Flag("--delete-originals"),
            DeleteLongPaths = Flag("--delete-long-paths"),
        };
    }
}
