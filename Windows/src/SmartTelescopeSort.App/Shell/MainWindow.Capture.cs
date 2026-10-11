using System.IO;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using SmartTelescopeSort.App.Dialogs;
using SmartTelescopeSort.App.Services;
using SmartTelescopeSort.App.ViewModels;
using SmartTelescopeSort.Core.Settings;

namespace SmartTelescopeSort.App.Shell;

/// <summary>
/// <c>--capture &lt;folder&gt;</c>: scans the Capture Folder, renders the window and each dialog with WPF's own
/// renderer (works without a desktop, e.g. over SSH) and exits. Nothing is sorted, moved or deleted.
/// </summary>
public partial class MainWindow
{
    private const int WsPopup = unchecked((int)0x80000000);
    private const int WsExToolWindow = 0x00000080;
    private const int WsExNoActivate = 0x08000000;

    private HwndSource? _captureHost;

    private async Task RunCaptureAsync(string folder)
    {
        Directory.CreateDirectory(folder);
        var log = new List<string>();
        try
        {
            if (_options.Width is int w && _options.Height is int h) MoveContentToCaptureHost(w, h);
        }
        catch (Exception ex)
        {
            log.Add($"HOST {ex.GetType().Name}: {ex.Message}");
        }

        _model.Prompts = new CapturePrompts();
        await _model.RefreshAsync();
        _model.Prompts = new WpfPrompts(() => _model);
        await Settle(800);
        var main = Save("01-main", RootGrid, Background);
        if (main is { PixelWidth: < StoreMinWidth } or { PixelHeight: < StoreMinHeight }) main = null;

        await CaptureWindow("02-review-file-plan", () => new PlanReviewWindow(_model) { Width = 1100, Height = 680 });
        await CaptureProgress("03-scan-progress", ProgressKind.Scan);
        await CaptureProgress("04-backup-progress", ProgressKind.Backup);
        await CaptureWindow("05-finished-folder", () => new MessageWindow("Delete finished folder?",
            "Everything selected has been sorted out of:\n• 2025-10-10_07-49-28_observation-M31: 12 JPG\n\n"
            + "JPG / JPEG isn't checked under Files to Move, so those images are still inside. "
            + "Yes moves the folder and the images left in it to the Recycle Bin; you're asked about JSON files, and a folder holding other files "
            + "(e.g. .afphoto) is kept. No leaves it in the Capture Folder.",
            new[] { "Yes", "Sort JPG / JPEG First", "No" }, 2, 2, 0));
        await CaptureProgress("06-sort-progress", ProgressKind.Transfer);
        await CaptureWindow("07-backup-offer", () => new MessageWindow("Back up before sorting?", _model.BackupOfferMessage,
            new[] { "Yes, back up first", "No, sort without backup", "Cancel" }, 0, 2));
        await CaptureWindow("08-delete-originals", () => new MessageWindow("All moves are done. Delete the original folders and files?",
            "51 image file(s) were copied and each copy was checked byte for byte against its original. The originals are still in the Capture Folder.\n\n"
            + "Yes deletes the originals. No keeps them; the next scan marks them Duplicate.",
            new[] { "Yes", "No" }, 1, 1, 0));
        await CaptureWindow("09-name-requests", () => new NameRequestsWindow("Name the 2 folder(s) with no object name",
            "No folder names a DSO or other celestial object for these images. Each is filled in with its date; keep it, "
            + "pick an object already in Targets {year}, or type a name. Uncheck a folder to leave its images in the Capture Folder.",
            new[]
            {
                new NameRequest("a", @"Backyard\2025-09-14", "18 image(s) · Targets 2025", "2025-09-14"),
                new NameRequest("b", @"Backyard\2025-09-21", "9 image(s) · Targets 2025", "2025-09-21"),
            },
            new[] { "M31", "M42", "NGC 7000" }, "Sort All", "Cancel Sort"));
        await CaptureWindow("10-target-folder", () => new LibraryFolderWindow(LibraryFolder.Originals, _model.TargetFolderPath ?? @"D:\Astro"));
        await CaptureWindow("11-assumptions", () => new AssumptionsWindow(_record, true));
        await CaptureWindow("12-credits", () => new CreditsWindow());
        await CaptureWindow("13-about", () => new AboutWindow());
        await CaptureWindow("14-manual", () => new ManualWindow { Width = 1040, Height = 760 });

        File.WriteAllLines(Path.Combine(folder, "capture.log"), log);
        _captureHost?.Dispose();
        Application.Current.Shutdown();

        async Task CaptureProgress(string name, ProgressKind kind)
        {
            _model.StageProgress(kind);
            await CaptureWindow(name, () => new ProgressWindow(_model, kind));
            _model.ClearStagedProgress();
        }

        async Task CaptureWindow(string name, Func<Window> create)
        {
            Window? window = null;
            try
            {
                window = create();
                window.Owner = null;
                window.ShowInTaskbar = false;
                window.ShowActivated = false;
                window.WindowStartupLocation = WindowStartupLocation.Manual;
                window.Left = -20000;
                window.Top = -20000;
                window.Show();
                await Settle(900);
                log.Add($"SIZE {name} {window.ActualWidth:0}x{window.ActualHeight:0}");
                if (VisualTreeHelper.GetChildrenCount(window) > 0 && VisualTreeHelper.GetChild(window, 0) is FrameworkElement frame
                    && Save(name, frame, window.Background) is { } shot && main is not null)
                    Write("store-" + name, OverMain(main, shot));
            }
            catch (Exception ex)
            {
                log.Add($"FAILED {name}: {ex.GetType().Name}: {ex.Message}");
            }
            finally
            {
                if (window is ProgressWindow progress) progress.Finish();
                else window?.Close();
            }
        }

        BitmapSource? Save(string name, FrameworkElement root, Brush background)
        {
            try
            {
                var bitmap = Snapshot(root, background);
                return Write(name, bitmap) ? bitmap : null;
            }
            catch (Exception ex)
            {
                log.Add($"FAILED {name}: {ex.GetType().Name}: {ex.Message}");
                return null;
            }
        }

        bool Write(string name, BitmapSource bitmap)
        {
            var file = Path.Combine(folder, name + ".png");
            try
            {
                var encoder = new PngBitmapEncoder();
                encoder.Frames.Add(BitmapFrame.Create(bitmap));
                using var stream = File.Create(file);
                encoder.Save(stream);
                log.Add($"SAVED {file} {bitmap.PixelWidth}x{bitmap.PixelHeight}");
                return true;
            }
            catch (Exception ex)
            {
                log.Add($"FAILED {file}: {ex.GetType().Name}: {ex.Message}");
                return false;
            }
        }
    }

