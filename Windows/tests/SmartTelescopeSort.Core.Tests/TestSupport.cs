using System.Runtime.CompilerServices;
using System.Text;
using SmartTelescopeSort.Core.Sorting;
using Xunit;
using Xunit.Abstractions;

// SortExtensions and the identical-file cache are static, as on the Mac.
[assembly: CollectionBehavior(DisableTestParallelization = true)]

namespace SmartTelescopeSort.Core.Tests;

/// <summary>The Mac tests' Checker: counts every check so the totals can be compared with App/Tests/CaptureSorterTests.swift.</summary>
public sealed class Checker
{
    private readonly ITestOutputHelper? _output;

    public Checker(ITestOutputHelper? output = null) => _output = output;

    public int Passed { get; private set; }

    public List<string> Failures { get; } = new();

    public void Expect(bool ok, string what, [CallerLineNumber] int line = 0)
    {
        if (ok)
        {
            Passed++;
            return;
        }
        Failures.Add($"line {line}: {what}");
        _output?.WriteLine($"FAIL (line {line}): {what}");
    }

    public void Equal<T>(T actual, T expected, string what, [CallerLineNumber] int line = 0) =>
        Expect(EqualityComparer<T>.Default.Equals(actual, expected), $"{what}: got {Show(actual)}, expected {Show(expected)}", line);

    public void SequenceEqual<T>(IEnumerable<T>? actual, IEnumerable<T> expected, string what, [CallerLineNumber] int line = 0) =>
        Expect(actual is not null && actual.SequenceEqual(expected), $"{what}: got {Show(actual)}, expected {Show(expected)}", line);

    public void SetEqual<T>(IEnumerable<T>? actual, IEnumerable<T> expected, string what, [CallerLineNumber] int line = 0) =>
        Expect(actual is not null && actual.ToHashSet().SetEquals(expected), $"{what}: got {Show(actual)}, expected {Show(expected)}", line);

    /// <summary>All checks passed, and as many ran as in the Mac test.</summary>
    public void Done(int expectedChecks)
    {
        _output?.WriteLine($"{Passed} checks passed, {Failures.Count} failed");
        Assert.True(Failures.Count == 0, string.Join(Environment.NewLine, Failures));
        Assert.Equal(expectedChecks, Passed);
    }

    private static string Show(object? value) => value switch
    {
        null => "nil",
        string s => $"\"{s}\"",
        System.Collections.IEnumerable items => "[" + string.Join(", ", items.Cast<object?>().Select(Show)) + "]",
        _ => value.ToString() ?? "",
    };
}

public static class Fixture
{
    /// <summary>Writes a small file whose bytes are its own path, so no two fixtures are identical.</summary>
    public static string File(string root, string path, DateTime? modified = null)
    {
        var full = Path.Combine(root, P(path));
        Directory.CreateDirectory(Path.GetDirectoryName(full)!);
        System.IO.File.WriteAllBytes(full, Encoding.UTF8.GetBytes(path));
        if (modified is { } date) System.IO.File.SetLastWriteTime(full, date);
        return full;
    }

    /// <summary>A path written with "/" in the host's separators.</summary>
    public static string P(string path) => path.Replace('/', Path.DirectorySeparatorChar);

    /// <summary>Noon local time, so the year can't shift with the time zone.</summary>
    public static DateTime Day(int year, int month, int day) => new(year, month, day, 12, 0, 0, DateTimeKind.Local);

    public static HashSet<string> Extensions(IEnumerable<SortFileType> types) => SortFileTypes.ExtensionsOf(types);

    public static Dictionary<string, CaptureEntry> ByObject(IEnumerable<CaptureEntry> entries)
    {
        var rows = new Dictionary<string, CaptureEntry>(StringComparer.Ordinal);
        foreach (var entry in entries) rows.TryAdd(entry.Object, entry);
        return rows;
    }
}

/// <summary>A scratch folder under /tmp (the temp folder on Windows), removed after the test.</summary>
public sealed class Scratch : IDisposable
{
    public Scratch(string name = "SmartTelescopeSort-Tests")
    {
        var parent = OperatingSystem.IsWindows() ? Path.GetTempPath() : "/tmp";
        Root = Path.Combine(parent, $"{name}-{Guid.NewGuid():N}");
        Directory.CreateDirectory(Root);
    }

    public string Root { get; }

    public string this[string relative] => Path.Combine(Root, Fixture.P(relative));

    public void Dispose()
    {
        try
        {
            foreach (var file in Directory.EnumerateFiles(Root, "*", SearchOption.AllDirectories))
                System.IO.File.SetAttributes(file, FileAttributes.Normal);
            Directory.Delete(Root, true);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }
}
