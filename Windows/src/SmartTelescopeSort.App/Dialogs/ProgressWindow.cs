using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using SmartTelescopeSort.App.Services;
using SmartTelescopeSort.App.ViewModels;
using SmartTelescopeSort.Core.Common;
using SmartTelescopeSort.Core.Sorting;

namespace SmartTelescopeSort.App.Dialogs;

/// <summary>
/// The Mac's scan, transfer and backup progress sheets. Shown without blocking while the work runs in the background;
/// the main window is disabled until it closes. Closing it asks the work to stop, like the sheet's cancel button.
/// </summary>
public sealed class ProgressWindow : DialogWindow
{
    private readonly MainViewModel _model;
    private readonly ProgressKind _kind;
    private readonly DispatcherTimer _timer;
    private readonly TextBlock _title = Heading("");
    private readonly TextBlock _note = Paragraph("", 12);
    private readonly Border _noteCard;
    private readonly TextBlock _path = Paragraph("", 11, "LabelBrush");
    private readonly ProgressBar _bar = new() { Height = 8, Minimum = 0, Maximum = 1, Margin = new Thickness(0, 4, 0, 8) };
    private readonly TextBlock _left = new() { FontSize = 12, FontWeight = FontWeights.Medium };
    private readonly TextBlock _right = new() { FontSize = 12, FontWeight = FontWeights.Medium };
    private readonly TextBlock _item = new() { FontSize = 11, Foreground = Brush("LabelBrush"), TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 4, 0, 0) };
    private readonly TextBlock _clock = new() { FontSize = 11, Foreground = Brush("LabelBrush"), VerticalAlignment = VerticalAlignment.Center };
    private readonly Button _stop;
    private bool _finished;

    public ProgressWindow(MainViewModel model, ProgressKind kind) : base(Titles(kind), kind == ProgressKind.Transfer ? 600 : 580)
    {
        _model = model;
        _kind = kind;
        _left.FontFamily = _right.FontFamily = (System.Windows.Media.FontFamily)Application.Current.FindResource("AppFont");
        _item.FontFamily = (System.Windows.Media.FontFamily)Application.Current.FindResource("MonoFont");
        _path.TextTrimming = TextTrimming.CharacterEllipsis;
        _path.TextWrapping = TextWrapping.NoWrap;

        var panel = new StackPanel { Margin = new Thickness(24, 20, 24, 18) };
        panel.Children.Add(_title);
        _noteCard = new Border
        {
            Child = _note,
            Padding = new Thickness(10, 10, 10, 0),
            CornerRadius = new CornerRadius(8),
            Background = Brush("DestinationCardBrush"),
            Margin = new Thickness(0, 0, 0, 10),
        };
        if (kind == ProgressKind.Transfer) panel.Children.Add(_noteCard);
        else panel.Children.Add(_path);
        panel.Children.Add(_bar);
        var counts = new DockPanel();
        DockPanel.SetDock(_right, Dock.Right);
        counts.Children.Add(_right);
        counts.Children.Add(_left);
        panel.Children.Add(counts);
        if (kind != ProgressKind.Scan) panel.Children.Add(_item);

        _stop = MakeButton(kind switch { ProgressKind.Scan => "Cancel Scan", ProgressKind.Backup => "Cancel Backup", _ => "Stop" });
        _stop.IsCancel = true;
        _stop.Click += (_, _) => Stop();
        var footer = new DockPanel { Margin = new Thickness(0, 12, 0, 0) };
        DockPanel.SetDock(_stop, Dock.Right);
        footer.Children.Add(_stop);
        footer.Children.Add(_clock);
        panel.Children.Add(footer);
        if (kind != ProgressKind.Transfer)
        {
            var hint = Paragraph(kind == ProgressKind.Scan ? "Nothing is moved while scanning." : "Nothing is moved until the backup finishes and you confirm the sort.",
                10, "LabelBrush");
            hint.Margin = new Thickness(0, 8, 0, 0);
            panel.Children.Add(hint);
        }
        Content = panel;

        _timer = new DispatcherTimer(TimeSpan.FromMilliseconds(250), DispatcherPriority.Background, (_, _) => Update(), Dispatcher);
        Loaded += (_, _) =>
        {
            Update();
            _timer.Start();
        };
    }

    private static string Titles(ProgressKind kind) => kind switch
    {
        ProgressKind.Scan => "Scanning the Capture Folder",
        ProgressKind.Backup => "Backing up capture folders",
        _ => "Sorting",
    };

    /// <summary>Closes the window once the work is done (not a stop request).</summary>
    public void Finish()
    {
        _finished = true;
        _timer.Stop();
        Close();
    }

    private void Stop()
    {
        switch (_kind)
        {
            case ProgressKind.Scan:
                _model.CancelScan();
                break;
            case ProgressKind.Backup:
                _model.CancelBackup();
                break;
            default:
                _model.StopTransfer();
                break;
        }
        _stop.IsEnabled = false;
        _stop.Content = "Stopping…";
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        base.OnClosing(e);
        if (_finished) return;
        e.Cancel = true;
        Stop();
    }

    private static string Clock(TimeSpan span)
    {
        var s = Math.Max((int)Math.Round(span.TotalSeconds), 0);
        return $"{s / 60}:{s % 60:00}";
    }

    private void Update()
    {
        switch (_kind)
        {
            case ProgressKind.Scan:
            {
                var progress = _model.ScanProgress ?? new ScanProgress(1, "Starting");
                _title.Text = "Scanning the Capture Folder";
                _path.Text = _model.SourcePath;
                _bar.IsIndeterminate = progress.Fraction is null;
                if (progress.Fraction is { } fraction) _bar.Value = fraction;
                _left.Text = $"Step {progress.Step} of {ScanProgress.Steps}: {progress.Phase}";
                _right.Text = progress.CountText;
                _clock.Text = $"Elapsed {Clock(DateTime.Now - _model.ScanStarted)}";
                break;
            }
            case ProgressKind.Backup:
            {
                var progress = _model.BackupProgress ?? new ArchiveProgress { CurrentFile = "" };
                _title.Text = "Backing up capture folders";
                _path.Text = _model.BackupTitle;
                _bar.Value = progress.Fraction;
                _left.Text = $"{ByteSize.Format(progress.BytesDone)} of {ByteSize.Format(progress.BytesTotal)}";
                _right.Text = $"{progress.FilesDone} of {progress.FilesTotal} files · {(int)(progress.Fraction * 100)}%";
                _item.Text = string.IsNullOrEmpty(progress.CurrentFile) ? "Counting files…" : progress.CurrentFile;
                var elapsed = DateTime.Now - _model.BackupStarted;
                var text = $"Elapsed {Clock(elapsed)}";
                if (progress.Fraction is > 0.02 and < 1) text += $" · about {Clock(elapsed * ((1 - progress.Fraction) / progress.Fraction))} left";
                _clock.Text = text;
                break;
            }
            default:
            {
                var progress = _model.TransferProgress ?? new TransferProgress("Starting");
                var explanation = _model.TransferExplanation;
                _title.Text = explanation?.Title ?? (progress.Deleting ? progress.Phase : "Sorting: copy, check, then delete");
                _note.Text = explanation?.Note ?? (progress.Deleting
                    ? "You said Yes twice. Everything sorted is safe in Targets; these go to the Recycle Bin."
                    : "Copy then delete: each file is copied into the Target Folder and checked byte for byte against the original. "
                      + "Nothing is deleted now. When every move is done you're asked twice before the originals are deleted.");
                _bar.Value = progress.Fraction;
                _left.Text = progress.Phase;
                _right.Text = $"{progress.Done} of {progress.Total}";
                _item.Text = progress.Item.Length == 0 ? " " : progress.Item;
                _clock.Text = $"Elapsed {Clock(DateTime.Now - _model.TransferStarted)}";
                _stop.ToolTip = progress.Deleting ? "Stop deleting; the rest of the originals are kept." : "Stop copying; originals are never deleted without asking.";
                break;
            }
        }
    }
}
