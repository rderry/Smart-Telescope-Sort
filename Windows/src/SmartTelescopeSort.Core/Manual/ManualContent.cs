using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace SmartTelescopeSort.Core.Manual;

/// <summary>
/// WindowsManualContent.json: the in-app manual and the PDF manual (scripts/build-user-manual.py) share it.
/// Inline marks: **bold**, *italic*, `code`.
/// </summary>
public sealed partial class ManualContent
{
    [JsonPropertyName("title")] public string Title { get; set; } = "";
    [JsonPropertyName("subtitle")] public string Subtitle { get; set; } = "";
    [JsonPropertyName("platform")] public string Platform { get; set; } = "";
    [JsonPropertyName("notice")] public string Notice { get; set; } = "";
    [JsonPropertyName("purpose")] public string Purpose { get; set; } = "";
    [JsonPropertyName("cover")] public ManualBlock? Cover { get; set; }
    [JsonPropertyName("sections")] public List<ManualSection> Sections { get; set; } = new();
    [JsonPropertyName("end")] public string End { get; set; } = "";

    public static ManualContent Parse(string json) =>
        JsonSerializer.Deserialize<ManualContent>(json) ?? throw new JsonException("The manual content is empty.");

    public static ManualContent LoadBundled()
    {
        using var stream = typeof(ManualContent).Assembly.GetManifestResourceStream("SmartTelescopeSort.Core.Resources.WindowsManualContent.json")
            ?? throw new FileNotFoundException("WindowsManualContent.json is not bundled.");
        using var reader = new StreamReader(stream);
        return Parse(reader.ReadToEnd());
    }

    public enum Mark
    {
        Plain,
        Bold,
        Italic,
        Code,
    }

    [GeneratedRegex(@"\*\*(.+?)\*\*|`(.+?)`|\*(.+?)\*")]
    private static partial Regex Marks();

    /// <summary>A line of manual text split into plain, bold, italic and code runs.</summary>
    public static List<(string Text, Mark Mark)> Runs(string text)
    {
        var runs = new List<(string, Mark)>();
        var at = 0;
        foreach (Match match in Marks().Matches(text))
        {
            if (match.Index > at) runs.Add((text[at..match.Index], Mark.Plain));
            if (match.Groups[1].Success) runs.Add((match.Groups[1].Value, Mark.Bold));
            else if (match.Groups[2].Success) runs.Add((match.Groups[2].Value, Mark.Code));
            else runs.Add((match.Groups[3].Value, Mark.Italic));
            at = match.Index + match.Length;
        }
        if (at < text.Length) runs.Add((text[at..], Mark.Plain));
        return runs;
    }

    /// <summary>The text without its marks, for searching and accessibility names.</summary>
    public static string Plain(string text) => string.Concat(Runs(text).Select(r => r.Text));
}

public sealed class ManualSection
{
    [JsonPropertyName("title")] public string Title { get; set; } = "";
    [JsonPropertyName("level")] public int Level { get; set; } = 1;
    [JsonPropertyName("blocks")] public List<ManualBlock> Blocks { get; set; } = new();

    public override string ToString() => ManualContent.Plain(Title);
}

public sealed class ManualBlock
{
    /// <summary>paragraph, bullets, numbers, code, table or figure.</summary>
    [JsonPropertyName("type")] public string Type { get; set; } = "paragraph";
    [JsonPropertyName("text")] public string? Text { get; set; }
    [JsonPropertyName("items")] public List<string>? Items { get; set; }
    [JsonPropertyName("rows")] public List<List<string>>? Rows { get; set; }
    [JsonPropertyName("image")] public string? Image { get; set; }
    [JsonPropertyName("caption")] public string? Caption { get; set; }
}
