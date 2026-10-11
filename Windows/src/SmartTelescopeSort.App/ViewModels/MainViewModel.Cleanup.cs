using SmartTelescopeSort.App.Services;
using SmartTelescopeSort.Core.IO;
using SmartTelescopeSort.Core.Sorting;

namespace SmartTelescopeSort.App.ViewModels;

public enum SetAsideKind
{
    PlateSolves,
    Calibration,
}

public sealed partial class MainViewModel
{
    private static string Noun(SetAsideKind kind) => kind == SetAsideKind.PlateSolves ? "plate-solve folder" : "calibration folder";

    private static string Explanation(SetAsideKind kind) => kind == SetAsideKind.PlateSolves
        ? "Plate-solve frames (astrometry.jpeg) the telescope took while pointing and guiding are kept out of the Target Folder:"
        : "Lights, Darks, Dark Flats, Flats, Bias and Master* folders are kept out of the Target Folder:";

    private static List<SetAsideFolder> FoldersOf(SetAsideKind kind, string root) =>
        kind == SetAsideKind.PlateSolves ? CaptureSorter.PlateSolveFolders(root) : CaptureSorter.CalibrationFolders(root);

    /// <summary>
    /// Plate-solve moves with every object named, asking in one list for the sessions no folder names. Unchecked
    /// sessions are left out; null when the user leaves them all.
    /// </summary>
    private List<PlateSolveMove>? NamedPlateSolveMoves(IReadOnlyList<SetAsideFolder> folders)
    {
        var moves = CaptureSorter.PlateSolveMoves(folders, SourcePath);
        var unnamed = moves.Where(m => m.Object is null).GroupBy(m => m.Session).ToDictionary(g => g.Key, g => g.ToList());
        if (unnamed.Count == 0) return moves;
        var requests = unnamed.Keys.OrderBy(k => k, Core.Common.NaturalComparer.Instance).Select(session =>
        {
            var group = unnamed[session];
            return new NameRequest(session, group[0].Path, $"{group.Count} folder(s) · {group.Sum(m => m.Images)} image(s)", group[0].SessionDate);
        }).ToList();
        var choices = unnamed.Values.SelectMany(g => g).Select(m => m.Year).Distinct()
            .SelectMany(year => FolderNames(System.IO.Path.Combine(TargetsRoot, $"Targets {year}")));
        var names = Prompts.AskNames($"Name the {requests.Count} plate-solve session(s) with no object name",
            "No folder names a DSO or other celestial object for these plate solves. Each is filled in with its date; keep it, "
            + $"pick an object already in Targets {{year}}, or type a name. They go to Targets {{year}}\\{{name}}\\{CaptureSorter.PlateSolvesFolderName}. "
            + "Uncheck a session to leave it in the Capture Folder.",
            requests, SortedChoices(choices), "Move All", "Leave All Plate Solves");
        if (names is null) return null;
        var result = new List<PlateSolveMove>();
        foreach (var move in moves)
        {
            if (move.Object is not null) result.Add(move);
            else if (names.TryGetValue(move.Session, out var name)) result.Add(move with { Object = name });
        }
        return result;
    }

