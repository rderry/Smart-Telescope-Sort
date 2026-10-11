namespace SmartTelescopeSort.Core.Common;

/// <summary>
/// What the Credits popup lists, in order. Same wording and order as the other BigSkyAstro apps
/// (Marketing Field Data/Shared/Credits-Popup-Spec.md). Names only: the popup has no links.
/// </summary>
public static class Credits
{
    public sealed record Person(string Name, string Role);

    public const string Title = "Credits";

    /// <summary>Bundled banner shown at the top of the popup (Assets/BigSkyAstro-logo.png).</summary>
    public const string LogoResource = "BigSkyAstro-logo";

    public const string PeopleHeading = "People";

    public const string DataSourcesHeading = "Data sources";

    public static IReadOnlyList<Person> People { get; } = new[]
    {
        new Person("R Derry", "Developer and Owner"),
        new Person("F Derry", "Full Time Beta Tester"),
        new Person("Otto", "Programming and Smoke Testing"),
        new Person("A Derry", "Interface Consultant"),
    };

    public static IReadOnlyList<string> PeopleLines { get; } = People.Select(p => $"{p.Name} — {p.Role}").ToList();

    /// <summary>
    /// The app downloads and reads no data. Its only sources are the open-source code and the catalogs whose
    /// designations it recognizes in folder names (CaptureSorter's catalog pattern).
    /// </summary>
    public static IReadOnlyList<string> DataSources { get; } = new[]
    {
        "GitHub (open source, MIT license)",
        "Messier catalog",
        "New General Catalogue (NGC)",
        "Index Catalogue (IC)",
        "Sharpless catalog (Sh2)",
        "Barnard catalog",
        "Lynds Dark Nebulae (LDN)",
        "Lynds Bright Nebulae (LBN)",
        "van den Bergh catalog (vdB)",
        "Abell catalog",
        "Arp Atlas of Peculiar Galaxies",
        "Melotte catalog",
        "Collinder catalog",
        "Uppsala General Catalogue (UGC)",
        "Principal Galaxies Catalogue (PGC)",
        "Caldwell catalog",
    };
}
