namespace SmartTelescopeSort.Core.Common;

/// <summary>Name, version and the web links the Mac app's Help menu opens (BigSkyAstroWebLinks).</summary>
public static class AppInfo
{
    public const string Name = "Telescope Data Sort";

    /// <summary>The name until 1.2.1. The GitHub repository and the credit line keep it.</summary>
    public const string FormerName = "Smart Telescope Sort";

    public const string GitHubNameNote = "The GitHub project keeps the app's earlier name, " + FormerName + ".";

    /// <summary>Same marketing version and build as the Mac app it was ported from: 1.2.1 (11).</summary>
    public const string Version = "1.2.1";

    public const string Build = "11";

    public const string Freeware = "Open-source freeware";

    public const string PrivacyPolicy = "https://bigskyastro.com/privacy";
    public const string AppPage = "https://bigskyastro.com/macos/smart-telescope-sort";
    public const string Support = "https://bigskyastro.com/feedback/smart-telescope-sort";
    public const string SupportEmail = "mailto:support@bigskyastro.com";
    public const string ObservationPlanner = "https://apps.apple.com/app/id6764166535";
    public const string TelescopePlanner = "https://apps.apple.com/app/id6768153445";
    public const string SourceCode = "https://github.com/rderry/Smart-Telescope-Sort";
    public const string Home = "https://bigskyastro.com";

    public const string CreditLine = "Based on Smart Telescope Sort by BigSkyAstro — https://bigskyastro.com";

    public const string OpenSourceMessage =
        "If you change it and give it away, please give credit to BigSkyAstro: include the BigSkyAstro logo and a link to bigskyastro.com.";

    public const string MitNotice = "Open-source freeware, released under the MIT License.";

    /// <summary>Free zip and tarball apps for Windows, offered when a backup fails (the Mac lists Keka, PeaZip and Finder Compress).</summary>
    public static IReadOnlyList<(string Title, string Url)> ArchiverLinks { get; } = new[]
    {
        ("7-Zip (free zip & tarball)", "https://www.7-zip.org/"),
        ("PeaZip (free, open source)", "https://peazip.github.io/"),
        ("Windows Compressed Folders (built-in zip)", "https://support.microsoft.com/windows/zip-and-unzip-files-8d28fa72-f2f9-712f-67df-f80cf89fd4e5"),
    };
}