    /// <summary>
    /// Asks whether to move, leave or delete one kind of set-aside folder. Move copies the folders and adds them to the
    /// originals offered for deletion at the end of the sort.
    /// </summary>
    public async Task AskAboutSetAsideFoldersAsync(SetAsideKind kind)
    {
        var source = SourcePath;
        var folders = FoldersOf(kind, source);
        if (folders.Count == 0) return;
        var noun = folders.Count == 1 ? Noun(kind) : Noun(kind) + "s";
        const int shown = 10;
        var lines = folders.Take(shown).Select(f => $"• {f.Path}: {Describe(new[] { f.Images })}");
        var message = Explanation(kind) + "\n"
            + string.Join("\n", lines)
            + (folders.Count > shown ? $"\n…and {folders.Count - shown} more ({Describe(folders.Select(f => f.Images))} in all)" : "")
            + (kind == SetAsideKind.PlateSolves
                ? $"\n\nMove puts each one with its object's images in Targets {{year}}\\{{object}}\\{CaptureSorter.PlateSolvesFolderName}\\{{session}}. "
                  + "Or leave them in the Capture Folder, or delete them (they go to the Recycle Bin)."
                : "\n\nMove them to a folder you choose, leave them in the Capture Folder, or delete them (they go to the Recycle Bin).");
        var answer = Prompts.Choose($"{folders.Count} {noun} {(folders.Count == 1 ? "was" : "were")} not sorted", message,
            new[] { kind == SetAsideKind.PlateSolves ? "Move to Targets" : "Move…", "Leave", "Delete" }, defaultIndex: 1, cancelIndex: 1, destructiveIndex: 2);

        var paths = folders.Select(f => f.Path).ToList();
        var left = $" Left {folders.Count} {noun} in the Capture Folder.";
        switch (answer)
        {
            case 0 when kind == SetAsideKind.PlateSolves:
            {
                if (NamedPlateSolveMoves(folders) is not { } moves)
                {
                    Status += left;
                    break;
                }
                var targets = TargetsRoot;
                var (result, _) = await RunTransferAsync("Copying plate solves", monitor => CaptureSorter.CopyPlateSolves(moves, source, targets, monitor));
                _pendingOriginals.AddRange(result.Copied);
                Status += $" Copied {result.Copied.Count} plate-solve folder(s) in with their images: Targets {{year}}\\{{object}}\\{CaptureSorter.PlateSolvesFolderName}."
                          + (result.Failed.Count == 0 ? "" : $" {result.Failed.Count} couldn't be copied.");
                return;
            }
            case 0:
            {
                var start = TargetFolderPath ?? R.Parent(source);
                if (Prompts.ChooseFolder($"Where should the {Noun(kind)}s go? Each folder keeps its path from the Capture Folder, so folders with the same name don't collide.",
                        start) is not { } destination)
                {
                    Status += left;
                    break;
                }
                var (result, _) = await RunTransferAsync($"Copying {Noun(kind)}s",
                    monitor => CaptureSorter.CopySetAsideFolders(paths, source, destination, monitor));
                _pendingOriginals.AddRange(result.Copied);
                Status += $" Copied {result.Copied.Count} {Noun(kind)}(s) to {destination}."
                          + (result.Failed.Count == 0 ? "" : $" {result.Failed.Count} couldn't be copied.");
                return;
            }
            case 2:
            {
                var confirm = Prompts.Choose($"Delete {folders.Count} {noun}?", "They go to the Recycle Bin with everything inside them.",
                    new[] { "Delete", "Cancel" }, defaultIndex: 1, cancelIndex: 1, destructiveIndex: 0);
                if (confirm != 0)
                {
                    Status += left;
                    break;
                }
                var (permanent, keptLong) = await AskAboutLongPathsAsync(paths.Select(p => R.Combine(source, p)).ToList());
                FolderCleanup result;
                using (FileOps.AllowPermanentDelete(permanent))
                {
                    if (kind == SetAsideKind.PlateSolves)
                    {
                        result = CaptureSorter.TrashCaptureFolders(paths, source, new HashSet<string>(), new DeletePermissions(true, true));
                    }
                    else
                    {
                        result = CaptureSorter.TrashCaptureFolders(paths, source, CaptureSorter.CalibrationDisposable, WithoutAstrometry);
                        var held = result.Held;
                        result.Removed += AskToDeleteHeld(held, offerAstrometry: false,
                            allowing => CaptureSorter.TrashCaptureFolders(held.Keys.ToList(), source, CaptureSorter.CalibrationDisposable, allowing));
                    }
                }
                Status += $" Deleted {result.Removed} {Noun(kind)}(s)." + DescribeKept(result.Kept) + LongPathsKept(keptLong);
                break;
            }
            default:
                Status += left;
                break;
        }
        PlateSolveFolders = CaptureSorter.PlateSolveFolders(source);
        CalibrationFolders = CaptureSorter.CalibrationFolders(source);
    }

