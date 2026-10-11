using System.Collections.ObjectModel;
using System.IO;
using System.Windows;
using System.Windows.Threading;
using SmartTelescopeSort.App.Services;
using SmartTelescopeSort.Core.Common;
using SmartTelescopeSort.Core.IO;
using SmartTelescopeSort.Core.Settings;
using SmartTelescopeSort.Core.Sorting;

namespace SmartTelescopeSort.App.ViewModels;

/// <summary>A row of the capture table.</summary>
public sealed class EntryRow
{
    public required CaptureEntry Entry { get; init; }
    public required string CaptureFolderText { get; init; }
    public required string Status { get; init; }
    public required string TargetPath { get; init; }

    public string Year => Entry.Year;
    public string Month => Entry.Month;
    public bool NeedsObjectName => Entry.NeedsObjectName;
    public string ObjectText => Entry.NeedsObjectName ? "Ask when sorting" : Entry.Object;
    public string ObjectHelp => Entry.NeedsObjectName
        ? $"No folder names a target. You'll be asked which object these images are of; the date {Entry.SessionDate} is the default."
        : Entry.Object;
    public int ImageFolders => Entry.ImageFolders;
    public int Files => Entry.Files;
    public string Formats => string.Join(", ", Entry.Formats);
    public string TargetFolder => $"Targets {Entry.Year}{Path.DirectorySeparatorChar}{Entry.Object}";
    public bool IsDuplicateStatus => Status.StartsWith("Duplicate", StringComparison.Ordinal) || Status.EndsWith("duplicates", StringComparison.Ordinal);
    public string StatusHelp => Status.Contains("uplicate", StringComparison.Ordinal) ? "Already in Targets. You'll be asked before these are deleted." : Status;

    public override string ToString() => AccessibleNames.CaptureRow(CaptureFolderText, ObjectText, Year, Month, Files, Status, TargetFolder);
}

public sealed record Choice(string Id, string Title)
{
    public override string ToString() => Title;
}

/// <summary>A coloured dot and its text; Color names a theme brush (Green, Red or Orange).</summary>
public sealed record StatusLight(string Text, string Color)
{
    public override string ToString() => Text;
}

/// <summary>
/// The Mac app's SortViewModel on Windows: the Capture Folder, Target Folder and Backup Storage, the scan and preview, and
/// the copy-check-delete sort flow with every question asked through IPrompts.
/// </summary>
public sealed partial class MainViewModel : Observable
{
    private static PathRules R => PathRules.Host;

    private readonly SettingsStore _store;
    private readonly AppSettings _settings;
    private readonly Dispatcher _dispatcher;

    public MainViewModel(IPrompts prompts, SettingsStore store, string? captures = null)
    {
        Prompts = prompts;
        _store = store;
        _settings = store.Load();
        _dispatcher = Application.Current?.Dispatcher ?? Dispatcher.CurrentDispatcher;
        _telescopeKind = TelescopeKinds.FromRaw(_settings.TelescopeKind) ?? TelescopeKind.Vaonis;
        if (_settings.FileTypes is { } raw) _fileTypes = raw.Select(SortFileTypes.FromRaw).OfType<SortFileType>().ToHashSet();
        _backupFormat = BackupFormats.FromRaw(_settings.BackupFormat);
        _deleteJson = _settings.DeleteJson;
        _deleteAstrometry = _settings.DeleteAstrometry;
        if (!string.IsNullOrWhiteSpace(captures)) _sourcePath = R.Normalize(Path.GetFullPath(captures));
        LoadLibraryFolders();
    }

    public IPrompts Prompts { get; set; }

    public AppSettings Settings => _settings;

    public void SaveSettings()
    {
        try
        {
            _store.Save(_settings);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Status = $"Settings couldn't be saved: {e.Message}";
        }
    }

    // MARK: Layout

    private TelescopeKind _telescopeKind;
    private bool _layoutDetected;

    public bool LayoutDetected
    {
        get => _layoutDetected;
        private set
        {
            if (Set(ref _layoutDetected, value)) OnPropertiesChanged(nameof(LayoutTitle), nameof(LayoutNote), nameof(LayoutDropHint), nameof(LayoutHeading));
        }
    }

