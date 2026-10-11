using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using SmartTelescopeSort.App.Platform;
using SmartTelescopeSort.Core.Common;
using SmartTelescopeSort.Core.Sorting;
using SmartTelescopeSort.Core.Terms;

namespace SmartTelescopeSort.App.Dialogs;

/// <summary>Bundled images, read from the app's resources.</summary>
public static class AppImages
{
    public static BitmapImage Load(string name)
    {
        var image = new BitmapImage();
        image.BeginInit();
        image.UriSource = new Uri($"pack://application:,,,/Assets/{name}.png", UriKind.Absolute);
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.EndInit();
        image.Freeze();
        return image;
    }

    /// <summary>The logo with rounded corners, `width` wide.</summary>
    public static Border Logo(double width, string? tooltip = null)
    {
        var bitmap = Load(Credits.LogoResource);
        var height = width * bitmap.PixelHeight / Math.Max(bitmap.PixelWidth, 1);
        return new Border
        {
            Width = width,
            Height = height,
            CornerRadius = new CornerRadius(10),
            Background = new ImageBrush(bitmap) { Stretch = Stretch.UniformToFill },
            HorizontalAlignment = HorizontalAlignment.Center,
            ToolTip = tooltip,
        };
    }
}

/// <summary>The Credits popup: BigSkyAstro logo, the people, then the data sources (names only, no links).</summary>
public sealed class CreditsWindow : DialogWindow
{
    public CreditsWindow() : base(Credits.Title, 460)
    {
        SizeToContent = SizeToContent.Manual;
        Height = 600;
        var panel = new StackPanel { Margin = new Thickness(24) };
        var logo = AppImages.Logo(380);
        logo.SetValue(AutomationPropertiesName, "BigSkyAstro");
        logo.Margin = new Thickness(0, 0, 0, 20);
        panel.Children.Add(logo);
        panel.Children.Add(Section(Credits.PeopleHeading, Credits.PeopleLines));
        panel.Children.Add(Section(Credits.DataSourcesHeading, Credits.DataSources));

        var done = MakeButton("Done", "ProminentButton");
        done.IsDefault = true;
        done.IsCancel = true;
        done.Click += (_, _) => Close();
        var footer = new Border
        {
            BorderBrush = Brush("HairlineBrush"),
            BorderThickness = new Thickness(0, 1, 0, 0),
            Padding = new Thickness(12),
            Child = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Children = { done } },
        };
        var dock = new DockPanel();
        DockPanel.SetDock(footer, Dock.Bottom);
        dock.Children.Add(footer);
        dock.Children.Add(new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        Content = dock;
    }

    private static readonly DependencyProperty AutomationPropertiesName = System.Windows.Automation.AutomationProperties.NameProperty;

    private static StackPanel Section(string heading, IEnumerable<string> lines)
    {
        var section = new StackPanel { Margin = new Thickness(0, 0, 0, 20) };
        section.Children.Add(new TextBlock { Text = heading, FontSize = 15, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 6) });
        foreach (var line in lines)
            section.Children.Add(new TextBlock { Text = line, FontSize = 13, Foreground = Brush("SubtitleBrush"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 4) });
        return section;
    }
}

/// <summary>About Telescope Data Sort: version, licence, credit line and the non-affiliation statement.</summary>
public sealed class AboutWindow : DialogWindow
{
    public AboutWindow() : base($"About {AppInfo.Name}", 520)
    {
        var panel = new StackPanel { Margin = new Thickness(24, 20, 24, 18) };
        var logo = AppImages.Logo(300);
        logo.Margin = new Thickness(0, 0, 0, 14);
        panel.Children.Add(logo);
        panel.Children.Add(new TextBlock { Text = AppInfo.Name, FontSize = 20, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Center });
        panel.Children.Add(new TextBlock
        {
            Text = $"Version {AppInfo.Version} ({AppInfo.Build}) for Windows\nFormerly {AppInfo.FormerName}",
            Foreground = Brush("LabelBrush"),
            HorizontalAlignment = HorizontalAlignment.Center,
            TextAlignment = TextAlignment.Center,
            Margin = new Thickness(0, 2, 0, 14),
        });
        panel.Children.Add(Paragraph("Sorts smart-telescope and classic telescope captures into Targets {year}\\{object} folders. " + AppInfo.Freeware + ", with no ads, accounts or tracking."));
        panel.Children.Add(Paragraph(TelescopeKinds.NotAffiliated, 12, "SubtitleBrush"));
        panel.Children.Add(Paragraph(AppInfo.MitNotice + " " + AppInfo.OpenSourceMessage, 12, "SubtitleBrush"));
        panel.Children.Add(Paragraph(AppInfo.CreditLine, 12, "LinkBrush"));

        var site = MakeButton("bigskyastro.com");
        site.Click += (_, _) => Desktop.Open(AppInfo.Home);
        var ok = MakeButton("OK", "ProminentButton");
        ok.IsDefault = true;
        ok.IsCancel = true;
        ok.Click += (_, _) => Close();
        panel.Children.Add(ButtonRow(site, ok));
        Content = panel;
    }
}

