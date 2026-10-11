using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using SmartTelescopeSort.App.Platform;

namespace SmartTelescopeSort.App.Dialogs;

/// <summary>A dark, centred dialog window like the Mac app's sheets, with helpers for the common pieces.</summary>
public class DialogWindow : Window
{
    public DialogWindow(string title, double width)
    {
        Title = title;
        Width = width;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = Brush("DialogBrush");
        Foreground = Brush("TextBrush");
        FontFamily = (FontFamily)Application.Current.FindResource("AppFont");
        FontSize = 13;
        UseLayoutRounding = true;
        Owner = ActiveOwner();
        if (Owner is null) WindowStartupLocation = WindowStartupLocation.CenterScreen;
        WindowBackdrop.UseDark(this, 0x33_1B_10);
    }

    public static Window? ActiveOwner()
    {
        var windows = Application.Current?.Windows.OfType<Window>().Where(w => w.IsVisible).ToList() ?? new List<Window>();
        return windows.FirstOrDefault(w => w.IsActive) ?? windows.LastOrDefault();
    }

    public static Brush Brush(string key) => (Brush)Application.Current.FindResource(key);

    public static Style StyleOf(string key) => (Style)Application.Current.FindResource(key);

    public static TextBlock Heading(string text) => new()
    {
        Text = text,
        Style = StyleOf("DialogTitle"),
        TextWrapping = TextWrapping.Wrap,
        Margin = new Thickness(0, 0, 0, 10),
    };

    public static TextBlock Paragraph(string text, double size = 13, string brush = "TextBrush") => new()
    {
        Text = text,
        TextWrapping = TextWrapping.Wrap,
        FontSize = size,
        Foreground = Brush(brush),
        Margin = new Thickness(0, 0, 0, 10),
    };

    public static Button MakeButton(string text, string style = "BorderedButton") => new()
    {
        Content = text,
        Style = StyleOf(style),
        MinWidth = 88,
        Margin = new Thickness(8, 0, 0, 0),
    };

    /// <summary>Right-aligned button row.</summary>
    public static StackPanel ButtonRow(params Button[] buttons)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
        foreach (var button in buttons) row.Children.Add(button);
        return row;
    }

    /// <summary>Text that scrolls when it is long, so a big list of folders never pushes the buttons off screen.</summary>
    public static UIElement ScrollingText(string text, double maxHeight = 420)
    {
        var block = Paragraph(text);
        block.Margin = new Thickness(0, 0, 8, 0);
        return new ScrollViewer
        {
            Content = block,
            MaxHeight = maxHeight,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Margin = new Thickness(0, 0, 0, 10),
        };
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (e.Key == Key.Escape && !e.Handled)
        {
            e.Handled = true;
            Close();
        }
    }
}
