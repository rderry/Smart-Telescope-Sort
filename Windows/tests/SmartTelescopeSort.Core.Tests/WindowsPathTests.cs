using SmartTelescopeSort.Core.IO;
using SmartTelescopeSort.Core.Sorting;
using Xunit;

namespace SmartTelescopeSort.Core.Tests;

/// <summary>Drive letters, UNC shares, \\?\ paths, case-insensitivity and reserved names, on the Windows rules from any machine.</summary>
public sealed class WindowsPathTests
{
    private static readonly PathRules W = PathRules.Windows;

    [Theory]
    [InlineData(@"C:\Astro\Captures", 3)]
    [InlineData("C:/Astro", 3)]
    [InlineData("d:", 2)]
    [InlineData(@"\\NAS\Astro\Captures", 12)]
    [InlineData(@"\\NAS\Astro", 11)]
    [InlineData(@"\\?\C:\Astro", 7)]
    [InlineData(@"\\?\UNC\NAS\Astro\M31", 18)]
    [InlineData(@"\Astro", 1)]
    [InlineData(@"Astro\M31", 0)]
    [InlineData("", 0)]
    public void RootsAreDriveLettersSharesAndLongPathPrefixes(string path, int length) => Assert.Equal(length, W.RootLength(path));

    [Theory]
    [InlineData(@"c:/Astro//Captures/./M31/..", @"C:\Astro\Captures")]
    [InlineData(@"C:\Astro\Captures\", @"C:\Astro\Captures")]
    [InlineData("d:", @"D:\")]
    [InlineData(@"C:\..\Astro", @"C:\Astro")]
    [InlineData(@"\\NAS\Astro\Captures\\M31\", @"\\NAS\Astro\Captures\M31")]
    [InlineData("//NAS/Astro/M31", @"\\NAS\Astro\M31")]
    [InlineData(@"M31\..\..\x", @"..\x")]
    public void PathsNormalizeToOneSpelling(string path, string expected) => Assert.Equal(expected, W.Normalize(path));

    [Fact]
    public void ComparisonsIgnoreCaseLikeNtfs()
    {
        Assert.True(W.AreSame(@"C:\Astro\Captures\M31", @"c:\ASTRO\captures\m31\"));
        Assert.True(W.AreSame(@"\\nas\astro\M31", @"\\NAS\Astro\m31"));
        Assert.True(W.IsSameOrInside(@"c:\astro\captures\M31\a.fits", @"C:\Astro\Captures"));
        Assert.False(W.IsSameOrInside(@"C:\AstroX\M31", @"C:\Astro"));
        Assert.False(W.IsSameOrInside(@"D:\Astro\M31", @"C:\Astro"));
        Assert.Equal(@"M31\a.fits", W.RelativePath(@"C:\ASTRO\Captures\M31\a.fits", @"c:\astro\captures"));
        Assert.Equal("", W.RelativePath(@"c:\astro\captures\", @"C:\Astro\Captures"));

        var posix = PathRules.Posix;
        Assert.False(posix.AreSame("/Astro/M31", "/astro/m31"));
        Assert.Equal(StringComparer.OrdinalIgnoreCase, W.Comparer);
    }

    [Fact]
    public void RelativePathOutsideTheRootIsJustTheName() =>
        Assert.Equal("a.fits", W.RelativePath(@"D:\Other\a.fits", @"C:\Astro"));

    [Fact]
    public void BothSlashesSeparateNamesOnWindowsOnly()
    {
        Assert.Equal(new[] { "2026-10-07", "M42", "a.fits" }, W.Split(@"2026-10-07/M42\a.fits"));
        Assert.Equal(new[] { @"2026-10-07\M42" }, PathRules.Posix.Split(@"2026-10-07\M42"));
        Assert.Equal(@"\\NAS\Astro\Captures\M31\Light", W.Combine(@"\\NAS\Astro\Captures", "M31/Light"));
        Assert.Equal(@"D:\M31", W.Combine(@"D:\", "M31"));
    }

    [Fact]
    public void ParentsLastNamesAndDepthStopAtTheRoot()
    {
        Assert.Equal(@"C:\", W.Parent(@"C:\Astro"));
        Assert.Equal(@"C:\", W.Parent(@"C:\"));
        Assert.Equal(@"\\NAS\Astro\", W.Parent(@"\\NAS\Astro\M31"));
        Assert.True(W.IsRoot(@"\\NAS\Astro"));
        Assert.True(W.IsRoot("e:"));
        Assert.False(W.IsRoot(@"E:\Astro"));
        Assert.Equal("M31", W.LastComponent(@"\\?\C:\Astro\M31\"));
        Assert.Equal(2, W.Depth(@"\\NAS\Astro\Captures\M31"));
        Assert.Equal(0, W.Depth(@"C:\"));
    }

    [Theory]
    [InlineData(@"C:\Windows")]
    [InlineData("C:Windows")]
    [InlineData(@"\\NAS\Astro\M31")]
    [InlineData(@"\Windows")]
    [InlineData(@"..\Elsewhere")]
    [InlineData(@"M31\..\..\Elsewhere")]
    [InlineData("M31/../../Elsewhere")]
    [InlineData(@"Targets 2025\M31")]
    [InlineData(@"\\?\C:\Windows")]
    [InlineData("")]
    public void BackupAndCleanupPathsNeverLeaveTheCaptureFolder(string name) =>
        Assert.Null(CaptureSorter.CaptureFolderPath(name, @"D:\Astro\Captures", W));

    [Theory]
    [InlineData("M31", @"D:\Astro\Captures\M31")]
    [InlineData(@"2026-10-07\M42", @"D:\Astro\Captures\2026-10-07\M42")]
    [InlineData("2026-10-07/M42", @"D:\Astro\Captures\2026-10-07\M42")]
    public void CapturePathsStayInside(string name, string expected) =>
        Assert.Equal(expected, CaptureSorter.CaptureFolderPath(name, @"D:\Astro\Captures", W));

    [Theory]
    [InlineData("CON", true)]
    [InlineData("con", true)]
    [InlineData("Aux.fits", true)]
    [InlineData("NUL ", true)]
    [InlineData("COM1", true)]
    [InlineData("lpt9.txt", true)]
    [InlineData("COM¹", true)]
    [InlineData("CONSOLE", false)]
    [InlineData("M31", false)]
    [InlineData("COM10", false)]
    [InlineData("AUXILIARY", false)]
    public void ReservedDeviceNamesAreRecognized(string name, bool reserved) => Assert.Equal(reserved, WindowsNames.IsReserved(name));

    [Theory]
    [InlineData("M31: Andromeda?", "M31- Andromeda-")]
    [InlineData("  M31 / M32 . ", "M31 - M32")]
    [InlineData("CON", "CON_")]
    [InlineData("a<b>c|d*e\"f", "a-b-c-d-e-f")]
    [InlineData("...", "")]
    public void TypedNamesAreMadeSafe(string typed, string safe) => Assert.Equal(safe, WindowsNames.Safe(typed));

    [Theory]
    [InlineData("M31", "M31")]
    [InlineData("AUX", "AUX_")]
    [InlineData("NGC-7000.", "NGC-7000")]
    [InlineData("M31:A", "M31-A")]
    [InlineData("...", "_")]
    public void ObjectFolderNamesAreCreatable(string name, string segment) => Assert.Equal(segment, WindowsNames.SafeSegment(name));

    [Fact]
    public void BackupNamesAreSafeFileNames()
    {
        Assert.Equal("M31 M27 Backup 2026-10-03 15-27", CaptureSorter.BackupBaseName("M31 M27 Backup 2026-10-03 15:27.tar.gz"));
        Assert.Equal("a-b-c", CaptureSorter.BackupBaseName(@"a\b/c.zip"));
        Assert.Equal("PRN_", CaptureSorter.BackupBaseName("PRN"));
        Assert.StartsWith("TelescopeDataSort-Backup-", CaptureSorter.BackupBaseName("  "));
    }
}