/// <summary>Asks for BigSkyAstro credit before opening the open-source repository (the Mac's SourceCodeCredit).</summary>
public static class SourceCodeCredit
{
    public static void OpenRepository()
    {
        var accessory = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 4) };
        accessory.Children.Add(AppImages.Logo(300));
        var link = new Button { Content = AppInfo.Home, Style = DialogWindow.StyleOf("LinkButton"), HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 8, 0, 0) };
        link.Click += (_, _) => Desktop.Open(AppInfo.Home);
        accessory.Children.Add(link);
        var window = new MessageWindow($"{AppInfo.Name} is open source",
            AppInfo.OpenSourceMessage + $"\n\nCredit line: \"{AppInfo.CreditLine}\"\n\n{AppInfo.GitHubNameNote}",
            new[] { "Continue", "Cancel" }, defaultIndex: 0, cancelIndex: 1, accessory: accessory, width: 480);
        if (window.Run() == 0) Desktop.Open(AppInfo.SourceCode);
    }
}

/// <summary>Where the locked terms-acceptance PDF is, and when the terms were accepted.</summary>
public static class TermsRecordInfo
{
    public static void Show(AgreementRecord record)
    {
        if (record.Read() is { } contents)
        {
            var answer = new MessageWindow($"Terms accepted {contents.AgreedAt}",
                $"On this PC ({contents.MacAddress}), terms version {contents.TermsVersion}.\n\n"
                + $"The record is a hidden, read-only, password-locked PDF:\n{record.FilePath}",
                new[] { "OK", "Copy Path" }, defaultIndex: 0, cancelIndex: 0).Run();
            if (answer == 1) Desktop.CopyToClipboard(record.FilePath);
        }
        else
        {
            new MessageWindow("No terms acceptance recorded",
                $"It is saved when you check “I have read and accept the above” and click I Understand. It will be kept at:\n{record.FilePath}",
                new[] { "OK" }, 0, 0).Run();
        }
    }
}

/// <summary>What the app takes for granted, shown when it opens and from the Help menu. Can't be closed until accepted.</summary>
public sealed class AssumptionsWindow : DialogWindow
{
    public const string BackupNotice = "A BACKUP is highly recommended, on a separate drive if possible. "
        + "You can delete it once you are satisfied all your data is moved.";

    public const string Disclaimer = "Big Sky Astro is not responsible for the loss of data. We have built in many safeguards to prevent it. "
        + "The user accepts all liability using this freeware.";

    public static readonly IReadOnlyList<string> Points = new[]
    {
        "Capture Folder: where your images are. All subfolders are searched.",
        "Images move to the Target Folder by DSO or celestial name: Targets {year}\\{object}.",
        "Any telescope or camera: smart-telescope layouts (Vespera, Stellina, Seestar, DWARF, Origin) are detected. "
            + "Images from other telescopes, including classic setups, sort when a folder above them names the object, e.g. M31\\.",
        "No object name found? Before sorting you name them all in one list. The date is the default.",
        "Dates come from folder names, else from the files.",
        "Only file types checked under Files to Move are moved (TIFF, JPG, FITS).",
        "Nothing is overwritten. A name used by another night gets a number: img-0001 2.tiff.",
        "Exact copies are marked Duplicate and deleted only if you say Yes.",
        "Not sorted: Targets {year} folders, thumbnails, auto-init frames.",
        "Emptied folders are deleted. JSON and astrometry files only if checked under OK to Delete or you allow it; folders with other files (e.g. .afphoto) are kept.",
        "After sorting, choose Move, Leave or Delete for plate solves, then for Lights, Darks, Dark Flats, Flats, Bias, Master* folders. Frames inside those folders are not sorted.",
        "Plate solves move in with their images: Targets {year}\\{object}\\Plate Solves. Unnamed ones are named in one list.",
    };

