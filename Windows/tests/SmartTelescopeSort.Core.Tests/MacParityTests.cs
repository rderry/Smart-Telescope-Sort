using System.Runtime.CompilerServices;
using SmartTelescopeSort.Core.Common;
using SmartTelescopeSort.Core.IO;
using SmartTelescopeSort.Core.Sorting;
using Xunit;
using Xunit.Abstractions;
using static SmartTelescopeSort.Core.Tests.Fixture;

namespace SmartTelescopeSort.Core.Tests;

/// <summary>
/// App/Tests/CaptureSorterTests.swift, check for check: images from any telescope or camera sort by the object their
/// folders name, frames inside calibration folders are set aside, and Credits follows the shared spec.
/// The Mac totals are 66 sorting checks (19 + 16 + 5 + 18 + 8) and 43 Credits checks.
/// </summary>
public sealed class MacParityTests
{
    private readonly ITestOutputHelper _output;

    public MacParityTests(ITestOutputHelper output) => _output = output;

    /// <summary>&lt;Object&gt;/&lt;files&gt; straight off a classic rig: no dates in folder names, so the year comes from the files.</summary>
    [Fact]
    public void ClassicObjectFolders()
    {
        var t = new Checker(_output);
        using var scratch = new Scratch();
        var captures = scratch["Captures"];
        var targets = scratch["Library"];
        DateTime nov2025 = Day(2025, 11, 3), aug2024 = Day(2024, 8, 20);
        foreach (var name in new[] { "Light_M31_300s_0001.fits", "Light_M31_300s_0002.fits", "M31_stacked.tif", "preview.jpg",
                     "notes.txt", "IMG_0001.CR2", "IMG_0002.NEF", "capture.ser", "capture.avi", "frame.xisf", "frame.fts", "frame.png" })
            File(captures, $"M31/{name}", nov2025);
        File(captures, "NGC 7000/frame_0001.fit", aug2024);

        t.Expect(TelescopeKinds.Detect(captures) is null, "classic object folders match no smart-telescope layout");

        CaptureSorter.SortExtensions = Extensions(SortFileTypes.Defaults);
        var rows = ByObject(CaptureSorter.Scan(TelescopeKind.Vaonis, captures, targets).Entries);
        t.SequenceEqual(rows.Keys.OrderBy(k => k, StringComparer.Ordinal), new[] { "M31", "NGC-7000" }, "objects from folder names");
        t.Equal(rows.GetValueOrDefault("M31")?.Year, "2025", "M31 year from file dates");
        t.Equal(rows.GetValueOrDefault("M31")?.Files, 3, "M31 sorts its FITS and TIFF files only");
        t.SequenceEqual(rows.GetValueOrDefault("M31")?.Formats, new[] { "FITS", "TIF" }, "M31 formats");
        t.Equal(rows.GetValueOrDefault("M31")?.NeedsObjectName, false, "M31 is named by its folder");
        t.Equal(rows.GetValueOrDefault("NGC-7000")?.Year, "2024", "NGC 7000 year from file dates");
        t.SequenceEqual(rows.GetValueOrDefault("NGC-7000")?.Formats, new[] { "FIT" }, "NGC 7000 formats");

        var entries = rows.Values.ToList();
        var (plans, summary) = CaptureSorter.Preview(entries);
        t.Equal(summary.Move, 4, "four new files");
        t.Equal(summary.Duplicate, 0, "no duplicates");
        t.SetEqual(plans.Select(p => CaptureSorter.RelativePath(p.Destination, targets)), new[]
        {
            P("Targets 2025/M31/Light_M31_300s_0001.fits"),
            P("Targets 2025/M31/Light_M31_300s_0002.fits"),
            P("Targets 2025/M31/M31_stacked.tif"),
            P("Targets 2024/NGC-7000/frame_0001.fit"),
        }, "destinations");
        t.Expect(plans.Select(p => CaptureSorter.Extension(p.Source).ToLowerInvariant()).All(e => e is "fits" or "fit" or "tif"),
            "RAW, video, XISF, FTS, PNG and other files are never in the plan");

        var copied = CaptureSorter.CopySort(entries, captures, targets);
        t.Expect(copied.Error is null && copied.Failed.Count == 0, $"copy has no errors: {copied.Error} {string.Join(", ", copied.Failed)}");
        t.Equal(copied.Copied.Count, 4, "four files copied");
        foreach (var item in copied.Copied)
            t.Expect(System.IO.File.Exists(item.Original) && FileOps.ContentsEqual(item.Original, item.Copy),
                $"{Path.GetFileName(item.Copy)} copied byte for byte, original kept");

        CaptureSorter.SortExtensions = Extensions(SortFileTypes.All);
        var withJpg = ByObject(CaptureSorter.Scan(TelescopeKind.Seestar, captures, targets).Entries);
        t.SequenceEqual(withJpg.GetValueOrDefault("M31")?.Formats, new[] { "FITS", "JPG", "TIF" }, "JPG sorts once checked");
        CaptureSorter.SortExtensions = Extensions(SortFileTypes.Defaults);

        t.Done(19);
    }