    public TelescopeKind TelescopeKind
    {
        get => _telescopeKind;
        private set
        {
            if (!Set(ref _telescopeKind, value)) return;
            _settings.TelescopeKind = value.RawValue();
            SaveSettings();
            OnPropertiesChanged(nameof(LayoutTitle), nameof(LayoutNote), nameof(LayoutDropHint), nameof(LayoutHeading));
        }
    }

    public string LayoutTitle => LayoutDetected ? TelescopeKind.MenuTitle() : TelescopeKinds.OtherLayoutTitle;
    public string LayoutNote => LayoutDetected ? TelescopeKind.CompatibilityNote() : TelescopeKinds.OtherCompatibilityNote;
    public string LayoutDropHint => LayoutDetected ? TelescopeKind.DropHint() : TelescopeKinds.OtherDropHint;
    public string LayoutHeading => LayoutTitle + (LayoutDetected ? " · detected" : "");
    public string FirstHowItWorksLine => LayoutDropHint + " The layout is detected; Targets {year} folders are skipped.";

    // MARK: File types, permissions and backup format

    private HashSet<SortFileType> _fileTypes = SortFileTypes.Defaults.ToHashSet();

    public IReadOnlySet<SortFileType> FileTypes => _fileTypes;

    public void SetFileTypes(IEnumerable<SortFileType> types)
    {
        var next = types.ToHashSet();
        if (next.SetEquals(_fileTypes)) return;
        _fileTypes = next;
        _settings.FileTypes = SortFileTypes.All.Where(_fileTypes.Contains).Select(t => t.RawValue()).OrderBy(r => r, StringComparer.Ordinal).ToList();
        SaveSettings();
        OnPropertiesChanged(nameof(TiffChecked), nameof(JpegChecked), nameof(FitsChecked), nameof(AllTypesChecked), nameof(FileTypesSummary));
        _ = RefreshAsync();
    }

    private void Toggle(SortFileType type, bool on)
    {
        var next = _fileTypes.ToHashSet();
        if (on) next.Add(type);
        else next.Remove(type);
        SetFileTypes(next);
    }

    public bool TiffChecked { get => _fileTypes.Contains(SortFileType.Tiff); set => Toggle(SortFileType.Tiff, value); }
    public bool JpegChecked { get => _fileTypes.Contains(SortFileType.Jpeg); set => Toggle(SortFileType.Jpeg, value); }
    public bool FitsChecked { get => _fileTypes.Contains(SortFileType.Fits); set => Toggle(SortFileType.Fits, value); }

    public bool AllTypesChecked
    {
        get => _fileTypes.Count == SortFileTypes.All.Length;
        set => SetFileTypes(value ? SortFileTypes.All : Array.Empty<SortFileType>());
    }

    public string FileTypesSummary
    {
        get
        {
            var chosen = SortFileTypes.All.Where(_fileTypes.Contains).ToList();
            return chosen.Count == 0 ? "no file types" : string.Join(", ", chosen.Select(t => t.Label()));
        }
    }

    private bool _deleteJson;
    private bool _deleteAstrometry;

    public bool DeleteJson
    {
        get => _deleteJson;
        set
        {
            if (!Set(ref _deleteJson, value)) return;
            _settings.DeleteJson = value;
            SaveSettings();
        }
    }

    public bool DeleteAstrometry
    {
        get => _deleteAstrometry;
        set
        {
            if (!Set(ref _deleteAstrometry, value)) return;
            _settings.DeleteAstrometry = value;
            SaveSettings();
        }
    }

    private DeletePermissions Permissions => new(_deleteJson, _deleteAstrometry);

    /// <summary>The JSON setting, with astrometry never allowed: used where plate solves haven't been asked about.</summary>
    private DeletePermissions WithoutAstrometry => new(_deleteJson);

    private BackupFormat? _backupFormat;

    public IReadOnlyList<Choice> BackupChoices { get; } = new[] { new Choice("off", "Off") }
        .Concat(BackupFormats.All.Select(f => new Choice(f.RawValue(), $"{f.Label()} (.{f.FileExtension()})"))).ToList();

