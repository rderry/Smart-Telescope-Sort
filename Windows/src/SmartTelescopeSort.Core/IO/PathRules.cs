namespace SmartTelescopeSort.Core.IO;

/// <summary>
/// Path arithmetic done on strings, the way the Mac app's standardizedFileURL comparisons work, for either Windows
/// (drive letters, UNC shares, \\?\ prefixes, both slashes, case-insensitive) or POSIX paths. Nothing here touches the disk,
/// so the Windows rules run the same in tests on any machine.
/// </summary>
public sealed class PathRules
{
    public static readonly PathRules Windows = new(true);
    public static readonly PathRules Posix = new(false);
    public static PathRules Host { get; } = OperatingSystem.IsWindows() ? Windows : Posix;

    private PathRules(bool windows) => IsWindows = windows;

    public bool IsWindows { get; }

    public char Separator => IsWindows ? '\\' : '/';

    public StringComparison Comparison => IsWindows ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;

    public StringComparer Comparer => IsWindows ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;

    public bool IsSeparator(char c) => c == '/' || (IsWindows && c == '\\');

    /// <summary>
    /// Length of the root at the start of a path, with its trailing separator: "C:\", "\\server\share\", "\\?\C:\",
    /// "\\?\UNC\server\share\", "\" or "/". Zero for a relative path.
    /// </summary>
    public int RootLength(string path)
    {
        if (string.IsNullOrEmpty(path)) return 0;
        if (!IsWindows) return path[0] == '/' ? 1 : 0;

        if (path.Length >= 4 && IsSeparator(path[0]) && IsSeparator(path[1]) && (path[2] == '?' || path[2] == '.') && IsSeparator(path[3]))
        {
            var rest = path[4..];
            if (rest.StartsWith("UNC", StringComparison.OrdinalIgnoreCase) && rest.Length > 3 && IsSeparator(rest[3]))
                return 4 + 4 + ShareLength(rest[4..]);
            if (rest.Length >= 2 && rest[1] == ':') return 4 + (rest.Length >= 3 && IsSeparator(rest[2]) ? 3 : 2);
            return 4;
        }
        if (path.Length >= 2 && IsSeparator(path[0]) && IsSeparator(path[1])) return 2 + ShareLength(path[2..]);
        if (path.Length >= 2 && path[1] == ':' && char.IsAsciiLetter(path[0]))
            return path.Length >= 3 && IsSeparator(path[2]) ? 3 : 2;
        return IsSeparator(path[0]) ? 1 : 0;
    }

    /// <summary>"server\share\" at the start of `text`: the two names and the separator after them, if any.</summary>
    private int ShareLength(string text)
    {
        var index = 0;
        for (var part = 0; part < 2; part++)
        {
            while (index < text.Length && !IsSeparator(text[index])) index++;
            if (index < text.Length) index++;
        }
        return index;
    }

    public bool IsRooted(string path) => RootLength(path) > 0;

    /// <summary>
    /// The path with its root written one way (backslashes and a capital drive letter on Windows), repeated separators
    /// collapsed, "." and ".." resolved, and no trailing separator except on the root itself.
    /// </summary>
    public string Normalize(string path)
    {
        if (string.IsNullOrEmpty(path)) return path;
        var rootLength = RootLength(path);
        var root = path[..rootLength];
        if (IsWindows)
        {
            root = root.Replace('/', '\\');
            if (root.Length >= 2 && root[1] == ':') root = char.ToUpperInvariant(root[0]) + root[1..];
            if (root.Length == 2 && root[1] == ':') root += "\\";
        }

        var parts = new List<string>();
        foreach (var part in Split(path[rootLength..]))
        {
            if (part == ".") continue;
            if (part == "..")
            {
                if (parts.Count > 0 && parts[^1] != "..") parts.RemoveAt(parts.Count - 1);
                else if (rootLength == 0) parts.Add("..");
                continue;
            }
            parts.Add(part);
        }
        var joined = string.Join(Separator, parts);
        if (root.Length == 0) return joined.Length == 0 ? "." : joined;
        if (!IsSeparator(root[^1]) && joined.Length > 0) root += Separator;
        return root + joined;
    }

    /// <summary>The names in a path below its root, in order; empty names from repeated separators are dropped.</summary>
    public string[] Split(string relative) =>
        relative.Split(IsWindows ? new[] { '\\', '/' } : new[] { '/' }, StringSplitOptions.RemoveEmptyEntries);

    public bool AreSame(string a, string b) => string.Equals(Normalize(a), Normalize(b), Comparison);

    /// <summary>True when `path` is `folder` or anywhere below it.</summary>
    public bool IsSameOrInside(string path, string folder)
    {
        var p = Normalize(path);
        var f = Normalize(folder);
        if (string.Equals(p, f, Comparison)) return true;
        var prefix = IsSeparator(f[^1]) ? f : f + Separator;
        return p.StartsWith(prefix, Comparison);
    }

    /// <summary>
    /// `path` relative to `root`: "" for the root itself, the rest of the path when it is inside `root`, else just its
    /// last name (the Mac app's relativePath(of:in:)).
    /// </summary>
    public string RelativePath(string path, string root)
    {
        var p = Normalize(path);
        var r = Normalize(root);
        if (string.Equals(p, r, Comparison)) return "";
        var prefix = IsSeparator(r[^1]) ? r : r + Separator;
        return p.StartsWith(prefix, Comparison) ? p[prefix.Length..] : LastComponent(p);
    }

    public string LastComponent(string path)
    {
        var normalized = Normalize(path);
        var rootLength = RootLength(normalized);
        if (normalized.Length == rootLength) return normalized;
        var index = normalized.Length - 1;
        while (index >= rootLength && !IsSeparator(normalized[index])) index--;
        return normalized[(index + 1)..];
    }

    /// <summary>The folder holding `path`; the root for a top-level name, and the root itself for a root.</summary>
    public string Parent(string path)
    {
        var normalized = Normalize(path);
        var rootLength = RootLength(normalized);
        if (normalized.Length <= rootLength) return normalized;
        var index = normalized.Length - 1;
        while (index >= rootLength && !IsSeparator(normalized[index])) index--;
        if (index < rootLength) return rootLength > 0 ? normalized[..rootLength] : ".";
        return normalized[..index];
    }

    public bool IsRoot(string path)
    {
        var normalized = Normalize(path);
        return normalized.Length > 0 && normalized.Length == RootLength(normalized);
    }

    /// <summary>`relative` (names separated by either slash on Windows) appended to `folder`.</summary>
    public string Combine(string folder, string relative)
    {
        var parts = Split(relative);
        if (parts.Length == 0) return folder;
        var start = IsSeparator(folder[^1]) ? folder : folder + Separator;
        return start + string.Join(Separator, parts);
    }

    /// <summary>Names below the root, so a path's depth can be compared like the Mac's pathComponents.</summary>
    public int Depth(string path)
    {
        var normalized = Normalize(path);
        return Split(normalized[RootLength(normalized)..]).Length;
    }
}