    /// <summary>Date and target folders as capture software writes them, a DSLR export, the Moon, and a folder naming no object.</summary>
    [Fact]
    public void DatedAndSoftwareFolders()
    {
        var t = new Checker(_output);
        using var scratch = new Scratch();
        var captures = scratch["Captures"];
        var targets = scratch["Library"];
        File(captures, "2026-10-07/M42/M42_0001.fits");
        File(captures, "2026-10-07/M42/M42_0002.fits");
        File(captures, "M81/2026-10-06/M81_0001.fits");
        File(captures, "SharpCap Captures/2026-10-05/M27/22_15_03/Capture_00001.fits");
        File(captures, "DSLR Export/M45/IMG_1234.tif", Day(2024, 1, 15));
        File(captures, "Moon/2026-09-17/moon_001.tif");
        File(captures, "Session 3/frame_0001.fits", Day(2026, 3, 1));

        t.Expect(TelescopeKinds.Detect(captures) is null, "dated classic folders match no smart-telescope layout");

        CaptureSorter.SortExtensions = Extensions(SortFileTypes.Defaults);
        var rows = ByObject(CaptureSorter.Scan(TelescopeKind.Dwarf, captures, targets).Entries);
        t.SequenceEqual(rows.Keys.OrderBy(k => k, StringComparer.Ordinal), new[] { "M27", "M42", "M45", "M81", "MOON", "SESSION-3" }, "objects");
        t.Equal(rows.GetValueOrDefault("M42")?.Files, 2, "M42 files");
        t.Equal(rows.GetValueOrDefault("M42")?.Session, "2026-10-07", "date folder above the object");
        t.Equal(rows.GetValueOrDefault("M81")?.Session, "2026-10-06", "date folder below the object");
        t.Equal(rows.GetValueOrDefault("M27")?.CaptureFolder, P("SharpCap Captures/2026-10-05/M27"), "nearest folder naming the object");
        t.Equal(rows.GetValueOrDefault("M27")?.Session, "2026-10-05", "date from a folder above the time folder");
        t.Equal(rows.GetValueOrDefault("M45")?.Year, "2024", "no dated folder: year from the file date");
        t.Equal(rows.GetValueOrDefault("MOON")?.Year, "2026", "solar-system name");
        t.Equal(rows.GetValueOrDefault("SESSION-3")?.NeedsObjectName, true, "a folder naming no object is named by the user");
        t.Equal(rows.GetValueOrDefault("SESSION-3")?.SessionDate, "2026-03-01", "date offered as its name");
        foreach (var (obj, row) in rows.Where(r => r.Key != "SESSION-3"))
            t.Equal(row.NeedsObjectName, false, $"{obj} is named by a folder");

        t.Done(16);
    }

