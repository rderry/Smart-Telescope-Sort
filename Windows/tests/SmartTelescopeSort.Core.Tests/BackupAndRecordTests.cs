using System.Formats.Tar;
using System.IO.Compression;
using SmartTelescopeSort.Core.Common;
using SmartTelescopeSort.Core.Manual;
using SmartTelescopeSort.Core.Settings;
using SmartTelescopeSort.Core.Sorting;
using SmartTelescopeSort.Core.Terms;
using Xunit;
using static SmartTelescopeSort.Core.Tests.Fixture;

namespace SmartTelescopeSort.Core.Tests;

public sealed class BackupTests
{
    private static Scratch Captures()
    {
        var s = new Scratch();
        File(s.Root, "Captures/M31/a.fits");
        File(s.Root, "Captures/M31/Light/b.fits");
        File(s.Root, "Captures/M31/._a.fits");
        File(s.Root, "Captures/2026-10-07/M42/c.tif");
        Directory.CreateDirectory(s["Backups"]);
        return s;
    }

    [Fact]
    public void ZipHoldsTheCaptureFoldersWithForwardSlashNames()
    {
        using var s = Captures();
        var archive = CaptureSorter.ArchiveCaptureFolders(new[] { "M31", P("2026-10-07/M42"), P("M31/Light") }, s["Captures"], s["Backups"],
                                                          BackupFormat.Zip, "M31 M42 Backup");
        Assert.Equal(s["Backups/M31 M42 Backup.zip"], archive);
        using var zip = ZipFile.OpenRead(archive!);
        var names = zip.Entries.Select(e => e.FullName).OrderBy(n => n, StringComparer.Ordinal).ToList();
        Assert.Equal(new[] { "2026-10-07/M42/", "2026-10-07/M42/c.tif", "M31/", "M31/Light/", "M31/Light/b.fits", "M31/a.fits" }, names);
    }

    [Fact]
    public void TarballRoundTripsAndANameInUseGetsANumber()
    {
        using var s = Captures();
        System.IO.File.WriteAllText(s["Backups/Nightly.tar.gz"], "taken");
        var archive = CaptureSorter.ArchiveCaptureFolders(new[] { "M31" }, s["Captures"], s["Backups"], BackupFormat.Tarball, "Nightly.tar.gz");
        Assert.Equal(s["Backups/Nightly 2.tar.gz"], archive);
        Assert.Equal("taken", System.IO.File.ReadAllText(s["Backups/Nightly.tar.gz"]));

        using var gzip = new GZipStream(System.IO.File.OpenRead(archive!), CompressionMode.Decompress);
        using var tar = new TarReader(gzip);
        var files = new Dictionary<string, string>();
        while (tar.GetNextEntry() is { } entry)
        {
            if (entry.EntryType is not (TarEntryType.RegularFile or TarEntryType.V7RegularFile)) continue;
            using var reader = new StreamReader(entry.DataStream!, leaveOpen: true);
            files[entry.Name] = reader.ReadToEnd();
        }
        Assert.Equal(new[] { "M31/Light/b.fits", "M31/a.fits" }, files.Keys.OrderBy(k => k, StringComparer.Ordinal));
        Assert.Equal("Captures/M31/a.fits", files["M31/a.fits"]);
    }

    [Fact]
    public void CancelledBackupLeavesNoPartialArchive()
    {
        using var s = Captures();
        var job = new ArchiveJob();
        job.Cancel();
        Assert.Throws<ArchiveJob.CancelledException>(() =>
            CaptureSorter.ArchiveCaptureFolders(new[] { "M31" }, s["Captures"], s["Backups"], BackupFormat.Zip, "Stopped", job));
        Assert.Empty(Directory.EnumerateFileSystemEntries(s["Backups"]));
    }

    [Fact]
    public void FolderBackupCopiesCaptureFoldersIntoANamedFolder()
    {
        using var s = Captures();
        CaptureSorter.SortExtensions = Extensions(SortFileTypes.Defaults);
        var entries = CaptureSorter.Scan(TelescopeKind.Vaonis, s["Captures"]).Entries;
        var summary = CaptureSorter.BackupCaptureFolders(entries, s["Captures"], s["Backups"], "Before sort");
        Assert.Equal(s["Backups/Before sort"], summary.Destination);
        Assert.True(System.IO.File.Exists(s["Backups/Before sort/M31/a.fits"]));
        Assert.True(System.IO.File.Exists(s["Backups/Before sort/2026-10-07/M42/c.tif"]));
        Assert.True(System.IO.File.Exists(s["Captures/M31/a.fits"]));
    }
}