    // MARK: Finished folders

    /// <summary>Capture folders a sort left behind because they still hold images, with counts by extension.</summary>
    public Dictionary<string, Dictionary<string, int>> KeptFolders { get; private set; } = new();

    /// <summary>File types holding the leftovers that aren't checked under Files to Move.</summary>
    public List<SortFileType> KeptUnselectedTypes
    {
        get
        {
            var extensions = KeptFolders.Values.SelectMany(c => c.Keys).ToHashSet();
            return SortFileTypes.All.Where(t => !_fileTypes.Contains(t) && t.Extensions().Overlaps(extensions)).ToList();
        }
    }

    public string KeptFoldersMessage
    {
        get
        {
            var lines = KeptFolders.Keys.OrderBy(k => k, StringComparer.Ordinal).Select(k => $"• {k}: {Describe(new[] { KeptFolders[k] })}");
            var types = string.Join(", ", KeptUnselectedTypes.Select(t => t.Label()));
            return "Everything selected has been sorted out of:\n" + string.Join("\n", lines) + "\n\n"
                   + (types.Length == 0 ? "" : $"{types} isn't checked under Files to Move, so those images are still inside. ")
                   + "Yes moves the folder and the images left in it to the Recycle Bin; you're asked about JSON files, and a folder holding other files "
                   + "(e.g. .afphoto) is kept. No leaves it in the Capture Folder.";
        }
    }

    public async Task AskAboutFinishedFoldersAsync()
    {
        KeptFolders = CaptureSorter.LeftoverImages(FinishedCaptureNames, SourcePath);
        if (KeptFolders.Count == 0) return;
        var unselected = KeptUnselectedTypes;
        var buttons = new List<string> { "Yes" };
        if (unselected.Count > 0) buttons.Add($"Sort {string.Join(", ", unselected.Select(t => t.Label()))} First");
        buttons.Add("No");
        var answer = Prompts.Choose(KeptFolders.Count == 1 ? "Delete finished folder?" : $"Delete {KeptFolders.Count} finished folders?",
            KeptFoldersMessage, buttons, defaultIndex: buttons.Count - 1, cancelIndex: buttons.Count - 1, destructiveIndex: 0);
        if (answer == 0) await DeleteKeptFoldersAsync();
        else if (answer == buttons.Count - 1) KeepFinishedFolders();
        else await SortKeptTypesAsync();
    }

    private async Task DeleteKeptFoldersAsync()
    {
        var names = KeptFolders.Keys.ToList();
        KeptFolders = new Dictionary<string, Dictionary<string, int>>();
        var source = SourcePath;
        var (permanent, keptLong) = await AskAboutLongPathsAsync(names.Select(n => R.Combine(source, n)).ToList());
        FolderCleanup result;
        int removed;
        using (FileOps.AllowPermanentDelete(permanent))
        {
            result = CaptureSorter.TrashCaptureFolders(names, source, null, WithoutAstrometry);
            removed = result.Removed + AskToDeleteHeld(result.Held, offerAstrometry: false,
                allowing => CaptureSorter.TrashCaptureFolders(result.Held.Keys.ToList(), source, null, allowing));
        }
        var otherKept = names.Count - removed - result.Kept.Count - keptLong;
        await RefreshAsync(() => Status = $"Moved {removed} finished capture folder(s) to the Recycle Bin."
            + DescribeKept(result.Kept)
            + (otherKept > 0 ? $" {otherKept} kept." : "")
            + LongPathsKept(keptLong));
    }

    private void KeepFinishedFolders()
    {
        Status = $"Left {KeptFolders.Count} finished capture folder(s) in the Capture Folder.";
        KeptFolders = new Dictionary<string, Dictionary<string, int>>();
    }