    /// <summary>
    /// Frames left in Light/, Dark/, Flat/, Bias/ or Master… folders are set aside, as for every layout; lights moved
    /// into the object folder sort.
    /// </summary>
    [Fact]
    public void CalibrationFoldersSetAside()
    {
        var t = new Checker(_output);
        using var scratch = new Scratch();
        var captures = scratch["Captures"];
        File(captures, "Light/M31/Light_M31_0001.fits");
        File(captures, "M33/2026-10-01/LIGHT/M33_Light_0001.fits");
        File(captures, "M33/2026-10-01/FLAT/M33_Flat_0001.fits");
        File(captures, "M33/Darks/Dark_300s_0001.fits");
        File(captures, "Bias/Bias_0001.fits");
        File(captures, "Master Flats/MasterFlat_Ha.fits");
        File(captures, "M31/Light_M31_0002.fits");

        CaptureSorter.SortExtensions = Extensions(SortFileTypes.Defaults);
        var entries = CaptureSorter.Scan(TelescopeKind.Origin, captures).Entries;
        t.SequenceEqual(entries.Select(e => e.Object), new[] { "M31" }, "only the frame outside a calibration folder sorts");
        t.SequenceEqual(entries.FirstOrDefault()?.SourceFiles.Select(f => CaptureSorter.RelativePath(f, captures)),
            new[] { P("M31/Light_M31_0002.fits") }, "sorted file");

        var expected = new[] { "Light", "M33/2026-10-01/LIGHT", "M33/2026-10-01/FLAT", "M33/Darks", "Bias", "Master Flats" }.Select(P).ToList();
        t.SetEqual(CaptureSorter.CalibrationFolders(captures).Select(f => f.Path), expected, "calibration folders set aside");
        var setAside = CaptureSorter.SetAsideFolders(captures, null);
        t.SetEqual(setAside.Calibration.Select(f => f.Path), expected, "scan's set-aside calibration folders");
        t.Expect(setAside.PlateSolves.Count == 0, "no plate solves");

        t.Done(5);
    }

    [Fact]
    public void CalibrationFolderNames()
    {
        var t = new Checker(_output);
        foreach (var name in new[] { "Light", "Lights", "LIGHT", "Dark", "Darks", "Dark Flats", "Dark_Flats", "Flat", "Flats1x20", "Bias", "Biases", "Master Darks" })
            t.Expect(CaptureSorter.IsCalibrationFolder(name), $"{name} is a calibration folder");
        foreach (var name in new[] { "M31", "NGC 7000", "Lighthouse", "Darkness", "2026-10-07", "SharpCap Captures" })
            t.Expect(!CaptureSorter.IsCalibrationFolder(name), $"{name} is not a calibration folder");
        t.Done(18);
    }

    /// <summary>
    /// NN-observation folders copied straight into the Capture Folder are their own captures, not the Capture Folder;
    /// one with nothing left to sort stays in the scan but isn't listed.
    /// </summary>
    [Fact]
    public void ObservationFoldersAtTheTop()
    {
        var t = new Checker(_output);
        using var scratch = new Scratch();
        var captures = scratch["Captures"];
        File(captures, "04-observation-m92/01-images-initial/M92_0001.fits", Day(2025, 10, 7));
        File(captures, "04-observation-m92/Untitled.afphoto", Day(2025, 10, 7));
        File(captures, "05-observation-m13/M13_0001.fits", Day(2025, 10, 7));
        File(captures, "2026-09-14_07-20-55_plan_Demo_Night/01-observation-ngc7000/01-images-initial/NGC7000_0001.fits");
        File(captures, "06-observation-m57/01-images-initial/capture.json", Day(2025, 10, 7));

        CaptureSorter.SortExtensions = Extensions(SortFileTypes.Defaults);
        var entries = CaptureSorter.Scan(TelescopeKind.Vaonis, captures).Entries;
        var rows = ByObject(entries);
        t.Equal(rows.GetValueOrDefault("M92")?.CaptureFolder, "04-observation-m92", "top-level observation folder is its own capture");
        t.Equal(rows.GetValueOrDefault("M13")?.CaptureFolder, "05-observation-m13", "top-level observation folder without an images folder");
        t.Equal(rows.GetValueOrDefault("NGC7000")?.CaptureFolder, "2026-09-14_07-20-55_plan_Demo_Night", "a nested observation folder keeps its plan folder");
        t.Equal(entries.Count(e => e.CaptureFolder.Length == 0), 0, "no row is labelled with the Capture Folder");
        t.SequenceEqual(CaptureSorter.BackupPaths(rows.Where(r => r.Key == "M92").Select(r => r.Value).ToList(), captures),
            new[] { "04-observation-m92" }, "a backup takes the whole observation folder, .afphoto included");

        t.Equal(rows.GetValueOrDefault("M57")?.Files, 0, "an observation folder with nothing to sort still scans");
        var shown = CaptureSorter.RowsToShow(entries);
        t.SequenceEqual(shown.Select(e => e.Object).OrderBy(o => o, StringComparer.Ordinal), new[] { "M13", "M92", "NGC7000" }, "rows with no files aren't listed");
        t.Expect(shown.All(e => e.Files > 0), "every listed row has files");

        t.Done(8);
    }

    private static string CreditsSpec => Environment.GetEnvironmentVariable("STS_CREDITS_SPEC")
        ?? "/Volumes/Large Drive/Marketing Field Data/Shared/Credits-Popup-Spec.md";

