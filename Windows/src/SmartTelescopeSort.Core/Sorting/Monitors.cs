namespace SmartTelescopeSort.Core.Sorting;

/// <summary>How far a scan of the Capture Folder has got. Total is null while folders are still being found.</summary>
public readonly record struct ScanProgress(int Step, string Phase, int Done = 0, int? Total = null)
{
    public const int Steps = 5;

    public double? Fraction => Total is { } total ? (total > 0 ? Math.Min((double)Done / total, 1) : 0) : null;

    public string CountText => Total is { } total ? $"{Done} of {total}" : $"{Done} folders searched";
}

/// <summary>Passes scan progress to the window at most ten times a second, and lets the user stop the scan.</summary>
public sealed class ScanMonitor
{
    public sealed class CancelledException : Exception
    {
    }

    private readonly object _lock = new();
    private readonly Action<ScanProgress> _onProgress;
    private bool _cancelled;
    private DateTime _lastReport = DateTime.MinValue;

    public ScanMonitor(Action<ScanProgress> onProgress) => _onProgress = onProgress;

    public bool IsCancelled
    {
        get { lock (_lock) return _cancelled; }
    }

    public void Cancel()
    {
        lock (_lock) _cancelled = true;
    }

    public void CheckCancelled()
    {
        if (IsCancelled) throw new CancelledException();
    }

    /// <summary>`force` reports even within a tenth of a second of the last one, for the start of each step.</summary>
    public void Report(int step, string phase, int done = 0, int? total = null, bool force = false)
    {
        var now = DateTime.UtcNow;
        lock (_lock)
        {
            if (!force && (now - _lastReport).TotalSeconds < 0.1) return;
            _lastReport = now;
        }
        _onProgress(new ScanProgress(step, phase, done, total));
    }
}

/// <summary>Progress of the copy-then-delete steps of a sort: copying files or folders, or deleting the originals.</summary>
public readonly record struct TransferProgress(string Phase, int Done = 0, int Total = 0, string Item = "", bool Deleting = false)
{
    public double Fraction => Total > 0 ? Math.Min((double)Done / Total, 1) : 0;
}

public sealed class TransferMonitor
{
    private readonly object _lock = new();
    private readonly Action<TransferProgress> _onProgress;
    private bool _cancelled;
    private DateTime _lastReport = DateTime.MinValue;

    public TransferMonitor(Action<TransferProgress> onProgress) => _onProgress = onProgress;

    public bool IsCancelled
    {
        get { lock (_lock) return _cancelled; }
    }

    public void Cancel()
    {
        lock (_lock) _cancelled = true;
    }

    public void Report(TransferProgress progress, bool force = false)
    {
        var now = DateTime.UtcNow;
        lock (_lock)
        {
            if (!force && (now - _lastReport).TotalSeconds < 0.1) return;
            _lastReport = now;
        }
        _onProgress(progress);
    }
}

/// <summary>Lets the UI stop a running archive; the partial archive is deleted.</summary>
public sealed class ArchiveJob
{
    public sealed class CancelledException : Exception
    {
    }

    private volatile bool _cancelled;

    public bool IsCancelled => _cancelled;

    public void Cancel() => _cancelled = true;

    public void CheckCancelled()
    {
        if (_cancelled) throw new CancelledException();
    }
}