    private async Task SortKeptTypesAsync()
    {
        var next = _fileTypes.Union(KeptUnselectedTypes).ToList();
        KeptFolders = new Dictionary<string, Dictionary<string, int>>();
        _fileTypes = next.ToHashSet();
        _settings.FileTypes = SortFileTypes.All.Where(_fileTypes.Contains).Select(t => t.RawValue()).OrderBy(r => r, StringComparer.Ordinal).ToList();
        SaveSettings();
        OnPropertiesChanged(nameof(TiffChecked), nameof(JpegChecked), nameof(FitsChecked), nameof(AllTypesChecked), nameof(FileTypesSummary));
        await RefreshAsync();
        if (PlannedCount > 0) await BeginSortFlowAsync();
    }

    private static string DescribeKept(Dictionary<string, Dictionary<string, int>> kept)
    {
        var others = kept.ToDictionary(p => p.Key, p => p.Value.Where(c => !CaptureSorter.KeepFolderExtensions.Contains(c.Key)).ToDictionary(c => c.Key, c => c.Value))
            .Where(p => p.Value.Count > 0).ToList();
        if (others.Count == 0) return "";
        var totals = new Dictionary<string, int>();
        foreach (var (_, counts) in others)
            foreach (var (ext, count) in counts) totals[ext] = totals.GetValueOrDefault(ext) + count;
        var kinds = string.Join(", ", totals.OrderByDescending(p => p.Value).Take(4).Select(p => $"{p.Value} .{p.Key}"));
        return $" {others.Count} folder(s) kept because they hold other files ({kinds}).";
    }

    /// <summary>
    /// Folders held back only by JSON or astrometry files the settings don't allow deleting: asks with a checkbox for
    /// each kind, then deletes those folders the answer allows through `retry`. Returns how many were removed.
    /// </summary>
    private int AskToDeleteHeld(Dictionary<string, ProtectedFiles> held, bool offerAstrometry, Func<DeletePermissions, FolderCleanup> retry)
    {
        var outer = held.Keys.Where(name => !held.Keys.Any(other => other.Length > 0 && name.Length > 0 && !string.Equals(other, name, R.Comparison) && R.IsSameOrInside(name, other)))
            .OrderBy(n => n, StringComparer.Ordinal).ToList();
        var json = outer.Sum(n => held[n].Json);
        var astrometry = outer.Sum(n => held[n].Astrometry);
        var askJson = json > 0 && !_deleteJson;
        var askAstrometry = astrometry > 0 && offerAstrometry && !_deleteAstrometry;
        if (!askJson && !askAstrometry) return 0;

        const int shown = 8;
        var message = string.Join("\n", outer.Take(shown).Select(name =>
                          {
                              var files = held[name];
                              return $"• {name}: " + string.Join(", ", new[]
                              {
                                  files.Json > 0 ? $"{files.Json} JSON" : null,
                                  files.Astrometry > 0 ? $"{files.Astrometry} astrometry" : null,
                              }.OfType<string>());
                          }))
                      + (outer.Count > shown ? $"\n…and {outer.Count - shown} more" : "")
                      + "\n\nCheck what may be deleted with these folders. A folder holding anything left unchecked is kept.";
        var answer = Prompts.AskHeld($"{outer.Count} emptied folder(s) still hold JSON or plate-solve files", message,
            askJson ? $"Delete {json} JSON file(s): observation, plan and session records" : null,
            askAstrometry ? $"Delete {astrometry} astrometry (plate-solve) file(s)" : null);
        if (answer is not { } checks) return 0;
        var allowing = new DeletePermissions(
            _deleteJson || (askJson && checks.Json),
            (_deleteAstrometry && offerAstrometry) || (askAstrometry && checks.Astrometry));
        return retry(allowing).Removed;
    }

    private static string Describe(IEnumerable<IReadOnlyDictionary<string, int>> counts)
    {
        var total = new Dictionary<string, int>();
        foreach (var c in counts)
            foreach (var (ext, n) in c) total[ext] = total.GetValueOrDefault(ext) + n;
        return string.Join(", ", total.OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => $"{p.Value} {p.Key.ToUpperInvariant()}"));
    }
}
