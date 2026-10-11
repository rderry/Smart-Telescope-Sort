using SmartTelescopeSort.Core.IO;
using SmartTelescopeSort.Core.Sorting;
using Xunit;
using static SmartTelescopeSort.Core.Tests.Fixture;

namespace SmartTelescopeSort.Core.Tests;

/// <summary>Copy, check, then delete: nothing in Targets is replaced, and originals go only when asked.</summary>
public sealed class SortingBehaviourTests
{
    public SortingBehaviourTests() => CaptureSorter.SortExtensions = Extensions(SortFileTypes.Defaults);

    private static List<CaptureEntry> Scan(string captures, string targets) =>
        CaptureSorter.Scan(TelescopeKind.Vaonis, captures, targets).Entries.ToList();

    [Fact]
    public void DifferentFileWithTheSameNameGetsANumberAndTargetsIsNeverOverwritten()
    {
        using var s = new Scratch();
        File(s.Root, "Captures/M31/IMG_0001.fits", Day(2025, 11, 3));
        var existing = File(s.Root, "Library/Targets 2025/M31/IMG_0001.fits");
        var before = System.IO.File.ReadAllBytes(existing);

        var entries = Scan(s["Captures"], s["Library"]);
        var (plans, summary) = CaptureSorter.Preview(entries);
        Assert.Equal(1, summary.Move);
        Assert.Equal(s["Library/Targets 2025/M31/IMG_0001 2.fits"], Assert.Single(plans).Destination);

        var copied = CaptureSorter.CopySort(entries, s["Captures"], s["Library"]);
        Assert.Null(copied.Error);
        Assert.Equal(before, System.IO.File.ReadAllBytes(existing));
        Assert.True(FileOps.ContentsEqual(s["Captures/M31/IMG_0001.fits"], s["Library/Targets 2025/M31/IMG_0001 2.fits"]));
    }

    [Fact]
    public void ByteIdenticalCopiesAreDuplicatesEvenUnderANumberedName()
    {
        using var s = new Scratch();
        var source = File(s.Root, "Captures/M31/IMG_0001.fits", Day(2025, 11, 3));
        var target = s["Library/Targets 2025/M31/IMG_0001 2.fits"];
        Directory.CreateDirectory(Path.GetDirectoryName(target)!);
        System.IO.File.Copy(source, target);

        var entries = Scan(s["Captures"], s["Library"]);
        var (plans, summary) = CaptureSorter.Preview(entries);
        Assert.Equal(0, summary.Move);
        Assert.Equal(1, summary.Duplicate);
        var plan = Assert.Single(plans);
        Assert.Equal(target, plan.Destination);
        Assert.Equal("Duplicate", plan.ActionLabel);

        var cleanup = CaptureSorter.DeleteDuplicates(plans, s["Captures"]);
        Assert.Equal(1, cleanup.Deleted);
        Assert.False(System.IO.File.Exists(source));
        Assert.True(System.IO.File.Exists(target));
        Assert.Equal(1, cleanup.RemovedFolders);
    }

    [Fact]
    public void CopySortKeepsEveryOriginalAndItsDate()
    {
        using var s = new Scratch();
        var source = File(s.Root, "Captures/2026-10-07/M42/M42_0001.fits", Day(2026, 10, 8));
        var copied = CaptureSorter.CopySort(Scan(s["Captures"], s["Library"]), s["Captures"], s["Library"]);
        var item = Assert.Single(copied.Copied);
        Assert.Equal(source, item.Original);
        Assert.True(System.IO.File.Exists(source));
        Assert.Equal(System.IO.File.GetLastWriteTimeUtc(source), System.IO.File.GetLastWriteTimeUtc(item.Copy));
        Assert.Equal(s["Library/Targets 2026/M42/M42_0001.fits"], item.Copy);
    }

