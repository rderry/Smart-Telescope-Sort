using System.Text;
using System.Text.RegularExpressions;

namespace SmartTelescopeSort.Core.IO;

/// <summary>
/// Folder and file names Windows can't create: device names (CON, PRN, AUX, NUL, COM1–COM9, LPT1–LPT9, with or without
/// an extension), the characters &lt; &gt; : " / \ | ? * and control characters, and names ending in a dot or space,
/// which Windows silently trims.
/// </summary>
public static partial class WindowsNames
{
    [GeneratedRegex(@"^(?:CON|PRN|AUX|NUL|COM[0-9¹²³]|LPT[0-9¹²³])(?:\..*)?$", RegexOptions.IgnoreCase)]
    private static partial Regex ReservedPattern();

    public static bool IsReserved(string name) => ReservedPattern().IsMatch(name.TrimEnd(' ', '.'));

    public static bool IsInvalidChar(char c) => c < 32 || c is '<' or '>' or ':' or '"' or '/' or '\\' or '|' or '?' or '*';

    /// <summary>
    /// A typed name made safe for a folder or file: forbidden characters become "-", surrounding spaces and dots go, and a
    /// device name gets "_" added. On the Mac only / : \ are replaced; the extra characters can't be in a Windows name.
    /// </summary>
    public static string Safe(string typed)
    {
        var builder = new StringBuilder(typed.Length);
        foreach (var c in typed) builder.Append(c >= 32 && IsInvalidChar(c) ? '-' : c);
        var name = TrimDotsAndWhitespace(builder.ToString());
        if (name.Any(c => c < 32)) name = new string(name.Select(c => c < 32 ? '-' : c).ToArray());
        return name.Length > 0 && IsReserved(name) ? name + "_" : name;
    }

    /// <summary>Spaces, dots and whitespace off both ends, like the Mac's trimming with ". " plus whitespacesAndNewlines.</summary>
    public static string TrimDotsAndWhitespace(string text)
    {
        var start = 0;
        var end = text.Length;
        while (start < end && (text[start] == '.' || char.IsWhiteSpace(text[start]))) start++;
        while (end > start && (text[end - 1] == '.' || char.IsWhiteSpace(text[end - 1]))) end--;
        return text[start..end];
    }

    /// <summary>A name that is already a folder name elsewhere (an object decoded from a folder) made creatable on Windows.</summary>
    public static string SafeSegment(string name)
    {
        var trimmed = name.TrimEnd('.', ' ');
        if (trimmed.Length == 0) return name.Length == 0 ? name : "_";
        if (trimmed.Any(IsInvalidChar)) trimmed = new string(trimmed.Select(c => IsInvalidChar(c) ? '-' : c).ToArray());
        return IsReserved(trimmed) ? trimmed + "_" : trimmed;
    }
}
