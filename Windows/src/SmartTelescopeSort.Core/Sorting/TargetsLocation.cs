using System.Text.RegularExpressions;
using SmartTelescopeSort.Core.IO;

namespace SmartTelescopeSort.Core.Sorting;

/// <summary>Where Targets {year} folders live, and the note shown under the Target Folder (SortViewModel.targetsRoot).</summary>
public static partial class TargetsLocation
{
    [GeneratedRegex(@"^Targets \d{4}$")]
    private static partial Regex TargetsYear();

    private static PathRules R => PathRules.Host;

    /// <summary>
    /// The chosen Target Folder (or its parent when a Targets {year} folder itself was picked), else the Capture Folder.
    /// When that folder holds no Targets {year} folder, the nearest folder above it that does is used.
    /// </summary>
    public static string Resolve(string? chosenTarget, string captureFolder)
    {
        var folder = R.Normalize(chosenTarget ?? captureFolder);
        if (TargetsYear().IsMatch(R.LastComponent(folder))) return R.Parent(folder);
        return FolderHoldingTargets(folder) ?? folder;
    }

    /// <summary>
    /// The folder, or the nearest above it, holding a Targets {year} folder. Stops below the drive root on Windows and
    /// below top-level folders such as /Volumes elsewhere, as the Mac does.
    /// </summary>
    private static string? FolderHoldingTargets(string start)
    {
        var minimumDepth = R.IsWindows ? 1 : 2;
        var folder = start;
        while (R.Depth(folder) >= minimumDepth)
        {
            try
            {
                if (Directory.Exists(folder) && Directory.EnumerateDirectories(folder).Any(d => TargetsYear().IsMatch(Path.GetFileName(d))))
                    return folder;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
            }
            folder = R.Parent(folder);
        }
        return null;
    }

    /// <summary>Where sorted images really go, shown under the Target Folder; a warning when that isn't the folder chosen.</summary>
    public static (string Text, bool Warning)? Note(string? chosenTarget, string captureFolder)
    {
        var hasCapture = captureFolder.Length > 0;
        if (!hasCapture && chosenTarget is null) return null;
        var root = Resolve(chosenTarget, captureFolder);
        var destination = $"Sorted images go to {R.Combine(root, "Targets {year}/{object}")}";
        if (chosenTarget is null) return (destination + ".", false);
        var chosen = R.Normalize(chosenTarget);
        if (TargetsYear().IsMatch(R.LastComponent(chosen)) || R.AreSame(chosen, root)) return (destination + ".", false);
        var inside = hasCapture && R.IsSameOrInside(chosen, captureFolder);
        return (destination + (inside
            ? ". The folder chosen is inside the Capture Folder, so the folder above it that holds Targets {year} is used. Choose that folder to avoid confusion."
            : ". The folder chosen holds no Targets {year} folder, so the folder above it that does is used."), true);
    }
}
