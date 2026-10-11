using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using SmartTelescopeSort.Core.IO;
using SmartTelescopeSort.Core.Sorting;
using Xunit;
using Xunit.Abstractions;

namespace SmartTelescopeSort.Core.Tests;

/// <summary>
/// Demo Captures sorted by the port gives exactly what the Mac sorter gave (Golden/*.mac.txt, written by
/// tools/mac-golden/run-golden.sh): the plan, the copy-sort, a second sort finding only duplicates, and the Targets
/// tree, with every original left as it was. Set STS_DEMO_CAPTURES to the folder when the repo layout differs.
/// </summary>
public sealed class GoldenDemoTests
{
    private readonly ITestOutputHelper _output;

    public GoldenDemoTests(ITestOutputHelper output) => _output = output;

    private static string Here([CallerFilePath] string path = "") => Path.GetDirectoryName(path)!;

    private static string? DemoCaptures()
    {
        var folder = Environment.GetEnvironmentVariable("STS_DEMO_CAPTURES")
            ?? Path.GetFullPath(Path.Combine(Here(), "..", "..", "..", "Demo Captures"));
        return Directory.Exists(folder) ? folder : null;
    }

    private static string[] Golden(string name)
    {
        var file = Path.Combine(AppContext.BaseDirectory, "Golden", name);
        return File.ReadAllLines(File.Exists(file) ? file : Path.Combine(Here(), "Golden", name));
    }

    [Fact]
    public void DemoCapturesSortExactlyAsOnTheMac()
    {
        if (DemoCaptures() is not { } demo)
        {
            _output.WriteLine("Demo Captures not found; set STS_DEMO_CAPTURES to run this comparison.");
            return;
        }
        using var s = new Scratch();
        var captures = s["Captures"];
        var library = s["Library"];
        CopyKeepingDates(demo, captures);
        var before = Manifest(captures);
        var types = SortFileTypes.Defaults;

        Assert.Equal(Golden("demo-plan.mac.txt"), SortReport.Lines(captures, library, types));
        Assert.Equal(Golden("demo-sort.mac.txt"), SortReport.Lines(captures, library, types, sort: true));
        Assert.Equal(Golden("demo-sort-again.mac.txt"), SortReport.Lines(captures, library, types, sort: true));
        Assert.Equal(Golden("demo-targets-tree.mac.txt"), Manifest(library));
        Assert.Equal(before, Manifest(captures));
    }

    private static void CopyKeepingDates(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var file in Directory.EnumerateFiles(from))
        {
            if (Path.GetFileName(file).StartsWith("._", StringComparison.Ordinal) || Path.GetFileName(file) == ".DS_Store") continue;
            FileOps.CopyFile(file, Path.Combine(to, Path.GetFileName(file)));
        }
        foreach (var folder in Directory.EnumerateDirectories(from)) CopyKeepingDates(folder, Path.Combine(to, Path.GetFileName(folder)));
    }

    /// <summary>The same lines as `sts-check manifest`: path, size, SHA-256 and UTC date of every file.</summary>
    private static List<string> Manifest(string root)
    {
        var lines = new List<string>();
        foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
        {
            var info = new FileInfo(file);
            using var stream = info.OpenRead();
            var hash = Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
            lines.Add($"{PathRules.Host.RelativePath(file, root).Replace('\\', '/')}|{info.Length}|{hash}|{info.LastWriteTimeUtc:yyyy-MM-dd'T'HH:mm:ss'Z'}");
        }
        lines.Sort(StringComparer.Ordinal);
        return lines;
    }
}
