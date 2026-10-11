using System.Security.Cryptography;
using SmartTelescopeSort.Core.IO;
using SmartTelescopeSort.Core.Sorting;

// Headless checks for the Windows port: the same report as tools/mac-golden/GoldenReport.swift, and a manifest
// of a folder (sizes, SHA-256, dates) to prove originals are untouched. It never deletes anything.
var command = args.FirstOrDefault() ?? "";
var rest = args.Skip(1).ToList();
switch (command)
{
    case "report":
        return Report(rest);
    case "manifest":
        return Manifest(rest);
    default:
        Console.Error.WriteLine("usage:");
        Console.Error.WriteLine("  sts-check report <capture folder> <target folder> [tiff,fits,jpeg] [--sort]");
        Console.Error.WriteLine("  sts-check manifest <folder>");
        return 2;
}

static int Report(List<string> args)
{
    var sort = args.Remove("--sort");
    if (args.Count < 2) return Usage();
    var types = (args.Count > 2 ? args[2] : "tiff,fits").Split(',').Select(SortFileTypes.FromRaw).OfType<SortFileType>();
    foreach (var line in SortReport.Lines(Path.GetFullPath(args[0]), Path.GetFullPath(args[1]), types, sort)) Console.WriteLine(line);
    return 0;
}

static int Manifest(List<string> args)
{
    if (args.Count < 1) return Usage();
    var root = Path.GetFullPath(args[0]);
    var lines = new List<string>();
    foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
    {
        var info = new FileInfo(file);
        using var stream = info.OpenRead();
        var hash = Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
        var modified = info.LastWriteTimeUtc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");
        lines.Add($"{PathRules.Host.RelativePath(file, root).Replace('\\', '/')}|{info.Length}|{hash}|{modified}");
    }
    lines.Sort(StringComparer.Ordinal);
    foreach (var line in lines) Console.WriteLine(line);
    return 0;
}

static int Usage()
{
    Console.Error.WriteLine("Missing arguments; run sts-check with no arguments for usage.");
    return 2;
}
