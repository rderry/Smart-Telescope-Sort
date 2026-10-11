using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using SmartTelescopeSort.App.Platform;
using SmartTelescopeSort.Core.Manual;

namespace SmartTelescopeSort.App.Dialogs;

/// <summary>The user manual inside the app: sections on the left, the text on the right. Same content as the PDF.</summary>
public sealed class ManualWindow : Window
{
    private readonly Dictionary<ManualSection, Block> _anchors = new();
    private readonly FlowDocumentScrollViewer _viewer;

    public ManualWindow()
    {
        var manual = ManualContent.LoadBundled();
        Title = $"{manual.Title} — User Manual";
        Width = 1040;
        Height = 760;
        MinWidth = 760;
        MinHeight = 480;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Owner = DialogWindow.ActiveOwner();
        Background = DialogWindow.Brush("WorkspaceBrush");
        Foreground = DialogWindow.Brush("TextBrush");
        FontFamily = (FontFamily)Application.Current.FindResource("AppFont");
        WindowBackdrop.UseDark(this);

        var document = new FlowDocument
        {
            FontFamily = FontFamily,
            FontSize = 14,
            PagePadding = new Thickness(36, 28, 36, 36),
            Foreground = DialogWindow.Brush("TextBrush"),
            Background = DialogWindow.Brush("WorkspaceBrush"),
            ColumnWidth = double.PositiveInfinity,
            TextAlignment = TextAlignment.Left,
        };
        document.Blocks.Add(new Paragraph(new Run(manual.Title)) { FontSize = 28, FontWeight = FontWeights.Bold, Margin = new Thickness(0) });
        document.Blocks.Add(new Paragraph(new Run(manual.Subtitle)) { Foreground = DialogWindow.Brush("LinkBrush"), FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 4, 0, 0) });
        document.Blocks.Add(new Paragraph(new Run(manual.Platform)) { Foreground = DialogWindow.Brush("LabelBrush"), FontSize = 12, Margin = new Thickness(0, 2, 0, 12) });
        document.Blocks.Add(new Paragraph(new Run(manual.Notice))
        {
            FontSize = 15,
            FontWeight = FontWeights.Bold,
            Foreground = DialogWindow.Brush("UntestedNoticeTextBrush"),
            Margin = new Thickness(0, 0, 0, 12),
        });
        document.Blocks.Add(TextParagraph(manual.Purpose));
        if (manual.Cover is { } cover) Add(document, new ManualBlock { Type = "figure", Image = cover.Image, Caption = cover.Caption });

        foreach (var section in manual.Sections)
        {
            var heading = new Paragraph(new Run(section.Title))
            {
                FontSize = section.Level == 1 ? 21 : 16,
                FontWeight = FontWeights.Bold,
                Foreground = section.Level == 1 ? DialogWindow.Brush("TextBrush") : DialogWindow.Brush("LinkBrush"),
                Margin = new Thickness(0, section.Level == 1 ? 26 : 16, 0, 6),
                BreakPageBefore = false,
            };
            document.Blocks.Add(heading);
            _anchors[section] = heading;
            foreach (var block in section.Blocks) Add(document, block);
        }
        document.Blocks.Add(new Paragraph(new Run(manual.End)) { Foreground = DialogWindow.Brush("LabelBrush"), FontSize = 12, Margin = new Thickness(0, 28, 0, 0) });

        _viewer = new FlowDocumentScrollViewer
        {
            Document = document,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            IsToolBarVisible = false,
        };

        var list = new ListBox
        {
            Background = DialogWindow.Brush("SidebarBrush"),
            Foreground = DialogWindow.Brush("TextBrush"),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(8, 12, 8, 12),
            ItemsSource = manual.Sections,
            DisplayMemberPath = nameof(ManualSection.Title),
        };
        list.ItemContainerStyle = SectionStyle();
        list.SelectionChanged += (_, _) =>
        {
            if (list.SelectedItem is ManualSection section && _anchors.TryGetValue(section, out var anchor)) anchor.BringIntoView();
        };

        var pdf = new Button { Content = "Open the PDF manual", Style = DialogWindow.StyleOf("BorderedButton"), Margin = new Thickness(12) };
        pdf.Click += (_, _) =>
        {
            if (!Desktop.OpenManualPdf())
                new MessageWindow(File.Exists(Desktop.ManualPath) ? "The PDF manual couldn't be opened" : "The PDF manual wasn't found",
                    $"It should be at {Desktop.ManualPath}. This window shows the same manual.", new[] { "OK" }, 0, 0).Run();
        };
        var sidebar = new DockPanel { Width = 280, Background = DialogWindow.Brush("SidebarBrush") };
        DockPanel.SetDock(pdf, Dock.Bottom);
        sidebar.Children.Add(pdf);
        sidebar.Children.Add(list);