    [Fact]
    public void ReadOnlyOriginalsAreCopiedAndDeletedOnlyWhenAsked()
    {
        using var s = new Scratch();
        var source = File(s.Root, "Captures/M31/M31_0001.fits", Day(2025, 11, 3));
        System.IO.File.SetAttributes(source, FileAttributes.ReadOnly);

        var copied = CaptureSorter.CopySort(Scan(s["Captures"], s["Library"]), s["Captures"], s["Library"]);
        Assert.Null(copied.Error);
        var item = Assert.Single(copied.Copied);
        Assert.True(FileOps.ContentsEqual(source, item.Copy));
        Assert.True(System.IO.File.Exists(source));

        var (deleted, skipped) = CaptureSorter.DeleteOriginals(copied.Copied);
        Assert.Equal(1, deleted);
        Assert.Empty(skipped);
        Assert.False(System.IO.File.Exists(source));
        Assert.True(System.IO.File.Exists(item.Copy));
    }

    [Fact]
    public void OriginalsWhoseCopyIsMissingOrDifferentAreKept()
    {
        using var s = new Scratch();
        var a = File(s.Root, "Captures/M31/a.fits");
        var b = File(s.Root, "Captures/M31/b.fits");
        var shortCopy = File(s.Root, "Library/b.fits");
        System.IO.File.WriteAllBytes(shortCopy, new byte[] { 1 });
        var items = new[]
        {
            new CopiedItem(a, s["Library/missing.fits"], false),
            new CopiedItem(b, shortCopy, false),
        };
        var (deleted, skipped) = CaptureSorter.DeleteOriginals(items);
        Assert.Equal(0, deleted);
        Assert.Equal(new[] { a, b }, skipped);
        Assert.True(System.IO.File.Exists(a) && System.IO.File.Exists(b));
    }

    [Fact]
    public void StoppedCopyMovesAndDeletesNothing()
    {
        using var s = new Scratch();
        var source = File(s.Root, "Captures/M31/M31_0001.fits", Day(2025, 11, 3));
        var monitor = new TransferMonitor(_ => { });
        monitor.Cancel();
        var copied = CaptureSorter.CopySort(Scan(s["Captures"], s["Library"]), s["Captures"], s["Library"], monitor);
        Assert.Empty(copied.Copied);
        Assert.True(System.IO.File.Exists(source));
        Assert.False(System.IO.File.Exists(s["Library/Targets 2025/M31/M31_0001.fits"]));
    }

    [Fact]
    public void NamesDifferingOnlyInCaseNeverLandOnTheSameFile()
    {
        using var s = new Scratch();
        File(s.Root, "Captures/2026-10-01/M31/img_0001.fits");
        File(s.Root, "Captures/2026-10-02/M31/IMG_0001.FITS");
        var entries = Scan(s["Captures"], s["Library"]);
        var (plans, _) = CaptureSorter.Preview(entries);
        Assert.Equal(2, plans.Count);
        Assert.Equal(2, plans.Select(p => p.Destination.ToLowerInvariant()).Distinct().Count());
        Assert.Contains(plans, p => Path.GetFileName(p.Destination) == "IMG_0001 2.FITS");

        var copied = CaptureSorter.CopySort(entries, s["Captures"], s["Library"]);
        Assert.Equal(2, copied.Copied.Count);
        Assert.Empty(copied.Failed);
    }

    [Fact]
    public void PathsLongerThan260CharactersSort()
    {
        using var s = new Scratch();
        var deep = string.Join('/', Enumerable.Range(1, 6).Select(i => $"session-{i:00}-" + new string('x', 48)));
        var relative = $"Captures/{deep}/M31/M31_frame_with_a_long_name_0001.fits";
        var source = File(s.Root, relative, Day(2025, 11, 3));
        Assert.True(source.Length > 300, $"path is {source.Length} characters");

        var entries = Scan(s["Captures"], s["Library"]);
        Assert.Equal("M31", Assert.Single(entries).Object);
        var copied = CaptureSorter.CopySort(entries, s["Captures"], s["Library"]);
        Assert.True(FileOps.ContentsEqual(source, Assert.Single(copied.Copied).Copy));
        var (deleted, skipped) = CaptureSorter.DeleteOriginals(copied.Copied);
        Assert.Equal(0, deleted);
        Assert.Equal(new[] { source }, skipped);
        Assert.True(System.IO.File.Exists(source));
        using (FileOps.AllowPermanentDelete(new[] { source }))
            (deleted, _) = CaptureSorter.DeleteOriginals(copied.Copied);
        Assert.Equal(1, deleted);
    }

