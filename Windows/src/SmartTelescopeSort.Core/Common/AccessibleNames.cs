namespace SmartTelescopeSort.Core.Common;

/// <summary>
/// What screen readers say for list rows. WPF names a list row, and a table cell without its own name, from the item's
/// ToString(), so every type shown in a list overrides ToString() with one of these.
/// </summary>
public static class AccessibleNames
{
    public static string CaptureRow(string captureFolder, string objectText, string year, string month, int files, string status, string targetFolder) =>
        $"{captureFolder}, {objectText}, {year}-{month}, {Count(files, "file")}, {status}, to {targetFolder}";

    public static string PlanFile(string fileName, string objectName, string date, string status, string targetFolder) =>
        $"{fileName}, {objectName}, {date}, {status}, to {targetFolder}";

    public static string Count(int count, string noun) => count == 1 ? $"1 {noun}" : $"{count} {noun}s";
}