    private readonly AgreementRecord _record;
    private readonly bool _alreadyAgreed;
    private readonly CheckBox _accept;
    private readonly CheckBox _showAtLaunch;
    private readonly Button _understand;
    private bool _done;

    protected override void OnKeyDown(System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == System.Windows.Input.Key.Escape && !_alreadyAgreed)
        {
            e.Handled = true;
            return;
        }
        base.OnKeyDown(e);
    }

    public AssumptionsWindow(AgreementRecord record, bool showAtLaunch) : base("Before you sort", 840)
    {
        _record = record;
        _alreadyAgreed = record.IsAccepted;
        var panel = new StackPanel { Margin = new Thickness(28) };
        panel.Children.Add(new TextBlock { Text = "Before you sort", FontSize = 22, FontWeight = FontWeights.Bold, Margin = new Thickness(0, 0, 0, 14) });
        foreach (var point in Points)
        {
            var line = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 14, Margin = new Thickness(0, 0, 0, 8) };
            line.Inlines.Add(new Run("•  ") { Foreground = Brush("AccentBrush") });
            line.Inlines.Add(new Run(point));
            panel.Children.Add(line);
        }
        panel.Children.Add(Notice(BackupNotice, Brushes.Red, Brush("NoticeYellowBrush")));
        panel.Children.Add(Notice(Disclaimer, Brushes.Black, Brush("RedBrush")));

        var agreed = _alreadyAgreed && record.AcceptedDate is { } date ? $" on {date.LocalDateTime:MMMM d, yyyy 'at' h:mm tt}" : "";
        _accept = new CheckBox
        {
            Content = new TextBlock
            {
                Text = _alreadyAgreed ? "You have already agreed" + agreed : "I have read and accept the above",
                FontSize = 14,
                FontWeight = FontWeights.Bold,
            },
            IsChecked = _alreadyAgreed,
            IsEnabled = !_alreadyAgreed,
            Margin = new Thickness(0, 6, 0, 12),
        };
        panel.Children.Add(_accept);

        _showAtLaunch = new CheckBox { Content = "Show this when the app opens", IsChecked = showAtLaunch, VerticalAlignment = VerticalAlignment.Center };
        _understand = MakeButton("I Understand", "ProminentButton");
        _understand.IsDefault = true;
        _understand.IsEnabled = _alreadyAgreed;
        _accept.Checked += (_, _) => _understand.IsEnabled = true;
        _accept.Unchecked += (_, _) => _understand.IsEnabled = _alreadyAgreed;
        _understand.Click += (_, _) => Understand();
        var footer = new DockPanel();
        DockPanel.SetDock(_understand, Dock.Right);
        footer.Children.Add(_understand);
        footer.Children.Add(_showAtLaunch);
        panel.Children.Add(footer);
        Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MaxHeight = 900 };
    }

    public bool ShowAtLaunch => _showAtLaunch.IsChecked == true;

    private static Border Notice(string text, Brush ink, Brush paper) => new()
    {
        Background = paper,
        CornerRadius = new CornerRadius(8),
        Padding = new Thickness(12),
        Margin = new Thickness(0, 6, 0, 6),
        Child = new TextBlock { Text = text, Foreground = ink, FontSize = 14, FontWeight = FontWeights.Bold, TextWrapping = TextWrapping.Wrap },
    };

    private void Understand()
    {
        if (!_alreadyAgreed)
        {
            try
            {
                _record.Record(Points.Concat(new[] { BackupNotice, Disclaimer }).ToList());
            }
            catch (Exception e) when (e is System.IO.IOException or UnauthorizedAccessException)
            {
                new MessageWindow("The acceptance couldn't be saved", e.Message, new[] { "OK" }, 0, 0).Run();
            }
        }
        _done = true;
        Close();
    }

    /// <summary>False when the window was closed without accepting; the app then quits.</summary>
    public bool Accepted => _done || _alreadyAgreed;
}
