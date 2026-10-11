using SmartTelescopeSort.Core.IO;
using SmartTelescopeSort.Core.Sorting;
using Xunit;

namespace SmartTelescopeSort.Core.Tests;

/// <summary>
/// Items the Recycle Bin can't take (full path of 260 characters or more) are never deleted permanently unless the user
/// agreed to it separately; by default they are kept and reported as skipped.
/// </summary>
public class LongPathDeleteTests
{
    private static string Write(string path, string text = "image")
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, text);
        return path;
    }

    /// <summary>A folder under `root` deep enough that a file inside it has a path of 260 characters or more.</summary>
    private static string DeepFolder(string root)
    {
        var folder = Path.Combine(root, "Session", new string('a', 100), new string('b', 100));
        Assert.True(Path.Combine(folder, "light_0001.fits").Length >= FileOps.RecycleBinPathLimit);
        return folder;
    }

    [Fact]
    public void ShortPathsCanGoToTheRecycleBin()
    {
        using var scratch = new Scratch();
        var file = Write(scratch["Session/M31/light_0001.fits"]);
        Assert.Empty(FileOps.TooLongForRecycleBin(file));
        Assert.Empty(FileOps.TooLongForRecycleBin(scratch["Session"]));
        Assert.Empty(FileOps.TooLongForRecycleBin(scratch["Missing/file.fits"]));
    }

    [Fact]
    public void ListsTheLongFileAndTheOutermostLongItemsInAFolder()
    {
        using var scratch = new Scratch();
        var deep = DeepFolder(scratch.Root);
        var file = Write(Path.Combine(deep, "light_0001.fits"));
        Write(scratch["Session/short.fits"]);

        Assert.Equal(new[] { Path.GetFullPath(file) }, FileOps.TooLongForRecycleBin(file));
        var inSession = FileOps.TooLongForRecycleBin(scratch["Session"]);
        Assert.Single(inSession);
        Assert.True(inSession[0].Length >= FileOps.RecycleBinPathLimit);
        Assert.StartsWith(Path.GetFullPath(scratch["Session"]), inSession[0], StringComparison.Ordinal);
    }

    [Fact]
    public void LongFileIsKeptUnlessPermanentDeletionWasAgreed()
    {
        using var scratch = new Scratch();
        var file = Write(Path.Combine(DeepFolder(scratch.Root), "light_0001.fits"));

        var kept = Assert.Throws<LongPathKeptException>(() => FileOps.TrashOrDelete(file));
        Assert.IsAssignableFrom<IOException>(kept);
        Assert.True(File.Exists(file));

        using (FileOps.AllowPermanentDelete(new[] { file }))
            FileOps.TrashOrDelete(file);
        Assert.False(File.Exists(file));
    }

    [Fact]
    public void FolderHoldingALongPathIsKeptWholeUnlessAgreed()
    {
        using var scratch = new Scratch();
        var deep = Write(Path.Combine(DeepFolder(scratch.Root), "light_0001.fits"));
        var sibling = Write(scratch["Session/short.fits"]);
        var session = scratch["Session"];

        Assert.Throws<LongPathKeptException>(() => FileOps.TrashOrDelete(session));
        Assert.True(File.Exists(deep));
        Assert.True(File.Exists(sibling));

        using (FileOps.AllowPermanentDelete(new[] { session + Path.DirectorySeparatorChar }))
            FileOps.TrashOrDelete(session);
        Assert.False(Directory.Exists(session));
    }

    [Fact]
    public void PermissionCoversOnlyTheAgreedItemsAndEndsWithTheScope()
    {
        using var scratch = new Scratch();
        var deep = DeepFolder(scratch.Root);
        var first = Write(Path.Combine(deep, "light_0001.fits"));
        var second = Write(Path.Combine(deep, "light_0002.fits"));
        var third = Write(Path.Combine(deep, "light_0003.fits"));

        using (FileOps.AllowPermanentDelete(new[] { first }))
        {
            FileOps.TrashOrDelete(first);
            Assert.Throws<LongPathKeptException>(() => FileOps.TrashOrDelete(second));
        }
        Assert.Throws<LongPathKeptException>(() => FileOps.TrashOrDelete(third));
        Assert.False(File.Exists(first));
        Assert.True(File.Exists(second));
        Assert.True(File.Exists(third));
    }

    [Fact]
    public async Task PermissionFlowsIntoBackgroundWork()
    {
        using var scratch = new Scratch();
        var file = Write(Path.Combine(DeepFolder(scratch.Root), "light_0001.fits"));
        using (FileOps.AllowPermanentDelete(new[] { file }))
            await Task.Run(() => FileOps.TrashOrDelete(file));
        Assert.False(File.Exists(file));
    }

    [Fact]
    public void DeleteOriginalsSkipsLongOriginalsByDefault()
    {
        using var scratch = new Scratch();
        var deep = DeepFolder(scratch.Root);
        var longOriginal = Write(Path.Combine(deep, "light_0001.fits"));
        var shortOriginal = Write(scratch["Session/M31/stacked.fits"]);
        var longCopy = Write(scratch["Targets 2026/M31/light_0001.fits"]);
        var shortCopy = Write(scratch["Targets 2026/M31/stacked.fits"]);
        var items = new[] { new CopiedItem(longOriginal, longCopy, false), new CopiedItem(shortOriginal, shortCopy, false) };

        var (deleted, skipped) = CaptureSorter.DeleteOriginals(items);
        Assert.Equal(1, deleted);
        Assert.Equal(new[] { longOriginal }, skipped);
        Assert.True(File.Exists(longOriginal));
        Assert.False(File.Exists(shortOriginal));

        using (FileOps.AllowPermanentDelete(new[] { longOriginal }))
            (deleted, skipped) = CaptureSorter.DeleteOriginals(items.Take(1).ToList());
        Assert.Equal(1, deleted);
        Assert.Empty(skipped);
        Assert.False(File.Exists(longOriginal));
        Assert.True(File.Exists(longCopy));
    }
}
