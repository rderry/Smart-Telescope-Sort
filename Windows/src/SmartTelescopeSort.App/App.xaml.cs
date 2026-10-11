using System.IO;
using System.Windows;
using System.Windows.Threading;
using SmartTelescopeSort.App.Dialogs;
using SmartTelescopeSort.App.Platform;
using SmartTelescopeSort.App.Services;
using SmartTelescopeSort.App.Shell;
using SmartTelescopeSort.App.ViewModels;
using SmartTelescopeSort.Core.IO;
using SmartTelescopeSort.Core.Settings;

namespace SmartTelescopeSort.App;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        FileOps.Recycle = RecycleBin.Send;
        DispatcherUnhandledException += OnUnhandledException;

        var options = StartupOptions.Parse(e.Args);
        Directory.CreateDirectory(options.DataDir);
        if (options.AutoSortLog is { } log)
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            _ = AutoSortAsync(options, log);
            return;
        }
        var window = new MainWindow(options);
        MainWindow = window;
        window.Show();
    }

    /// <summary>A scripted scan and sort with no windows, for checking a build against the Mac's results.</summary>
    private async Task AutoSortAsync(StartupOptions options, string logPath)
    {
        var exitCode = 0;
        await using (var log = new StreamWriter(logPath, append: false))
        {
            try
            {
                var prompts = new ScriptedPrompts(log, options.DeleteOriginals, options.Targets, options.Backup, options.DeleteLongPaths);
                var model = new MainViewModel(prompts, new SettingsStore(options.DataDir), options.Captures);
                if (options.Targets is { } targets) model.UseLibraryFolder(LibraryFolder.Originals, targets, saveAsDefault: false);
                if (options.Backup is { } backup) model.UseLibraryFolder(LibraryFolder.Backup, backup, saveAsDefault: false);
                await model.RefreshAsync();
                log.WriteLine($"[scan] {model.Status}");
                log.WriteLine($"[plan] rows={model.Entries.Count} files={model.TotalFiles} move={model.Summary.Move} duplicates={model.Summary.Duplicates}");
                if (model.CanSort) await model.BeginSortFlowAsync();
                log.WriteLine($"[done] {model.Status}");
                log.WriteLine($"[after] rows={model.Entries.Count} move={model.Summary.Move} duplicates={model.Summary.Duplicates}");
            }
            catch (Exception ex)
            {
                exitCode = 1;
                log.WriteLine($"[error] {ex}");
            }
        }
        Shutdown(exitCode);
    }

    private static void OnUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        e.Handled = true;
        try
        {
            File.AppendAllText(Path.Combine(Path.GetTempPath(), "SmartTelescopeSort-errors.log"), $"{DateTime.Now:O} {e.Exception}\n\n");
        }
        catch (IOException)
        {
        }
        new MessageWindow("Something went wrong",
            $"{e.Exception.Message}\n\nIf it keeps happening, please contact support (Help → Contact Support) and mention this message.",
            new[] { "OK" }, 0, 0).Run();
    }
}
