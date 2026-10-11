using System.Text.Json;
using System.Text.Json.Serialization;

namespace SmartTelescopeSort.Core.Settings;

/// <summary>What the Mac app keeps in UserDefaults, kept in settings.json in the app's data folder.</summary>
public sealed class AppSettings
{
    [JsonPropertyName("telescopeKind")] public string? TelescopeKind { get; set; }
    [JsonPropertyName("fileTypes")] public List<string>? FileTypes { get; set; }
    [JsonPropertyName("deleteJSON")] public bool DeleteJson { get; set; }
    [JsonPropertyName("deleteAstrometry")] public bool DeleteAstrometry { get; set; }
    [JsonPropertyName("backupFormat")] public string BackupFormat { get; set; } = "off";
    [JsonPropertyName("originalsFolder")] public string? OriginalsFolder { get; set; }
    [JsonPropertyName("backupFolder")] public string? BackupFolder { get; set; }
    [JsonPropertyName("lastCaptureFolder")] public string? LastCaptureFolder { get; set; }
    [JsonPropertyName("showAssumptionsAtLaunch")] public bool ShowAssumptionsAtLaunch { get; set; } = true;

    public string? Folder(LibraryFolder folder) => folder == LibraryFolder.Originals ? OriginalsFolder : BackupFolder;

    public void SetFolder(LibraryFolder folder, string? path)
    {
        if (folder == LibraryFolder.Originals) OriginalsFolder = path;
        else BackupFolder = path;
    }
}

/// <summary>Reads and writes settings.json; a missing or damaged file gives the defaults.</summary>
public sealed class SettingsStore
{
    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };

    public SettingsStore(string folder) => FilePath = Path.Combine(folder, "settings.json");

    public string FilePath { get; }

    /// <summary>%LOCALAPPDATA%\SmartTelescopeSort (inside the package's private folder when installed from the Store).</summary>
    public static string DefaultFolder =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SmartTelescopeSort");

    public AppSettings Load()
    {
        try
        {
            return File.Exists(FilePath) ? JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath), Options) ?? new AppSettings() : new AppSettings();
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            return new AppSettings();
        }
    }

    public void Save(AppSettings settings)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        var temp = FilePath + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(settings, Options));
        File.Move(temp, FilePath, overwrite: true);
    }
}