    [Fact]
    public void SpentFoldersHoldingJsonWaitForPermissionAndOtherFilesKeepThem()
    {
        using var s = new Scratch();
        File(s.Root, "Captures/A/session.json");
        File(s.Root, "Captures/B/notes.afphoto");
        File(s.Root, "Captures/C/astrometry.dat");
        Directory.CreateDirectory(s["Captures/D"]);

        var names = new[] { "A", "B", "C", "D" };
        var cleanup = CaptureSorter.RemoveSpentCaptureFolders(names, s["Captures"]);
        Assert.Equal(1, cleanup.Removed);
        Assert.Equal(new[] { "A", "C" }, cleanup.Held.Keys.OrderBy(k => k));
        Assert.Equal(1, cleanup.Held["A"].Json);
        Assert.Equal(1, cleanup.Held["C"].Astrometry);
        Assert.Equal(1, cleanup.Kept["B"]["afphoto"]);

        var allowed = CaptureSorter.RemoveSpentCaptureFolders(names, s["Captures"], new DeletePermissions(Json: true, Astrometry: true));
        Assert.Equal(2, allowed.Removed);
        Assert.True(Directory.Exists(s["Captures/B"]));
        Assert.True(Directory.Exists(s["Captures"]));
    }

    [Fact]
    public void HiddenFilesAreNeverSorted()
    {
        using var s = new Scratch();
        File(s.Root, "Captures/M31/._M31_0001.fits");
        File(s.Root, "Captures/M31/M31_0001.fits", Day(2025, 11, 3));
        var entry = Assert.Single(Scan(s["Captures"], s["Library"]));
        Assert.Equal(1, entry.Files);
    }

    [Fact]
    public void TargetsFoldersAreNeverASource()
    {
        using var s = new Scratch();
        File(s.Root, "Captures/Targets 2025/M31/M31_0001.fits");
        File(s.Root, "Captures/M33/M33_0001.fits", Day(2025, 11, 3));
        Assert.Equal(new[] { "M33" }, Scan(s["Captures"], s["Captures"]).Select(e => e.Object));
    }

    [Theory]
    [InlineData("25")]
    [InlineData("20255")]
    [InlineData("abcd")]
    public void TargetYearsMustBeFourDigits(string year)
    {
        using var s = new Scratch();
        Assert.Throws<ArgumentException>(() => CaptureSorter.CreateTargetsFolder(year, s.Root));
    }

    [Fact]
    public void IdenticalCopiesInTargetsKeepTheUnnumberedFile()
    {
        using var s = new Scratch();
        var keep = File(s.Root, "Targets 2025/M31/IMG_0001.fits");
        var extra = s["Targets 2025/M31/IMG_0001 2.fits"];
        System.IO.File.Copy(keep, extra);
        File(s.Root, "Targets 2025/M31/IMG_0002 2.fits");
        var plate = s["Targets 2025/M31/Plate Solves/x/IMG_0001 3.fits"];
        Directory.CreateDirectory(Path.GetDirectoryName(plate)!);
        System.IO.File.Copy(keep, plate);

        var sets = CaptureSorter.FindRedundantCopies(s.Root);
        var set = Assert.Single(sets);
        Assert.Equal(keep, set.Keep);
        Assert.Equal(new[] { extra }, set.Extras);

        var (deleted, _, skipped) = CaptureSorter.RemoveRedundantCopies(sets);
        Assert.Equal(1, deleted);
        Assert.Empty(skipped);
        Assert.True(System.IO.File.Exists(keep) && System.IO.File.Exists(plate));
    }

    [Fact]
    public void DetectedLayoutsFollowTheMacVotes()
    {
        using var s = new Scratch();
        File(s.Root, "Vaonis/2026-09-10_22-15-03_observation_M31/01-images-initial/img-0001.tiff");
        Assert.Equal(TelescopeKind.Vaonis, TelescopeKinds.Detect(s["Vaonis"]));
        File(s.Root, "Origin/M31_2026-09-05/raw_0001.fits");
        Assert.Equal(TelescopeKind.Origin, TelescopeKinds.Detect(s["Origin"]));
    }
}