public sealed class RecordAndSettingsTests
{
    [Fact]
    public void AgreementIsEncryptedReadableWithThePasswordAndNeverReplaced()
    {
        using var s = new Scratch();
        var record = new AgreementRecord(s.Root);
        Assert.False(record.IsAccepted);
        var at = new DateTimeOffset(2026, 10, 9, 21, 30, 0, TimeSpan.FromHours(-6));
        record.Record(new[] { "Back up first.", "BigSkyAstro is not responsible for the loss of data." }, at, "a4:83:e7:12:34:56");

        Assert.True(record.IsAccepted);
        var bytes = System.IO.File.ReadAllBytes(record.FilePath);
        Assert.True(LockedPdf.IsEncrypted(bytes));
        Assert.DoesNotContain("a4:83:e7", System.Text.Encoding.Latin1.GetString(bytes));
        Assert.Null(LockedPdf.ReadInfo(bytes, "wrong"));

        var contents = record.Read();
        Assert.NotNull(contents);
        Assert.Equal(AgreementRecord.TermsVersion, contents!.TermsVersion);
        Assert.Equal("2026-10-09T21:30:00-06:00", contents.AgreedAt);
        Assert.Equal("a4:83:e7:12:34:56", contents.MacAddress);
        Assert.Equal(AppInfo.Version, contents.AppVersion);
        Assert.Equal(at, record.AcceptedDate);

        record.Record(new[] { "Other terms" }, at.AddDays(1), "00:00:00:00:00:00");
        Assert.Equal(bytes, System.IO.File.ReadAllBytes(record.FilePath));
    }

    [Fact]
    public void SettingsRoundTripAndDefaultToTheMacChoices()
    {
        using var s = new Scratch();
        var store = new SettingsStore(s.Root);
        var defaults = store.Load();
        Assert.True(defaults.ShowAssumptionsAtLaunch);
        Assert.Equal("off", defaults.BackupFormat);
        Assert.False(defaults.DeleteJson);
        Assert.False(defaults.DeleteAstrometry);

        defaults.SetFolder(LibraryFolder.Originals, @"D:\Astro\Targets");
        defaults.SetFolder(LibraryFolder.Backup, @"\\NAS\Astro\Backups");
        defaults.BackupFormat = "tarball";
        store.Save(defaults);

        var loaded = new SettingsStore(s.Root).Load();
        Assert.Equal(@"D:\Astro\Targets", loaded.Folder(LibraryFolder.Originals));
        Assert.Equal(@"\\NAS\Astro\Backups", loaded.Folder(LibraryFolder.Backup));
        Assert.Equal("tarball", loaded.BackupFormat);
        Assert.False(System.IO.File.Exists(store.FilePath + ".tmp"));
    }

    [Fact]
    public void CorruptSettingsFallBackToDefaults()
    {
        using var s = new Scratch();
        System.IO.File.WriteAllText(Path.Combine(s.Root, "settings.json"), "{ not json");
        Assert.True(new SettingsStore(s.Root).Load().ShowAssumptionsAtLaunch);
    }
}

public sealed class ManualTests
{
    [Fact]
    public void BundledManualHasTheMacSectionsInWindowsTerms()
    {
        var manual = ManualContent.LoadBundled();
        var top = manual.Sections.Where(s => s.Level == 1).Select(s => s.Title.Split(' ')[0]).ToList();
        Assert.Equal(new[] { "1.", "2.", "3.", "4.", "5.", "6.", "7.", "8.", "9.", "10." }, top);
        var text = string.Join("\n", manual.Sections.SelectMany(s => s.Blocks)
            .SelectMany(b => (b.Items ?? new List<string>()).Append(b.Text ?? "").Concat((b.Rows ?? new()).SelectMany(r => r))));
        Assert.Contains("File Explorer", text);
        Assert.Contains("Recycle Bin", text);
        Assert.Contains(@"D:\Astro", text);
        foreach (var mac in new[] { "Finder", "⌘", "Trash", "~/", "macOS" }) Assert.DoesNotContain(mac, text);
        Assert.Contains("not affiliated", text);
        Assert.Contains("Based on Smart Telescope Sort by BigSkyAstro", text);
    }

    [Fact]
    public void InlineMarksSplitIntoRuns()
    {
        var runs = ManualContent.Runs("Press **Sort** in `Targets {year}` *now*.");
        Assert.Equal(new[]
        {
            ("Press ", ManualContent.Mark.Plain), ("Sort", ManualContent.Mark.Bold), (" in ", ManualContent.Mark.Plain),
            ("Targets {year}", ManualContent.Mark.Code), (" ", ManualContent.Mark.Plain), ("now", ManualContent.Mark.Italic),
            (".", ManualContent.Mark.Plain),
        }, runs);
        Assert.Equal("Press Sort in Targets {year} now.", ManualContent.Plain("Press **Sort** in `Targets {year}` *now*."));
    }
}