    public string BackupChoice
    {
        get => _backupFormat?.RawValue() ?? "off";
        set
        {
            var format = BackupFormats.FromRaw(value);
            if (format == _backupFormat) return;
            _backupFormat = format;
            _settings.BackupFormat = format?.RawValue() ?? "off";
            SaveSettings();
            OnPropertiesChanged(nameof(BackupChoice), nameof(BackupNote));
        }
    }

    public string BackupNote => _backupFormat is null
        ? "Sort asks; Yes makes a folder copy"
        : $"→ {FolderPath(LibraryFolder.Backup) ?? "Backup Storage (asked when you sort)"}";

    private bool _backupFailed;

    /// <summary>Shows the free zip and tarball app links under Backup.</summary>
    public bool BackupFailed
    {
        get => _backupFailed;
        private set => Set(ref _backupFailed, value);
    }

    public IReadOnlyList<(string Title, string Url)> ArchiverLinks => Core.Common.AppInfo.ArchiverLinks;

    // MARK: Library folders

    private readonly Dictionary<LibraryFolder, string> _libraryFolders = new();
    private readonly HashSet<LibraryFolder> _savedDefaults = new();
    private readonly Dictionary<LibraryFolder, string> _sessionFolders = new();
    private readonly HashSet<LibraryFolder> _askedThisSession = new();

    public string? FolderPath(LibraryFolder folder) => _libraryFolders.GetValueOrDefault(folder);

    public bool IsSavedDefault(LibraryFolder folder) => _savedDefaults.Contains(folder);

    public string? TargetFolderPath => FolderPath(LibraryFolder.Originals);
    public string? BackupFolderPath => FolderPath(LibraryFolder.Backup);
    public string TargetFolderText => TargetFolderPath ?? "Not set — Targets {year} go inside the Capture Folder";
    public string BackupFolderText => BackupFolderPath ?? "Not set";
    public bool TargetFolderSet => TargetFolderPath is not null;
    public bool BackupFolderSet => BackupFolderPath is not null;
    public string TargetFolderScope => IsSavedDefault(LibraryFolder.Originals) ? "Default" : "This session";
    public string BackupFolderScope => IsSavedDefault(LibraryFolder.Backup) ? "Default" : "This session";

    public void LoadLibraryFolders()
    {
        _libraryFolders.Clear();
        _savedDefaults.Clear();
        foreach (var folder in LibraryFolders.All)
        {
            if (_settings.Folder(folder) is { Length: > 0 } saved)
            {
                _libraryFolders[folder] = saved;
                _savedDefaults.Add(folder);
            }
            else if (_sessionFolders.TryGetValue(folder, out var session))
            {
                _libraryFolders[folder] = session;
            }
        }
        NotifyFoldersChanged();
    }

    private void NotifyFoldersChanged() => OnPropertiesChanged(
        nameof(TargetFolderPath), nameof(BackupFolderPath), nameof(TargetFolderText), nameof(BackupFolderText), nameof(TargetFolderSet),
        nameof(BackupFolderSet), nameof(TargetFolderScope), nameof(BackupFolderScope), nameof(TargetFolderNote), nameof(TargetFolderNoteIsWarning),
        nameof(HasTargetFolderNote), nameof(BackupNote), nameof(TargetFolderLight), nameof(BackupFolderLight));

    /// <summary>Sets a library folder without asking, e.g. from the command line.</summary>
    public void UseLibraryFolder(LibraryFolder folder, string path, bool saveAsDefault)
    {
        var full = R.Normalize(Path.GetFullPath(path));
        _libraryFolders[folder] = full;
        if (saveAsDefault)
        {
            _settings.SetFolder(folder, full);
            _savedDefaults.Add(folder);
            _sessionFolders.Remove(folder);
        }
        else
        {
            _sessionFolders[folder] = full;
        }
        SaveSettings();
        NotifyFoldersChanged();
    }

