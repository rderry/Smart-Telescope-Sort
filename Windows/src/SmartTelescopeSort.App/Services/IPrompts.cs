using SmartTelescopeSort.Core.Settings;
using SmartTelescopeSort.Core.Sorting;

namespace SmartTelescopeSort.App.Services;

/// <summary>
/// One row of the "name these folders" list: a checkbox, a name box and a detail line. Scanned is the folder-based label
/// the scan gave the row, which scripted runs keep so their results match the Mac sorter's.
/// </summary>
public sealed record NameRequest(string Key, string Label, string Detail, string Suggestion, string? Scanned = null);

public enum ProgressKind
{
    Scan,
    Transfer,
    Backup,
}

/// <summary>Every question the sort flow asks (the Mac's NSAlerts and panels), so a script can answer them in tests.</summary>
public interface IPrompts
{
    /// <summary>Yes / No with No as the default (the Mac's confirm).</summary>
    bool Confirm(string title, string message);

    /// <summary>A question with several buttons; returns the index pressed, or `cancelIndex` when the window is closed.</summary>
    int Choose(string title, string message, IReadOnlyList<string> buttons, int defaultIndex, int cancelIndex, int destructiveIndex = -1);

    void Inform(string title, string message);

    /// <summary>The backup's name; null when cancelled.</summary>
    string? AskBackupName(string title, string message, string suggestion, string placeholder);

    /// <summary>Names for the checked rows by key; null when cancelled. Every checked row has a non-blank name.</summary>
    Dictionary<string, string>? AskNames(string title, string message, IReadOnlyList<NameRequest> requests, IReadOnlyList<string> choices,
                                         string okTitle, string cancelTitle);

    /// <summary>Which held files may go: null for Keep All. A null label hides that checkbox.</summary>
    (bool Json, bool Astrometry)? AskHeld(string title, string message, string? jsonLabel, string? astrometryLabel);

    string? ChooseFolder(string title, string? start);

    (string Path, bool SaveAsDefault)? ChooseLibraryFolder(LibraryFolder folder, string? start);

    /// <summary>Shows the progress window for `kind` until disposed; the window reads its numbers from the view model.</summary>
    IDisposable ShowProgress(ProgressKind kind);
}
