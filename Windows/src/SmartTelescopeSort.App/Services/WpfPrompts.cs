using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using SmartTelescopeSort.App.Dialogs;
using SmartTelescopeSort.App.ViewModels;
using SmartTelescopeSort.Core.Settings;

namespace SmartTelescopeSort.App.Services;

/// <summary>Asks every question with the app's dark dialogs.</summary>
public sealed class WpfPrompts : IPrompts
{
    private readonly Func<MainViewModel> _model;

    public WpfPrompts(Func<MainViewModel> model) => _model = model;

    public bool Confirm(string title, string message) =>
        new MessageWindow(title, message, new[] { "Yes", "No" }, defaultIndex: 1, cancelIndex: 1, destructiveIndex: 0).Run() == 0;

    public int Choose(string title, string message, IReadOnlyList<string> buttons, int defaultIndex, int cancelIndex, int destructiveIndex = -1) =>
        new MessageWindow(title, message, buttons, defaultIndex, cancelIndex, destructiveIndex).Run();

    public void Inform(string title, string message) => new MessageWindow(title, message, new[] { "OK" }, 0, 0).Run();

    public string? AskBackupName(string title, string message, string suggestion, string placeholder)
    {
        var field = new TextBox { Text = suggestion, Tag = placeholder, Margin = new Thickness(0, 0, 0, 4) };
        var window = new MessageWindow(title, message, new[] { "Start Backup", "Cancel" }, 0, 1, accessory: field);
        window.Loaded += (_, _) =>
        {
            field.Focus();
            field.SelectAll();
        };
        return window.Run() == 0 ? field.Text : null;
    }

    public Dictionary<string, string>? AskNames(string title, string message, IReadOnlyList<NameRequest> requests, IReadOnlyList<string> choices,
                                                string okTitle, string cancelTitle)
    {
        var window = new NameRequestsWindow(title, message, requests, choices, okTitle, cancelTitle);
        return window.ShowDialog() == true ? window.Names : null;
    }

    public (bool Json, bool Astrometry)? AskHeld(string title, string message, string? jsonLabel, string? astrometryLabel)
    {
        var json = new CheckBox { Content = jsonLabel, IsChecked = false, Margin = new Thickness(0, 0, 0, 6) };
        var astrometry = new CheckBox { Content = astrometryLabel, IsChecked = false };
        var stack = new StackPanel();
        if (jsonLabel is not null) stack.Children.Add(json);
        if (astrometryLabel is not null) stack.Children.Add(astrometry);
        var answer = new MessageWindow(title, message, new[] { "Delete Checked", "Keep All" }, defaultIndex: 1, cancelIndex: 1, accessory: stack).Run();
        return answer == 0 ? (jsonLabel is not null && json.IsChecked == true, astrometryLabel is not null && astrometry.IsChecked == true) : null;
    }

    public string? ChooseFolder(string title, string? start)
    {
        var dialog = new OpenFolderDialog { Title = title, Multiselect = false };
        if (!string.IsNullOrEmpty(start) && System.IO.Directory.Exists(start)) dialog.InitialDirectory = start;
        return dialog.ShowDialog(DialogWindow.ActiveOwner()) == true ? dialog.FolderName : null;
    }

    public (string Path, bool SaveAsDefault)? ChooseLibraryFolder(LibraryFolder folder, string? start)
    {
        var window = new LibraryFolderWindow(folder, start);
        return window.ShowDialog() == true ? window.Choice : null;
    }

    public IDisposable ShowProgress(ProgressKind kind)
    {
        var owner = DialogWindow.ActiveOwner();
        var window = new ProgressWindow(_model(), kind);
        if (owner is not null) owner.IsEnabled = false;
        window.Show();
        return new Closer(() =>
        {
            window.Finish();
            if (owner is not null)
            {
                owner.IsEnabled = true;
                owner.Activate();
            }
        });
    }

    private sealed class Closer : IDisposable
    {
        private Action? _close;

        public Closer(Action close) => _close = close;

        public void Dispose()
        {
            _close?.Invoke();
            _close = null;
        }
    }
}