    /// <summary>Asks for any library folder with no default, once per session.</summary>
    public void AskLibraryFoldersIfNeeded()
    {
        foreach (var folder in LibraryFolders.All.Where(f => !_libraryFolders.ContainsKey(f) && !_askedThisSession.Contains(f)).ToList())
            ChooseLibraryFolder(folder, refresh: false);
    }

    public void ChooseLibraryFolder(LibraryFolder folder) => ChooseLibraryFolder(folder, refresh: true);

    private void ChooseLibraryFolder(LibraryFolder folder, bool refresh)
    {
        _askedThisSession.Add(folder);
        var capture = HasCaptureFolder ? SourcePath : null;
        var start = FolderPath(folder) ?? (folder == LibraryFolder.Originals ? capture : capture is null ? null : R.Parent(capture));
        if (Prompts.ChooseLibraryFolder(folder, start) is not { } choice)
        {
            if (FolderPath(folder) is null)
                Status = folder == LibraryFolder.Originals
                    ? "Target Folder not set — Targets {year} folders go inside the Capture Folder."
                    : $"{folder.Title()} not set.";
            return;
        }
        _libraryFolders[folder] = R.Normalize(choice.Path);
        if (choice.SaveAsDefault)
        {
            _settings.SetFolder(folder, _libraryFolders[folder]);
            _savedDefaults.Add(folder);
            _sessionFolders.Remove(folder);
        }
        else
        {
            _settings.SetFolder(folder, null);
            _savedDefaults.Remove(folder);
            _sessionFolders[folder] = _libraryFolders[folder];
        }
        SaveSettings();
        NotifyFoldersChanged();
        if (refresh) _ = RefreshAsync();
    }

    /// <summary>Where Targets {year} folders live (TargetsLocation.Resolve).</summary>
    public string TargetsRoot => TargetsLocation.Resolve(TargetFolderPath, SourcePath.Length > 0 ? SourcePath : TargetFolderPath ?? "");

    private (string Text, bool Warning)? Note => TargetsLocation.Note(TargetFolderPath, SourcePath);
    public string TargetFolderNote => Note?.Text ?? "";
    public bool TargetFolderNoteIsWarning => Note?.Warning ?? false;
    public bool HasTargetFolderNote => Note is not null;

    // MARK: Capture Folder and scan state

    private string _sourcePath = "";

    public string SourcePath
    {
        get => _sourcePath;
        private set
        {
            if (!Set(ref _sourcePath, value)) return;
            OnPropertiesChanged(nameof(HasCaptureFolder), nameof(CaptureFolderText), nameof(CaptureLight), nameof(TargetFolderNote),
                nameof(TargetFolderNoteIsWarning), nameof(HasTargetFolderNote));
        }
    }

    public bool HasCaptureFolder => SourcePath.Length > 0;

    public string CaptureFolderText => HasCaptureFolder ? SourcePath : "Not chosen — click Choose… to pick the folder where your images are";

    private bool _sourceAvailable;

    public bool SourceAvailable
    {
        get => _sourceAvailable;
        private set
        {
            if (Set(ref _sourceAvailable, value)) OnPropertyChanged(nameof(CaptureLight));
        }
    }

    public StatusLight CaptureLight => !HasCaptureFolder ? new("No Capture Folder chosen", "Red")
        : SourceAvailable ? new("Capture Folder available", "Green") : new("Capture Folder unavailable", "Orange");
    public StatusLight TargetFolderLight => TargetFolderSet ? new("Target Folder selected", "Green") : new("Target Folder not selected", "Red");
    public StatusLight BackupFolderLight => BackupFolderSet ? new("Backup Storage selected", "Green") : new("Backup Storage not selected", "Red");

    private string _excluded = "Targets …";

    public string ExcludedText => $"{_excluded} folders are skipped.";

    public ObservableCollection<Choice> Years { get; } = new() { new Choice("all", "All years") };

    public IReadOnlyList<Choice> Months { get; } = new[]
    {
        new Choice("all", "All months"), new Choice("01", "January"), new Choice("02", "February"), new Choice("03", "March"),
        new Choice("04", "April"), new Choice("05", "May"), new Choice("06", "June"), new Choice("07", "July"), new Choice("08", "August"),
        new Choice("09", "September"), new Choice("10", "October"), new Choice("11", "November"), new Choice("12", "December"),
    };