        var root = new DockPanel();
        DockPanel.SetDock(sidebar, Dock.Left);
        root.Children.Add(sidebar);
        root.Children.Add(_viewer);
        Content = root;
    }

    private static Style SectionStyle()
    {
        var style = new Style(typeof(ListBoxItem));
        style.Setters.Add(new Setter(PaddingProperty, new Thickness(8, 5, 8, 5)));
        style.Setters.Add(new Setter(ForegroundProperty, DialogWindow.Brush("TextBrush")));
        style.Setters.Add(new Setter(FontSizeProperty, 12.5));
        return style;
    }

    private static Paragraph TextParagraph(string text, double size = 14)
    {
        var paragraph = new Paragraph { Margin = new Thickness(0, 0, 0, 10), FontSize = size, LineHeight = size * 1.4 };
        AddRuns(paragraph.Inlines, text);
        return paragraph;
    }

    private static void AddRuns(InlineCollection inlines, string text)
    {
        foreach (var (part, mark) in ManualContent.Runs(text))
        {
            var run = new Run(part);
            switch (mark)
            {
                case ManualContent.Mark.Bold:
                    run.FontWeight = FontWeights.Bold;
                    break;
                case ManualContent.Mark.Italic:
                    run.FontStyle = FontStyles.Italic;
                    break;
                case ManualContent.Mark.Code:
                    run.FontFamily = (FontFamily)Application.Current.FindResource("MonoFont");
                    run.Foreground = DialogWindow.Brush("LinkBrush");
                    break;
            }
            inlines.Add(run);
        }
    }

    private static void Add(FlowDocument document, ManualBlock block)
    {
        switch (block.Type)
        {
            case "bullets":
            case "numbers":
            {
                var list = new List
                {
                    MarkerStyle = block.Type == "numbers" ? TextMarkerStyle.Decimal : TextMarkerStyle.Disc,
                    Margin = new Thickness(0, 0, 0, 10),
                    Padding = new Thickness(22, 0, 0, 0),
                };
                foreach (var item in block.Items ?? new List<string>())
                {
                    var paragraph = TextParagraph(item);
                    paragraph.Margin = new Thickness(0, 0, 0, 5);
                    list.ListItems.Add(new ListItem(paragraph));
                }
                document.Blocks.Add(list);
                break;
            }
            case "code":
                document.Blocks.Add(new Paragraph(new Run(block.Text ?? ""))
                {
                    FontFamily = (FontFamily)Application.Current.FindResource("MonoFont"),
                    FontSize = 12.5,
                    Background = DialogWindow.Brush("DestinationCardBrush"),
                    Padding = new Thickness(12, 8, 12, 8),
                    Margin = new Thickness(0, 0, 0, 12),
                });
                break;
            case "table":
                document.Blocks.Add(MakeTable(block.Rows ?? new List<List<string>>()));
                break;
            case "figure":
                if (FigureImage(block.Image) is { } image)
                    document.Blocks.Add(new BlockUIContainer(image) { Margin = new Thickness(0, 6, 0, 4) });
                if (!string.IsNullOrEmpty(block.Caption))
                    document.Blocks.Add(new Paragraph(new Run(block.Caption))
                    {
                        FontSize = 12,
                        FontStyle = FontStyles.Italic,
                        Foreground = DialogWindow.Brush("LabelBrush"),
                        Margin = new Thickness(0, 0, 0, 14),
                    });
                break;
            default:
                document.Blocks.Add(TextParagraph(block.Text ?? ""));
                break;
        }
    }

    private static Table MakeTable(List<List<string>> rows)
    {
        var table = new Table { CellSpacing = 0, Margin = new Thickness(0, 0, 0, 14), BorderBrush = DialogWindow.Brush("HairlineBrush"), BorderThickness = new Thickness(1) };
        var columns = rows.Count == 0 ? 0 : rows.Max(r => r.Count);
        for (var i = 0; i < columns; i++) table.Columns.Add(new TableColumn());
        var group = new TableRowGroup();
        for (var r = 0; r < rows.Count; r++)
        {
            var row = new TableRow { Background = r == 0 ? DialogWindow.Brush("DestinationCardBrush") : null };
            foreach (var cell in rows[r])
            {
                var paragraph = TextParagraph(cell, 12.5);
                paragraph.Margin = new Thickness(0);
                if (r == 0) paragraph.FontWeight = FontWeights.Bold;
                row.Cells.Add(new TableCell(paragraph)
                {
                    Padding = new Thickness(8, 5, 8, 5),
                    BorderBrush = DialogWindow.Brush("HairlineBrush"),
                    BorderThickness = new Thickness(0, 0, 1, 1),
                });
            }
            group.Rows.Add(row);
        }
        table.RowGroups.Add(group);
        return table;
    }

    /// <summary>A bundled screenshot (Assets/Manual/{name}.png), or null when it hasn't been made yet.</summary>
    private static Image? FigureImage(string? name)
    {
        if (string.IsNullOrEmpty(name)) return null;
        try
        {
            var uri = new Uri($"pack://application:,,,/Assets/Manual/{name}.png", UriKind.Absolute);
            if (Application.GetResourceStream(uri) is null) return null;
            var bitmap = new BitmapImage(uri);
            return new Image { Source = bitmap, MaxWidth = 860, Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Left };
        }
        catch (IOException)
        {
            return null;
        }
    }
}
