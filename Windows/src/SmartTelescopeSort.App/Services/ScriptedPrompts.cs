using System.IO;
using SmartTelescopeSort.Core.Settings;

namespace SmartTelescopeSort.App.Services;

/// <summary>
/// Answers every question without a window, for test runs: `--auto-sort` on the command line. Each question and answer
/// is written to the log. Originals are never deleted: both "delete originals" questions are answered No unless
/// `deleteOriginals` is set, and every other destructive question is answered No / Leave / Keep All. Items too long for
/// the Recycle Bin are kept unless `deleteLongPaths` is set.
/// </summary>
public sealed class ScriptedPrompts : IPrompts
{
    private readonly TextWriter _log;
    private readonly bool _deleteOriginals;
    private readonly bool _deleteLongPaths;
    private readonly string? _backupFolder;
    private readonly string? _targetFolder;

    public ScriptedPrompts(TextWriter log, bool deleteOriginals = false, string? targetFolder = null, string? backupFolder = null,
                           bool deleteLongPaths = false)
    {
        _log = log;
        _deleteOriginals = deleteOriginals;
        _deleteLongPaths = deleteLongPaths;
        _targetFolder = targetFolder;
        _backupFolder = backupFolder;
    }

    private void Log(string kind, string title, string answer)
    {
        _log.WriteLine($"[{kind}] {title} → {answer}");
        _log.Flush();
    }

    public bool Confirm(string title, string message)
    {
        var yes = _deleteOriginals && (title.StartsWith("All moves are done", StringComparison.Ordinal) || title == "Are you sure?");
        Log("confirm", title, yes ? "Yes" : "No");
        return yes;
    }

    public int Choose(string title, string message, IReadOnlyList<string> buttons, int defaultIndex, int cancelIndex, int destructiveIndex = -1)
    {
        var index = title switch
        {
            "Back up before sorting?" => Index(buttons, "No, sort without backup", cancelIndex),
            "Sort eligible files?" => Index(buttons, "Sort now", cancelIndex),
            _ when title.EndsWith("can't go to the Recycle Bin", StringComparison.Ordinal) =>
                Index(buttons, _deleteLongPaths ? "Delete Permanently" : "Keep Them", cancelIndex),
            _ => Index(buttons, "Leave", cancelIndex),
        };
        Log("choose", title, buttons[index]);
        return index;
    }

    private static int Index(IReadOnlyList<string> buttons, string title, int fallback)
    {
        for (var i = 0; i < buttons.Count; i++)
            if (buttons[i] == title) return i;
        return fallback;
    }

    public void Inform(string title, string message) => Log("inform", title, "OK");

    public string? AskBackupName(string title, string message, string suggestion, string placeholder)
    {
        Log("backup-name", title, suggestion);
        return suggestion;
    }

    public Dictionary<string, string>? AskNames(string title, string message, IReadOnlyList<NameRequest> requests, IReadOnlyList<string> choices,
                                                string okTitle, string cancelTitle)
    {
        var names = requests.ToDictionary(r => r.Key, r => r.Scanned ?? r.Suggestion);
        Log("names", title, string.Join("; ", names.Select(p => $"{p.Key}={p.Value}")));
        return names;
    }

    public (bool Json, bool Astrometry)? AskHeld(string title, string message, string? jsonLabel, string? astrometryLabel)
    {
        Log("held", title, "Keep All");
        return null;
    }

    public string? ChooseFolder(string title, string? start)
    {
        Log("folder", title, "cancel");
        return null;
    }

    public (string Path, bool SaveAsDefault)? ChooseLibraryFolder(LibraryFolder folder, string? start)
    {
        var path = folder == LibraryFolder.Originals ? _targetFolder : _backupFolder;
        Log("library-folder", folder.Title(), path ?? "cancel");
        return path is null ? null : (path, false);
    }

    public IDisposable ShowProgress(ProgressKind kind)
    {
        Log("progress", kind.ToString(), "shown");
        return new Done(() => Log("progress", kind.ToString(), "closed"));
    }

    private sealed class Done : IDisposable
    {
        private readonly Action _done;

        public Done(Action done) => _done = done;

        public void Dispose() => _done();
    }
}