    /// <summary>
    /// Updates Years in place: clearing the list would drop the year box's selection, and it doesn't come back when
    /// SelectedYear is raised again, leaving the box blank.
    /// </summary>
    private void SyncYears(IReadOnlyList<string> years)
    {
        var wanted = years.Prepend("all").ToList();
        for (var i = Years.Count - 1; i >= 0; i--)
            if (!wanted.Contains(Years[i].Id)) Years.RemoveAt(i);
        for (var i = 0; i < wanted.Count; i++)
            if (i >= Years.Count || Years[i].Id != wanted[i])
                Years.Insert(i, new Choice(wanted[i], wanted[i] == "all" ? "All years" : wanted[i]));
        while (Years.Count > wanted.Count) Years.RemoveAt(Years.Count - 1);
    }

    private string _selectedYear = "all";
    private string _selectedMonth = "all";
    private bool _applyingScan;

    public string SelectedYear
    {
        get => _selectedYear;
        set
        {
            if (value is null || !Set(ref _selectedYear, value)) return;
            if (!_applyingScan) _ = RefreshAsync();
        }
    }

    public string SelectedMonth
    {
        get => _selectedMonth;
        set
        {
            if (value is null || !Set(ref _selectedMonth, value)) return;
            _ = RefreshAsync();
        }
    }

    private IReadOnlyList<CaptureEntry> _entries = Array.Empty<CaptureEntry>();
    private IReadOnlyList<SortPlanItem> _planItems = Array.Empty<SortPlanItem>();
    private SortSummary _summary = new();
    private Dictionary<string, string> _entryStatus = new();

    public IReadOnlyList<CaptureEntry> Entries => _entries;
    public IReadOnlyList<SortPlanItem> PlanItems => _planItems;
    public SortSummary Summary => _summary;
    public IReadOnlyList<EntryRow> Rows { get; private set; } = Array.Empty<EntryRow>();

    public List<SetAsideFolder> CalibrationFolders { get; private set; } = new();
    public List<SetAsideFolder> PlateSolveFolders { get; private set; } = new();

    private string _status = "Ready.";

    public string Status
    {
        get => _status;
        set => Set(ref _status, value);
    }

    private bool _isBusy;

    public bool IsBusy
    {
        get => _isBusy;
        private set
        {
            if (Set(ref _isBusy, value)) OnPropertiesChanged(nameof(CanReview), nameof(CanSort), nameof(CanChangeFolders));
        }
    }

    public bool CanChangeFolders => !IsBusy && !IsBackingUp;

    // MARK: Plan summaries (the Mac's computed properties)

    public List<string> MissingYears => _entries.Where(e => !e.TargetExists).Select(e => e.Year).Distinct().OrderBy(y => y, StringComparer.Ordinal).ToList();
    public string? MissingYear => MissingYears.FirstOrDefault();
    public bool HasMissingYear => MissingYear is not null;
    public string MissingYearTitle => $"Targets {MissingYear} does not exist yet.";
    public string CreateMissingYearButton => $"Create Targets {MissingYear}";

    public int PlannedCount => _summary.Move;
    public int ActionableCount => _summary.Move + _summary.Duplicates;
    public List<SortPlanItem> DuplicateItems => _planItems.Where(p => p.IsDuplicate).ToList();

    public string DuplicatePrompt
    {
        get
        {
            var folders = DuplicateItems.Select(i => i.CaptureFolder).Distinct().Count();
            return $"{_summary.Duplicates} image file(s) in {folders} capture folder(s) are byte-for-byte copies of files in Targets. Delete them from the "
                + "Capture Folder? They go to the Recycle Bin, the copies in the Target Folder are not touched, and capture folders left with no "
                + "images to sort are removed.";
        }
    }

