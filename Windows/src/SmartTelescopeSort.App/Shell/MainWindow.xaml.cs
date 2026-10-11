using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using SmartTelescopeSort.App.Dialogs;
using SmartTelescopeSort.App.Platform;
using SmartTelescopeSort.App.Services;
using SmartTelescopeSort.App.ViewModels;
using SmartTelescopeSort.Core.Common;
using SmartTelescopeSort.Core.Settings;
using SmartTelescopeSort.Core.Terms;

namespace SmartTelescopeSort.App.Shell;

public sealed record HowItWorksLine(string Icon, string Text)
{
    public override string ToString() => Text;
}

public partial class MainWindow : Window
{
    private readonly StartupOptions _options;
    private readonly MainViewModel _model;
    private readonly AgreementRecord _record;

    public MainWindow(StartupOptions options)
    {
        _options = options;
        _record = new AgreementRecord(options.DataDir);
        _model = new MainViewModel(new WpfPrompts(() => _model!), new SettingsStore(options.DataDir), options.Captures);
        if (options.Targets is { } targets) _model.UseLibraryFolder(LibraryFolder.Originals, targets, saveAsDefault: false);
        if (options.Backup is { } backup) _model.UseLibraryFolder(LibraryFolder.Backup, backup, saveAsDefault: false);

        InitializeComponent();
        InputBindings.Add(new KeyBinding(new RelayCommand(OpenManualPdf), Key.F1, ModifierKeys.None));
        InputBindings.Add(new KeyBinding(new RelayCommand(() => Run(() => _model.RefreshAsync())), Key.F5, ModifierKeys.None));
        InputBindings.Add(new KeyBinding(new RelayCommand(() => Run(() => _model.ChooseSourceFolderAsync())), Key.O, ModifierKeys.Control));
        WindowBackdrop.UseDark(this);
        Title = $"{AppInfo.Name} {AppInfo.Version}";
        DataContext = _model;
        _model.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(MainViewModel.LayoutDropHint) or nameof(MainViewModel.FirstHowItWorksLine)) FillHowItWorks();
        };
        FillHowItWorks();
        FillArchiverLinks();
        Loaded += OnLoaded;
    }

    private void FillHowItWorks() => HowItWorks.ItemsSource = new[]
    {
        new HowItWorksLine("\uE8B7", _model.FirstHowItWorksLine),
        new HowItWorksLine("\uE71C", "Pick a year, a month and the file types to move: TIFF, JPG/JPEG, FITS/FIT or All."),
        new HowItWorksLine("\uE8FD", "Review file plan lists every file with its object, date and target folder."),
        new HowItWorksLine("\uE7B8", "Optional Zip or Tarball backup. You name it, and a progress window shows it running."),
        new HowItWorksLine("\uE8C8", "Sort copies the checked file types into Targets {year}\\{object} and checks each copy byte for byte. Nothing there is overwritten."),
        new HowItWorksLine("\uE8C8", "Files already in the Target Folder are marked Duplicate. Plate solves go to {object}\\Plate Solves."),
        new HowItWorksLine("\uE74D", "Originals, then the processed capture folders, are deleted only after you say Yes twice."),
    };

    private void FillArchiverLinks()
    {
        foreach (var (title, url) in AppInfo.ArchiverLinks)
        {
            var item = new MenuItem { Header = title };
            item.Click += (_, _) => Desktop.Open(url);
            ArchiverMenu.Items.Add(item);
            var link = new Button { Content = title, Style = (Style)FindResource("LinkButton"), FontSize = 11, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 14, 0), ToolTip = url };
            link.Click += (_, _) => Desktop.Open(url);
            ArchiverLinks.Children.Add(link);
        }
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (_options.CaptureFolder is { } folder)
        {
            await RunCaptureAsync(folder);
            return;
        }
        if (_model.Settings.ShowAssumptionsAtLaunch || !_record.IsAccepted)
        {
            if (!ShowAssumptions())
            {
                Close();
                return;
            }
        }
        await _model.StartAsync();
    }

    /// <summary>Shows the Assumptions window; false when it was closed without accepting.</summary>
    private bool ShowAssumptions()
    {
        var window = new AssumptionsWindow(_record, _model.Settings.ShowAssumptionsAtLaunch) { Owner = this };
        window.ShowDialog();
        _model.Settings.ShowAssumptionsAtLaunch = window.ShowAtLaunch;
        _model.SaveSettings();
        return window.Accepted;
    }

    /// <summary>Runs one of the view model's flows unless another is already running.</summary>
    private async void Run(Func<Task> flow)
    {
        if (_model.IsBusy || _model.IsBackingUp) return;
        await flow();
    }

    private void ChooseCapture_Click(object sender, RoutedEventArgs e) => Run(() => _model.ChooseSourceFolderAsync());

    private void ChangeTarget_Click(object sender, RoutedEventArgs e)
    {
        if (!_model.IsBusy) _model.ChooseLibraryFolder(LibraryFolder.Originals);
    }

    private void ChangeBackup_Click(object sender, RoutedEventArgs e)
    {
        if (!_model.IsBusy) _model.ChooseLibraryFolder(LibraryFolder.Backup);
    }

    private void Refresh_Click(object sender, RoutedEventArgs e) => Run(() => _model.RefreshAsync());

    private void Review_Click(object sender, RoutedEventArgs e) => Run(async () =>
    {
        if (await _model.PrepareFilePlanAsync()) new PlanReviewWindow(_model).ShowDialog();
    });

    private void Sort_Click(object sender, RoutedEventArgs e) => Run(() => _model.BeginSortFlowAsync());

    private void RemoveCopies_Click(object sender, RoutedEventArgs e) => Run(() => _model.RemoveIdenticalCopiesInTargetsAsync());

    private void CreateMissing_Click(object sender, RoutedEventArgs e) => Run(() => _model.CreateMissingTargetAsync());

    private void Exit_Click(object sender, RoutedEventArgs e) => Close();

    private void OpenManualPdf()
    {
        if (Desktop.OpenManualPdf()) return;
        _model.Status = File.Exists(Desktop.ManualPath)
            ? "No app could open the user manual PDF. Help → User Manual (in this window) shows the same manual."
            : "User manual PDF was not found next to the app. Help → User Manual (in this window) shows the same manual.";
        new ManualWindow().Show();
    }

    private void ManualPdf_Click(object sender, RoutedEventArgs e) => OpenManualPdf();

    private void ManualInApp_Click(object sender, RoutedEventArgs e) => new ManualWindow().Show();

    private void Assumptions_Click(object sender, RoutedEventArgs e) => ShowAssumptions();

    private void TermsRecord_Click(object sender, RoutedEventArgs e) => TermsRecordInfo.Show(_record);

    private void Credits_Click(object sender, RoutedEventArgs e) => new CreditsWindow().ShowDialog();

    private void About_Click(object sender, RoutedEventArgs e) => new AboutWindow().ShowDialog();

    private void SourceCode_Click(object sender, RoutedEventArgs e) => SourceCodeCredit.OpenRepository();

    private void Home_Click(object sender, RoutedEventArgs e) => Desktop.Open(AppInfo.Home);

    private void Privacy_Click(object sender, RoutedEventArgs e) => Desktop.Open(AppInfo.PrivacyPolicy);

    private void AppPage_Click(object sender, RoutedEventArgs e) => Desktop.Open(AppInfo.AppPage);

    private void ObservationPlanner_Click(object sender, RoutedEventArgs e) => Desktop.Open(AppInfo.ObservationPlanner);

    private void TelescopePlanner_Click(object sender, RoutedEventArgs e) => Desktop.Open(AppInfo.TelescopePlanner);

    private void SupportEmail_Click(object sender, RoutedEventArgs e) => Desktop.Open(AppInfo.SupportEmail);

    private void Support_Click(object sender, RoutedEventArgs e) => Desktop.Open(AppInfo.Support);
}
