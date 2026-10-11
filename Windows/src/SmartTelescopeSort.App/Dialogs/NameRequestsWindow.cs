using System.Media;
using System.Windows;
using System.Windows.Controls;
using SmartTelescopeSort.App.Services;
using SmartTelescopeSort.App.ViewModels;

namespace SmartTelescopeSort.App.Dialogs;

/// <summary>
/// One list of every folder or session that needs an object name: a checkbox, an editable name box offering the objects
/// already in Targets {year}, and a detail line. OK only closes when every checked row has a name.
/// </summary>
public sealed class NameRequestsWindow : DialogWindow
{
    private readonly List<(NameRequest Request, CheckBox Check, ComboBox Box)> _rows = new();

    public NameRequestsWindow(string title, string message, IReadOnlyList<NameRequest> requests, IReadOnlyList<string> choices,
                              string okTitle, string cancelTitle)
        : base(title, 780)
    {
        var panel = new StackPanel { Margin = new Thickness(24, 20, 24, 18) };
        panel.Children.Add(Heading(title));
        panel.Children.Add(Paragraph(message));

        var grid = new Grid { Margin = new Thickness(4) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(300) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(230) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        foreach (var request in requests)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var row = grid.RowDefinitions.Count - 1;
            var check = new CheckBox
            {
                Content = new TextBlock { Text = request.Label, TextTrimming = TextTrimming.CharacterEllipsis, ToolTip = request.Label },
                IsChecked = true,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 3, 10, 3),
            };
            var box = new ComboBox
            {
                IsEditable = true,
                IsTextSearchEnabled = true,
                ItemsSource = choices,
                Text = request.Suggestion,
                ToolTip = "e.g. M31, NGC7000, Moon",
                Margin = new Thickness(0, 3, 10, 3),
            };
            var detail = new TextBlock
            {
                Text = request.Detail,
                FontSize = 11,
                Foreground = Brush("LabelBrush"),
                VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis,
            };
            check.Checked += (_, _) => box.IsEnabled = true;
            check.Unchecked += (_, _) => box.IsEnabled = false;
            Grid.SetRow(check, row);
            Grid.SetRow(box, row);
            Grid.SetRow(detail, row);
            Grid.SetColumn(box, 1);
            Grid.SetColumn(detail, 2);
            grid.Children.Add(check);
            grid.Children.Add(box);
            grid.Children.Add(detail);
            _rows.Add((request, check, box));
        }
        panel.Children.Add(new ScrollViewer
        {
            Content = grid,
            MaxHeight = 380,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        });

        var ok = MakeButton(okTitle, "ProminentButton");
        ok.IsDefault = true;
        ok.Click += (_, _) =>
        {
            var names = new Dictionary<string, string>();
            foreach (var (request, check, box) in _rows.Where(r => r.Check.IsChecked == true))
            {
                var name = MainViewModel.FolderName(box.Text ?? "");
                if (name.Length == 0)
                {
                    SystemSounds.Beep.Play();
                    box.Focus();
                    return;
                }
                names[request.Key] = name;
            }
            Names = names;
            DialogResult = true;
        };
        var cancel = MakeButton(cancelTitle);
        cancel.IsCancel = true;
        panel.Children.Add(ButtonRow(ok, cancel));
        Content = panel;
    }

    public Dictionary<string, string>? Names { get; private set; }
}