    public static string StatusText(IReadOnlyCollection<SortPlanItem> items)
    {
        var duplicates = items.Count(i => i.IsDuplicate);
        if (duplicates == items.Count) return duplicates == 1 ? "Duplicate" : $"{duplicates} duplicates";
        var fresh = items.Count(i => i.Action == SortAction.Move);
        var parts = new List<string>();
        if (fresh > 0) parts.Add($"{fresh} new");
        if (duplicates > 0) parts.Add($"{duplicates} duplicate");
        return string.Join(" · ", parts);
    }

    private string Capture(string name) => name.Length == 0 ? SourcePath : R.Combine(SourcePath, name);

    public List<string> SpentCaptureNames => _entries.GroupBy(e => e.CaptureFolder)
        .Where(g => g.Key.Length > 0 && g.All(e => e.Files == 0) && !CaptureSorter.HoldsImages(Capture(g.Key)))
        .Select(g => g.Key).OrderBy(n => n, StringComparer.Ordinal).ToList();

    /// <summary>Capture folders with nothing left to sort for the checked types that still hold other images.</summary>
    public List<string> FinishedCaptureNames
    {
        get
        {
            var active = _entries.Where(e => e.Files > 0).Select(e => e.CaptureFolder).ToHashSet();
            return _entries.GroupBy(e => e.CaptureFolder)
                .Where(g => g.Key.Length > 0
                            && !active.Any(a => !string.Equals(a, g.Key, R.Comparison) && R.IsSameOrInside(Capture(a), Capture(g.Key)))
                            && g.All(e => e.Files == 0) && CaptureSorter.HoldsImages(Capture(g.Key)))
                .Select(g => g.Key).OrderBy(n => n, StringComparer.Ordinal).ToList();
        }
    }

    public bool CanSortOrCleanup => ActionableCount > 0 || SpentCaptureNames.Count > 0 || FinishedCaptureNames.Count > 0;

    public bool OnlyFinishedFolders => ActionableCount == 0 && SpentCaptureNames.Count == 0 && FinishedCaptureNames.Count > 0;

    public bool CanReview => !IsBusy && (_planItems.Count > 0 || _entries.Count > 0);

    public bool CanSort => CanSortOrCleanup && !IsBusy && !IsBackingUp;

    public string PlanBarText
    {
        get
        {
            if (OnlyFinishedFolders)
                return $"{FinishedCaptureNames.Count} finished capture folder(s): nothing checked is left to sort, but other images remain.";
            if (ActionableCount == 0 && SpentCaptureNames.Count > 0)
                return $"{SpentCaptureNames.Count} emptied capture folder(s) ready to delete in the Capture Folder.";
            if (PlannedCount == 0 && _summary.Duplicates > 0)
                return $"All {_summary.Duplicates} file(s) are duplicates already in Targets. Delete duplicates asks before removing anything.";
            return $"{PlannedCount} files eligible: {_summary.Move} to move."
                   + (_summary.Duplicates > 0 ? $" {_summary.Duplicates} duplicate(s) already in Targets." : "");
        }
    }

    public bool PlanBarIsWarning => !OnlyFinishedFolders && !(ActionableCount == 0 && SpentCaptureNames.Count > 0) && PlannedCount == 0 && _summary.Duplicates > 0;

    public string SortButtonTitle => OnlyFinishedFolders ? "Delete finished folders…"
        : ActionableCount == 0 && SpentCaptureNames.Count > 0 ? "Remove empty captures"
        : PlannedCount == 0 && _summary.Duplicates > 0 ? "Delete duplicates…" : "Sort eligible files";

    public string RowsHeading => $"{Rows.Count} capture rows found";
    public int TotalFiles => _entries.Sum(e => e.Files);

    private void NotifyPlanChanged() => OnPropertiesChanged(
        nameof(Entries), nameof(PlanItems), nameof(Summary), nameof(Rows), nameof(MissingYear), nameof(HasMissingYear), nameof(MissingYearTitle),
        nameof(CreateMissingYearButton), nameof(PlannedCount), nameof(ActionableCount), nameof(CanSortOrCleanup), nameof(OnlyFinishedFolders),
        nameof(CanReview), nameof(CanSort), nameof(PlanBarText), nameof(PlanBarIsWarning), nameof(SortButtonTitle), nameof(RowsHeading),
        nameof(TotalFiles), nameof(ExcludedText));

