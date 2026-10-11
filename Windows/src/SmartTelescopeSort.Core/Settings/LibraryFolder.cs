namespace SmartTelescopeSort.Core.Settings;

/// <summary>Library folders the user picks once for all capture layouts.</summary>
public enum LibraryFolder
{
    Originals,
    Backup,
}

public static class LibraryFolders
{
    public static readonly LibraryFolder[] All = { LibraryFolder.Originals, LibraryFolder.Backup };

    public static string RawValue(this LibraryFolder folder) => folder == LibraryFolder.Originals ? "originals" : "backup";

    public static string Title(this LibraryFolder folder) => folder == LibraryFolder.Originals ? "Target Folder" : "Backup Storage";

    /// <summary>Shown after the title in the window, so the two main folders can't be confused.</summary>
    public static string? Caption(this LibraryFolder folder) => folder == LibraryFolder.Originals ? "where you want them put" : null;

    public static string Question(this LibraryFolder folder) => folder == LibraryFolder.Originals
        ? "Where do you want the sorted images put?"
        : "Where is your Backup Storage location?";

    public static string Detail(this LibraryFolder folder) => folder == LibraryFolder.Originals
        ? "Choose your Target Folder. Sorted images go into Targets {year}\\{object} inside it, alongside any Targets {year} folders already there."
        : "Choose where backups of your capture folders are stored before sorting (zip or tarball archives, or folder copies).";
}
