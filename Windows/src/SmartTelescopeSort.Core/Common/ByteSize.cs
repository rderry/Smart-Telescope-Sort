using System.Globalization;

namespace SmartTelescopeSort.Core.Common;

/// <summary>Sizes written the way File Explorer shows them (1 KB = 1,024 bytes).</summary>
public static class ByteSize
{
    public static string Format(long bytes)
    {
        if (bytes < 1024) return bytes == 1 ? "1 byte" : $"{bytes.ToString("N0", CultureInfo.CurrentCulture)} bytes";
        string[] units = { "KB", "MB", "GB", "TB", "PB" };
        double value = bytes;
        var unit = -1;
        while (value >= 1024 && unit < units.Length - 1)
        {
            value /= 1024;
            unit++;
        }
        return value.ToString(value >= 100 ? "0" : value >= 10 ? "0.#" : "0.##", CultureInfo.CurrentCulture) + " " + units[unit];
    }
}

/// <summary>Names compared the way File Explorer orders them: "Session 2" before "Session 10" (the Mac's localizedStandardCompare).</summary>
public sealed class NaturalComparer : IComparer<string>
{
    public static readonly NaturalComparer Instance = new();

    public int Compare(string? x, string? y)
    {
        if (ReferenceEquals(x, y)) return 0;
        if (x is null) return -1;
        if (y is null) return 1;
        int i = 0, j = 0;
        while (i < x.Length && j < y.Length)
        {
            if (char.IsDigit(x[i]) && char.IsDigit(y[j]))
            {
                var si = i;
                var sj = j;
                while (i < x.Length && char.IsDigit(x[i])) i++;
                while (j < y.Length && char.IsDigit(y[j])) j++;
                var a = x[si..i].TrimStart('0');
                var b = y[sj..j].TrimStart('0');
                var c = a.Length != b.Length ? a.Length.CompareTo(b.Length) : string.CompareOrdinal(a, b);
                if (c != 0) return c;
                continue;
            }
            var d = string.Compare(x[i].ToString(), y[j].ToString(), CultureInfo.CurrentCulture, CompareOptions.IgnoreCase);
            if (d != 0) return d;
            i++;
            j++;
        }
        var rest = (x.Length - i).CompareTo(y.Length - j);
        return rest != 0 ? rest : string.CompareOrdinal(x, y);
    }
}