    // MARK: Scanning

    private sealed class ScanOutput
    {
        public TelescopeKind? Detected { get; set; }
        public IReadOnlyList<CaptureEntry> Entries { get; set; } = Array.Empty<CaptureEntry>();
        public IReadOnlyList<string> Years { get; set; } = Array.Empty<string>();
        public string Excluded { get; set; } = "Targets …";
        public bool SourceAvailable { get; set; }
        public IReadOnlyList<SortPlanItem> Plans { get; set; } = Array.Empty<SortPlanItem>();
        public SortSummary Summary { get; set; } = new();
        public List<SetAsideFolder> Calibration { get; set; } = new();
        public List<SetAsideFolder> PlateSolves { get; set; } = new();
        public string? Error { get; set; }
        public bool Cancelled { get; set; }
    }

    private ScanProgress? _scanProgress;

    public ScanProgress? ScanProgress
    {
        get => _scanProgress;
        private set => Set(ref _scanProgress, value);
    }

    public DateTime ScanStarted { get; private set; } = DateTime.Now;

    private ScanMonitor? _scanMonitor;
    private int _scanGeneration;

    public void CancelScan() => _scanMonitor?.Cancel();

    /// <summary>
    /// Scans the Capture Folder in the background with the progress window up, then runs `then` with the new plan in
    /// place. Nothing is scanned until a Capture Folder has been chosen.
    /// </summary>
    public async Task RefreshAsync(Action? then = null)
    {
        if (!HasCaptureFolder)
        {
            Status = "Choose a Capture Folder to start: click Choose… next to Capture Folder.";
            return;
        }
        var generation = ++_scanGeneration;
        _scanMonitor?.Cancel();
        var monitor = new ScanMonitor(progress => _dispatcher.BeginInvoke(() =>
        {
            if (generation == _scanGeneration && ScanProgress is not null) ScanProgress = progress;
        }));
        _scanMonitor = monitor;
        var root = SourcePath;
        var targets = TargetsRoot;
        var year = SelectedYear == "all" ? null : SelectedYear;
        var month = SelectedMonth == "all" ? null : SelectedMonth;
        var kind = TelescopeKind;
        var extensions = SortFileTypes.ExtensionsOf(_fileTypes);
        IsBusy = true;
        SourceAvailable = Directory.Exists(root);
        Status = "Scanning the Capture Folder…";
        ScanStarted = DateTime.Now;
        ScanProgress = new ScanProgress(1, "Starting");
        ScanOutput output;
        using (Prompts.ShowProgress(ProgressKind.Scan))
        {
            output = await Task.Run(() => Scan(root, targets, year, month, kind, extensions, monitor));
        }
        if (generation != _scanGeneration) return;
        ScanProgress = null;
        _scanMonitor = null;
        IsBusy = false;
        if (output.Cancelled)
        {
            Status = "Scan cancelled. The list shows the last finished scan; click Refresh preview to scan again.";
            return;
        }
        Apply(output);
        then?.Invoke();
    }

    private static ScanOutput Scan(string root, string targets, string? year, string? month, TelescopeKind kind, HashSet<string> extensions, ScanMonitor monitor)
    {
        var output = new ScanOutput();
        CaptureSorter.SortExtensions = extensions;
        monitor.Report(1, "Detecting the telescope layout", force: true);
        try
        {
            output.Detected = TelescopeKinds.Detect(root);
            var result = CaptureSorter.Scan(output.Detected ?? kind, root, targets, year, month, monitor);
            output.Entries = result.Entries;
            output.Years = result.Years;
            output.Excluded = result.Excluded;
            output.SourceAvailable = Directory.Exists(root);
            (var plans, output.Summary) = CaptureSorter.Preview(result.Entries, monitor);
            output.Plans = plans;
            monitor.CheckCancelled();
            (output.PlateSolves, output.Calibration) = CaptureSorter.SetAsideFolders(root, monitor);
            monitor.CheckCancelled();
        }
        catch (ScanMonitor.CancelledException)
        {
            output.Cancelled = true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            output.Error = e.Message;
        }
        return output;
    }