    /// <summary>Microsoft Store desktop screenshots must be at least 1366×768.</summary>
    private const int StoreMinWidth = 1366;
    private const int StoreMinHeight = 768;

    /// <summary>A Store-size screenshot of a dialog: the dialog centered over the dimmed main window, as it appears in use.</summary>
    private static BitmapSource OverMain(BitmapSource main, BitmapSource dialog)
    {
        double width = main.PixelWidth, height = main.PixelHeight;
        var scale = Math.Min(1.0, Math.Min((width - 80) / dialog.PixelWidth, (height - 80) / dialog.PixelHeight));
        var place = new Rect((width - dialog.PixelWidth * scale) / 2, (height - dialog.PixelHeight * scale) / 2,
                             dialog.PixelWidth * scale, dialog.PixelHeight * scale);
        var surface = new DrawingVisual();
        using (var dc = surface.RenderOpen())
        {
            dc.DrawImage(main, new Rect(0, 0, width, height));
            dc.DrawRectangle(new SolidColorBrush(Color.FromArgb(150, 0, 0, 0)), null, new Rect(0, 0, width, height));
            dc.DrawRectangle(null, new Pen(new SolidColorBrush(Color.FromRgb(0x5A, 0x6E, 0xA0)), 2), Rect.Inflate(place, 1, 1));
            dc.DrawImage(dialog, place);
        }
        var bitmap = new RenderTargetBitmap(main.PixelWidth, main.PixelHeight, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(surface);
        return bitmap;
    }

    /// <summary>
    /// A resizable top-level window is clamped to the screen; a borderless popup is not, so captures can match the Mac
    /// window size whatever the PC's display.
    /// </summary>
    private void MoveContentToCaptureHost(int width, int height)
    {
        RootGrid.DataContext = DataContext;
        TextElement.SetForeground(RootGrid, Foreground);
        TextElement.SetFontFamily(RootGrid, FontFamily);
        TextElement.SetFontSize(RootGrid, FontSize);
        RootGrid.UseLayoutRounding = UseLayoutRounding;
        Content = null;
        var parameters = new HwndSourceParameters("Telescope Data Sort capture", width, height)
        {
            WindowStyle = WsPopup,
            ExtendedWindowStyle = WsExToolWindow | WsExNoActivate,
            PositionX = -20000,
            PositionY = -20000,
        };
        _captureHost = new HwndSource(parameters) { SizeToContent = SizeToContent.Manual };
        RootGrid.Width = width;
        RootGrid.Height = height;
        _captureHost.RootVisual = RootGrid;
    }

    private static Task Settle(int milliseconds)
    {
        var done = new TaskCompletionSource();
        var timer = new DispatcherTimer(DispatcherPriority.ApplicationIdle) { Interval = TimeSpan.FromMilliseconds(milliseconds) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            done.SetResult();
        };
        timer.Start();
        return done.Task;
    }

    private static BitmapSource Snapshot(FrameworkElement root, Brush background)
    {
        root.UpdateLayout();
        var dpi = VisualTreeHelper.GetDpi(root);
        var width = root.ActualWidth;
        var height = root.ActualHeight;
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(width * dpi.DpiScaleX), (int)Math.Ceiling(height * dpi.DpiScaleY),
            dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
        var surface = new DrawingVisual();
        using (var dc = surface.RenderOpen()) dc.DrawRectangle(background, null, new Rect(0, 0, width, height));
        bitmap.Render(surface);
        bitmap.Render(root);
        return bitmap;
    }

    /// <summary>Answers nothing during the capture scan: no windows, no folders asked for.</summary>
    private sealed class CapturePrompts : IPrompts
    {
        public bool Confirm(string title, string message) => false;
        public int Choose(string title, string message, IReadOnlyList<string> buttons, int defaultIndex, int cancelIndex, int destructiveIndex = -1) => cancelIndex;
        public void Inform(string title, string message) { }
        public string? AskBackupName(string title, string message, string suggestion, string placeholder) => null;
        public Dictionary<string, string>? AskNames(string title, string message, IReadOnlyList<NameRequest> requests, IReadOnlyList<string> choices, string okTitle, string cancelTitle) => null;
        public (bool Json, bool Astrometry)? AskHeld(string title, string message, string? jsonLabel, string? astrometryLabel) => null;
        public string? ChooseFolder(string title, string? start) => null;
        public (string Path, bool SaveAsDefault)? ChooseLibraryFolder(LibraryFolder folder, string? start) => null;
        public IDisposable ShowProgress(ProgressKind kind) => new Nothing();

        private sealed class Nothing : IDisposable
        {
            public void Dispose() { }
        }
    }
}
