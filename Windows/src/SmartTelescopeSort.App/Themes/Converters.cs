using System.Globalization;
using System.Windows;
using System.Windows.Data;

namespace SmartTelescopeSort.App.Themes;

/// <summary>True / false to one of two theme brushes, named in the parameter as "WhenTrue|WhenFalse".</summary>
public sealed class BoolBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        var names = (parameter as string ?? "TextBrush|TextBrush").Split('|');
        return Application.Current.FindResource(value is true ? names[0] : names[^1]);
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

/// <summary>A colour name such as "Green" to the theme's GreenBrush.</summary>
public sealed class ThemeBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        Application.Current.TryFindResource($"{value}Brush") ?? Application.Current.FindResource("TextBrush");

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}