    private void Apply(ScanOutput output)
    {
        LayoutDetected = output.Detected is not null;
        if (output.Detected is { } detected) TelescopeKind = detected;
        OnPropertyChanged(nameof(FirstHowItWorksLine));
        if (output.Error is { } error)
        {
            Status = error;
            _entries = Array.Empty<CaptureEntry>();
            _summary = new SortSummary();
            _planItems = Array.Empty<SortPlanItem>();
            _entryStatus = new Dictionary<string, string>();
            Rows = Array.Empty<EntryRow>();
            NotifyPlanChanged();
            return;
        }
        _entries = output.Entries;
        _excluded = output.Excluded;
        SourceAvailable = output.SourceAvailable;
        _summary = output.Summary;
        _planItems = output.Plans;
        _entryStatus = _planItems.GroupBy(p => p.EntryId).ToDictionary(g => g.Key, g => StatusText(g.ToList()));
        CalibrationFolders = output.Calibration;
        PlateSolveFolders = output.PlateSolves;
        var rootName = R.LastComponent(SourcePath);
        Rows = CaptureSorter.RowsToShow(_entries).Select(e => new EntryRow
        {
            Entry = e,
            CaptureFolderText = e.CaptureFolder.Length == 0 ? rootName : e.CaptureFolder,
            Status = _entryStatus.GetValueOrDefault(e.Id, ""),
            TargetPath = Path.Combine(TargetsRoot, e.TargetDirectory),
        }).ToList();

        _applyingScan = true;
        SyncYears(output.Years);
        if (SelectedYear != "all" && !output.Years.Contains(SelectedYear) && output.Years.Count > 0) SelectedYear = output.Years[0];
        else OnPropertyChanged(nameof(SelectedYear));
        _applyingScan = false;

        Status = !SourceAvailable ? "Capture Folder unavailable."
            : _fileTypes.Count == 0 ? "Check at least one file type under Files to Move."
            : $"Preview ready for {LayoutTitle} ({FileTypesSummary}) — no files have been moved."
              + (PlateSolveFolders.Count == 0 && CalibrationFolders.Count == 0 ? ""
                  : $" {PlateSolveFolders.Count} plate-solve and {CalibrationFolders.Count} calibration folder(s) are left out; you'll be asked about them after sorting.");
        NotifyPlanChanged();
    }

    /// <summary>After the launch window closes: ask for the Capture Folder, then any library folder without a default, then scan.</summary>
    public async Task StartAsync()
    {
        if (HasCaptureFolder)
        {
            AskLibraryFoldersIfNeeded();
            await RefreshAsync();
        }
        else
        {
            await ChooseSourceFolderAsync();
        }
    }

    public async Task ChooseSourceFolderAsync()
    {
        var start = HasCaptureFolder ? SourcePath : _settings.LastCaptureFolder;
        if (Prompts.ChooseFolder("Choose the Capture Folder: where your telescope's images are located", start) is not { } path)
        {
            if (!HasCaptureFolder) Status = "Choose a Capture Folder to start: click Choose… next to Capture Folder.";
            return;
        }
        SourcePath = R.Normalize(path);
        _settings.LastCaptureFolder = SourcePath;
        SaveSettings();
        AskLibraryFoldersIfNeeded();
        await RefreshAsync();
    }

    /// <summary>Opens the per-folder file list (does not move files).</summary>
    public async Task<bool> PrepareFilePlanAsync()
    {
        await RefreshAsync();
        if (_planItems.Count == 0 && _entries.Count == 0)
        {
            Status = "No plan yet — choose a Capture Folder that holds your telescope's images, then try again.";
            return false;
        }
        return true;
    }

    public async Task CreateMissingTargetAsync()
    {
        if (MissingYear is not { } year) return;
        if (!Prompts.Confirm("Create Targets folder?", $"Create Targets {year} in your Target Folder? No files will be moved.")) return;
        try
        {
            var created = CaptureSorter.CreateTargetsFolder(year, TargetsRoot);
            await RefreshAsync(() => Status = $"Created {created}. No capture files were moved.");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            Status = e.Message;
        }
    }
}
