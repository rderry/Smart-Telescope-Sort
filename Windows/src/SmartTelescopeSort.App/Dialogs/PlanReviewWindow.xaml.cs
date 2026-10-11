using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Data;
using SmartTelescopeSort.App.Platform;
using SmartTelescopeSort.App.ViewModels;
using SmartTelescopeSort.Core.Common;
using SmartTelescopeSort.Core.Sorting;

namespace SmartTelescopeSort.App.Dialogs;

/// <summary>One file in the plan review list.</summary>
public sealed record PlanRow(SortPlanItem Item, string Group)
{
    public string Object => Item.Object;
    public string FileName => Path.GetFileName(Item.Source);
    public string Source => Item.Source;
    public string DateText => Item.Date.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture);
    public string TargetFolder => Item.TargetFolder;
    public string Destination => Item.Destination;
    public string ActionLabel => Item.ActionLabel;
    public bool IsDuplicate => Item.IsDuplicate;

    public override string ToString() => AccessibleNames.PlanFile(FileName, Object, DateText, ActionLabel, TargetFolder);
}

/// <summary>The status shown on a capture folder's header: "3 new", "Duplicate", "2 new · 1 duplicate"…</summary>
public sealed class GroupStatusConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is System.Collections.IEnumerable items ? MainViewModel.StatusText(items.OfType<PlanRow>().Select(r => r.Item).ToList()) : "";

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

/// <summary>The Mac's PlanReviewSheet: every file the sort would copy, grouped by capture folder. Nothing moves from here.</summary>
public partial class PlanReviewWindow : Window
{
    private readonly MainViewModel _model;

    public PlanReviewWindow(MainViewModel model)
    {
        InitializeComponent();
        WindowBackdrop.UseDark(this);
        Owner = DialogWindow.ActiveOwner();
        _model = model;
        Refresh();
    }

    private void Refresh()
    {
        var root = Path.GetFileName(_model.SourcePath.TrimEnd('\\', '/'));
        var rows = _model.PlanItems.Select(i => new PlanRow(i, i.CaptureFolder.Length == 0 ? root : i.CaptureFolder))
            .OrderBy(r => r.Group, StringComparer.Ordinal).ToList();
        var groups = rows.Select(r => r.Group).Distinct().Count();
        LayoutText.Text = _model.LayoutTitle;
        SummaryText.Text = $"{groups} capture folder(s) · {rows.Count} files: {_model.Summary.Move} new · {_model.Summary.Duplicates} duplicate. Nothing has been moved yet.";
        var view = new ListCollectionView(rows);
        view.GroupDescriptions.Add(new PropertyGroupDescription(nameof(PlanRow.Group)));
        Plan.ItemsSource = view;
        Plan.Visibility = rows.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        EmptyText.Visibility = rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        DuplicateBar.Visibility = _model.Summary.Duplicates > 0 ? Visibility.Visible : Visibility.Collapsed;
        DuplicateText.Text = $"{_model.Summary.Duplicates} file(s) are byte-for-byte copies of files in Targets and are marked Duplicate. Sort leaves them in place.";
        DeleteDuplicatesButton.IsEnabled = !_model.IsBusy;
    }

    private void Done_Click(object sender, RoutedEventArgs e) => Close();

    private async void DeleteDuplicates_Click(object sender, RoutedEventArgs e)
    {
        await _model.ConfirmDuplicatesAsync();
        Refresh();
    }
}
