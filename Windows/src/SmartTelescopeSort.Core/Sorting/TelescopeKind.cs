using System.Text.RegularExpressions;
using SmartTelescopeSort.Core.IO;

namespace SmartTelescopeSort.Core.Sorting;

/// <summary>Smart-telescope family: labels how that brand drops TIFF/FITS onto disk after USB / FTP / Wi-Fi transfer.</summary>
public enum TelescopeKind
{
    Vaonis,
    Seestar,
    Dwarf,
    Origin,
}

public static partial class TelescopeKinds
{
    public static readonly TelescopeKind[] All = { TelescopeKind.Vaonis, TelescopeKind.Seestar, TelescopeKind.Dwarf, TelescopeKind.Origin };

    public static string RawValue(this TelescopeKind kind) => kind switch
    {
        TelescopeKind.Vaonis => "vaonis",
        TelescopeKind.Seestar => "seestar",
        TelescopeKind.Dwarf => "dwarf",
        _ => "origin",
    };

    public static TelescopeKind? FromRaw(string? raw) => All.Cast<TelescopeKind?>().FirstOrDefault(k => k!.Value.RawValue() == raw);

    /// <summary>Start-menu name. No manufacturer or model names.</summary>
    public static string EditionName(this TelescopeKind kind) => kind switch
    {
        TelescopeKind.Vaonis => "Telescope Data Sort — Dated Sessions",
        TelescopeKind.Seestar => "Telescope Data Sort — Object Albums",
        TelescopeKind.Dwarf => "Telescope Data Sort — Session Files",
        _ => "Telescope Data Sort — Object Date Folders",
    };

    public static string LayoutTitle(this TelescopeKind kind) => kind switch
    {
        TelescopeKind.Vaonis => "Dated session folders",
        TelescopeKind.Seestar => "Object album folders",
        TelescopeKind.Dwarf => "Session folders",
        _ => "Object and date folders",
    };

    /// <summary>One nominative mention, only inside the app, with a non-affiliation statement.</summary>
    public static string CompatibilityNote(this TelescopeKind kind) => kind switch
    {
        TelescopeKind.Vaonis => "Reads dated session folders from Vespera and Stellina telescopes. Independent app. Not affiliated with or created by Vaonis.",
        TelescopeKind.Seestar => "Reads object albums from S30, S30 Pro, and S50 telescopes. Independent app. Not affiliated with or created by ZWO.",
        TelescopeKind.Dwarf => "Reads session folders from DWARF 3, II, and mini telescopes. Independent app. Not affiliated with or created by DWARFLAB.",
        _ => "Reads object-and-date folders from Origin Mark II telescopes. Independent app. Not affiliated with or created by Celestron.",
    };

    /// <summary>Bold at the top of the main window and on page 1 of the manual. Same wording as the Mac app.</summary>
    public const string UntestedNotice = "This has not been tested with other telescopes, but there is no reason it will not work with almost any data that it supports!";

    public const string NotAffiliated = "Telescope names identify folder layouts only. This app is not affiliated with or created by those manufacturers.";

    /// <summary>Shown when no smart-telescope layout is found. Every layout is sorted the same way, so these images still sort.</summary>
    public const string OtherLayoutTitle = "Folders from any telescope or camera";

    public const string OtherCompatibilityNote = "No smart-telescope layout found. Images from any telescope or camera, including classic setups, "
        + "are sorted by the object their folders name, such as M31\\ or NGC 7000\\. Independent app. Not affiliated with telescope makers.";

    public const string OtherDropHint = "Copy smart-telescope sessions into the Capture Folder as they are. From any other telescope or camera, "
        + "put the TIFF or FITS files in a folder named for the object, such as M31\\.";

    public static string MenuTitle(this TelescopeKind kind) => kind.LayoutTitle();

    /// <summary>First How It Works step: how this layout's files get into Captures.</summary>
    public static string DropHint(this TelescopeKind kind) => kind switch
    {
        TelescopeKind.Vaonis => "Copy the telescope’s dated session folders into the Capture Folder.",
        TelescopeKind.Seestar => "Copy object albums into the Capture Folder and keep FIT/FITS files inside each object folder.",
        TelescopeKind.Dwarf => "Copy session folders into the Capture Folder and keep the FITS/TIFF files inside each session.",
        _ => "Copy raw folders named with the object and date into Captures. Turn on raw-image saving on the telescope first.",
    };

    [GeneratedRegex(@"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_(observation|plan)[-_]", RegexOptions.IgnoreCase)]
    private static partial Regex DatedSession();

    [GeneratedRegex(@"^\d+-(observation|images)", RegexOptions.IgnoreCase)]
    private static partial Regex NumberedObservation();

    [GeneratedRegex(@"^[A-Za-z][^_-]*(?:[_-][A-Za-z][^_-]*)*[_-]\d{4}-\d{2}-\d{2}", RegexOptions.IgnoreCase)]
    private static partial Regex OriginFolder();

    /// <summary>
    /// The layout most capture folders under `root` follow, at any depth, or null when none are recognisable.
    /// A recognised folder is not searched further; Targets {year} folders are skipped.
    /// </summary>
    public static TelescopeKind? Detect(string root, int maxDepth = 8)
    {
        var votes = new Dictionary<TelescopeKind, int>();
        var pending = new List<(string Folder, int Depth)> { (root, 0) };
        while (pending.Count > 0)
        {
            var (folder, depth) = pending[^1];
            pending.RemoveAt(pending.Count - 1);
            foreach (var child in FileOps.Subfolders(folder))
            {
                if (Path.GetFileName(child).ToLowerInvariant().StartsWith("targets ", StringComparison.Ordinal)) continue;
                if (Guess(child) is { } kind) votes[kind] = votes.GetValueOrDefault(kind) + 1;
                else if (depth < maxDepth) pending.Add((child, depth + 1));
            }
        }
        if (votes.Count == 0) return null;
        // Most votes; a tie goes to the kind whose raw value sorts first.
        return votes.OrderByDescending(v => v.Value).ThenBy(v => v.Key.RawValue(), StringComparer.Ordinal).First().Key;
    }

    private static TelescopeKind? Guess(string folder)
    {
        var name = Path.GetFileName(folder);
        var lower = name.ToLowerInvariant();
        if (lower.Contains("seestar")) return TelescopeKind.Seestar;
        if (lower.Contains("dwarf")) return TelescopeKind.Dwarf;
        if (DatedSession().IsMatch(name)) return TelescopeKind.Vaonis;
        var kids = FileOps.Subfolders(folder).Select(Path.GetFileName).ToList();
        if (kids.Any(k => NumberedObservation().IsMatch(k!))) return TelescopeKind.Vaonis;
        if (OriginFolder().IsMatch(name) || kids.Any(k => OriginFolder().IsMatch(k!))) return TelescopeKind.Origin;
        return null;
    }
}