    private static string AppAssets([CallerFilePath] string here = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(here)!, "..", "..", "src", "SmartTelescopeSort.App", "Assets"));

    /// <summary>
    /// The Credits popup follows the shared spec: logo, the four people in order, then names-only data sources with
    /// GitHub, each catalog being one the sorter really recognizes in folder names.
    /// </summary>
    [Fact]
    public void CreditsMatchSpec()
    {
        var t = new Checker(_output);
        var expectedPeople = new[]
        {
            "R Derry — Developer and Owner",
            "F Derry — Full Time Beta Tester",
            "Otto — Programming and Smoke Testing",
            "A Derry — Interface Consultant",
        };
        t.SequenceEqual(Credits.PeopleLines, expectedPeople, "people lines and order");
        var spec = System.IO.File.Exists(CreditsSpec) ? System.IO.File.ReadAllText(CreditsSpec) : null;
        var start = spec?.IndexOf("2. People", StringComparison.Ordinal) ?? -1;
        var end = start >= 0 ? spec!.IndexOf("3. Data sources", start + 9, StringComparison.Ordinal) : -1;
        if (start >= 0 && end >= 0)
        {
            var fromSpec = spec![(start + "2. People".Length)..end]
                .Split('\n')
                .Select(l => l.Trim())
                .Where(l => l.StartsWith("- ", StringComparison.Ordinal))
                .Select(l => l[2..])
                .ToList();
            t.SequenceEqual(Credits.PeopleLines, fromSpec, $"people lines match {Path.GetFileName(CreditsSpec)}");
        }
        else
        {
            t.Expect(false, $"spec readable with People and Data sources sections: {CreditsSpec}");
        }
        t.SequenceEqual(new[] { Credits.PeopleHeading, Credits.DataSourcesHeading }, new[] { "People", "Data sources" }, "section order");

        var logo = Path.Combine(AppAssets(), $"{Credits.LogoResource}.png");
        t.Expect(System.IO.File.Exists(logo), $"logo is bundled: {Path.GetFileName(logo)}");

        t.Equal(Credits.DataSources.FirstOrDefault(), "GitHub (open source, MIT license)", "GitHub listed first, with the MIT license");
        foreach (var line in Credits.PeopleLines.Concat(Credits.DataSources))
        {
            var lower = line.ToLowerInvariant();
            t.Expect(!new[] { "http", "://", "www.", ".com", ".org", "@" }.Any(lower.Contains), $"no link in \"{line}\"");
        }
        t.Equal(Credits.DataSources.Distinct().Count(), Credits.DataSources.Count, "no repeated data sources");

        var samples = new Dictionary<string, string>
        {
            ["Messier catalog"] = "M 31", ["New General Catalogue (NGC)"] = "NGC 891", ["Index Catalogue (IC)"] = "IC 1396",
            ["Sharpless catalog (Sh2)"] = "Sh2-155", ["Barnard catalog"] = "Barnard 33", ["Lynds Dark Nebulae (LDN)"] = "LDN 1622",
            ["Lynds Bright Nebulae (LBN)"] = "LBN 437", ["van den Bergh catalog (vdB)"] = "vdB 142", ["Abell catalog"] = "Abell 2151",
            ["Arp Atlas of Peculiar Galaxies"] = "Arp 273", ["Melotte catalog"] = "Mel 111", ["Collinder catalog"] = "Collinder 399",
            ["Uppsala General Catalogue (UGC)"] = "UGC 12158", ["Principal Galaxies Catalogue (PGC)"] = "PGC 2557",
            ["Caldwell catalog"] = "Caldwell 14",
        };
        t.SetEqual(Credits.DataSources.Skip(1), samples.Keys, "every listed catalog has a sample designation");
        using var scratch = new Scratch();
        var captures = scratch["Captures"];
        foreach (var folder in samples.Values) File(captures, $"{folder}/frame_0001.fits", Day(2026, 1, 10));
        CaptureSorter.SortExtensions = Extensions(SortFileTypes.Defaults);
        var entries = CaptureSorter.Scan(TelescopeKind.Vaonis, captures).Entries;
        t.Equal(entries.Count, samples.Count, "one row per catalog folder");
        foreach (var entry in entries) t.Expect(!entry.NeedsObjectName, $"{entry.CaptureFolder} is recognized as a catalog object");

        t.Done(43);
    }
}
