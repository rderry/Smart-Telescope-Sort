using System.Windows;
using System.Windows.Controls;

namespace SmartTelescopeSort.App.Dialogs;

/// <summary>
/// The Mac's NSAlert: a title, a message, optional extra controls and a row of buttons. Closing the window or pressing
/// Esc counts as the cancel button; Enter presses the default button.
/// </summary>
public sealed class MessageWindow : DialogWindow
{
    private readonly int _cancelIndex;

    public MessageWindow(string title, string message, IReadOnlyList<string> buttons, int defaultIndex, int cancelIndex,
                         int destructiveIndex = -1, UIElement? accessory = null, double width = 560)
        : base(title, width)
    {
        _cancelIndex = cancelIndex;
        Result = cancelIndex;
        var panel = new StackPanel { Margin = new Thickness(24, 20, 24, 18) };
        panel.Children.Add(Heading(title));
        if (message.Length > 0) panel.Children.Add(ScrollingText(message));
        if (accessory is not null) panel.Children.Add(accessory);

        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
        for (var i = 0; i < buttons.Count; i++)
        {
            var index = i;
            var style = i == destructiveIndex ? "DestructiveButton" : i == defaultIndex ? "ProminentButton" : "BorderedButton";
            var button = MakeButton(buttons[i], style);
            button.IsDefault = i == defaultIndex;
            button.IsCancel = i == cancelIndex;
            button.Click += (_, _) =>
            {
                Result = index;
                DialogResult = true;
            };
            row.Children.Add(button);
            if (i == defaultIndex) Loaded += (_, _) => button.Focus();
        }
        panel.Children.Add(row);
        Content = panel;
    }

    /// <summary>The index of the button pressed.</summary>
    public int Result { get; private set; }

    public int Run()
    {
        if (ShowDialog() != true) Result = _cancelIndex;
        return Result;
    }
}
