using System.IO;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using SmartTelescopeSort.Core.Settings;

namespace SmartTelescopeSort.App.Dialogs;

/// <summary>
/// Asks for the Target Folder or Backup Storage (the Mac's open panel with a "Save this as default" checkbox): the
/// question, why it's asked, the folder chosen with Browse…, and whether to keep it for next time.
/// </summary>
public sealed class LibraryFolderWindow : DialogWindow
{
    private readonly TextBox _path;
    private readonly CheckBox _saveDefault;
    private readonly LibraryFolder _folder;

    public LibraryFolderWindow(LibraryFolder folder, string? start) : base(folder.Title(), 640)
    {
        _folder = folder;
        var panel = new StackPanel { Margin = new Thickness(24, 20, 24, 18) };
        panel.Children.Add(Heading(folder.Question()));
        panel.Children.Add(Paragraph(folder.Detail(), 12, "SubtitleBrush"));

        var row = new Grid { Margin = new Thickness(0, 4, 0, 10) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _path = new TextBox { Text = start ?? "", Tag = folder == LibraryFolder.Originals ? @"e.g. D:\Astro" : @"e.g. E:\Backups", FontFamily = (System.Windows.Media.FontFamily)Application.Current.FindResource("MonoFont") };
        var browse = MakeButton("Browse…");
        browse.Click += (_, _) => Browse();
        Grid.SetColumn(browse, 1);
        row.Children.Add(_path);
        row.Children.Add(browse);
        panel.Children.Add(row);

        _saveDefault = new CheckBox { Content = "Save this as the default", IsChecked = true };
        panel.Children.Add(_saveDefault);
        panel.Children.Add(Paragraph("Unchecked, the folder is used until the app closes and you're asked again next time.", 11, "LabelBrush"));

        var choose = MakeButton("Choose", "ProminentButton");
        choose.IsDefault = true;
        choose.Click += (_, _) => Accept();
        var cancel = MakeButton("Cancel");
        cancel.IsCancel = true;
        panel.Children.Add(ButtonRow(choose, cancel));
        Content = panel;
        Loaded += (_, _) =>
        {
            if (_path.Text.Length == 0) Browse();
        };
    }

    public (string Path, bool SaveAsDefault)? Choice { get; private set; }

    private void Browse()
    {
        var dialog = new OpenFolderDialog
        {
            Title = _folder.Question(),
            Multiselect = false,
        };
        if (Directory.Exists(_path.Text)) dialog.InitialDirectory = _path.Text;
        if (dialog.ShowDialog(this) == true) _path.Text = dialog.FolderName;
    }

    private void Accept()
    {
        var typed = _path.Text.Trim().Trim('"');
        if (typed.Length == 0 || !Path.IsPathFullyQualified(typed))
        {
            new MessageWindow("Choose a folder", "Click Browse… to pick a folder, or type its full path, such as D:\\Astro or \\\\NAS\\Astro.",
                new[] { "OK" }, 0, 0).Run();
            return;
        }
        if (!Directory.Exists(typed))
        {
            var create = new MessageWindow("Create this folder?", $"{typed} doesn't exist yet. Create it?", new[] { "Create", "Cancel" }, 0, 1).Run();
            if (create != 0) return;
            try
            {
                Directory.CreateDirectory(typed);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or NotSupportedException)
            {
                new MessageWindow("The folder couldn't be created", e.Message, new[] { "OK" }, 0, 0).Run();
                return;
            }
        }
        Choice = (Path.GetFullPath(typed), _saveDefault.IsChecked == true);
        DialogResult = true;
    }
}
