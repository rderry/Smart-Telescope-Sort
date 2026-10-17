using SmartTelescopeSort.Core.Sorting;
using Xunit;

namespace SmartTelescopeSort.Core.Tests;

public sealed class TargetsLocationTests
{
    [Fact]
    public void ChosenTargetFolderIsUsedAndATargetsYearFolderMeansItsParent()
    {
        using var s = new Scratch();
        Directory.CreateDirectory(s["Library/Targets 2025"]);
        Directory.CreateDirectory(s["Captures"]);
        Assert.Equal(s["Library"], TargetsLocation.Resolve(s["Library"], s["Captures"]));
        Assert.Equal(s["Library"], TargetsLocation.Resolve(s["Library/Targets 2025"], s["Captures"]));
        Assert.Equal((Fixture.P($"Sorted images go to {s.Root}/Library/Targets {{year}}/{{object}}."), false),
                     TargetsLocation.Note(s["Library"], s["Captures"]));
    }

    [Fact]
    public void ShownNamesTheFolderImagesAreSetTo()
    {
        using var s = new Scratch();
        Directory.CreateDirectory(s["Library"]);
        Directory.CreateDirectory(s["Captures"]);
        Assert.Equal($"Set to {Fixture.P($"{s.Root}/Library/Targets {{year}}/{{object}}")}",
            TargetsLocation.Shown(s["Library"], s["Captures"]));
        Assert.Equal($"Set to {Fixture.P($"{s.Root}/Captures/Targets {{year}}/{{object}}")}",
            TargetsLocation.Shown(null, s["Captures"]));
        Assert.Equal("No location set — choose a Capture Folder or a Target Folder.", TargetsLocation.Shown(null, ""));
    }

    [Fact]
    public void WithoutAChoiceTargetsGoInsideTheCaptureFolder()
    {
        using var s = new Scratch();
        Directory.CreateDirectory(s["Captures"]);
        Assert.Equal(s["Captures"], TargetsLocation.Resolve(null, s["Captures"]));
        Assert.Null(TargetsLocation.Note(null, ""));
    }

    [Fact]
    public void AFolderBelowTheOneHoldingTargetsClimbsUpWithAWarning()
    {
        using var s = new Scratch();
        Directory.CreateDirectory(s["Astro/Targets 2026"]);
        Directory.CreateDirectory(s["Astro/Captures/M31"]);
        Assert.Equal(s["Astro"], TargetsLocation.Resolve(s["Astro/Captures/M31"], s["Astro/Captures"]));
        var note = TargetsLocation.Note(s["Astro/Captures/M31"], s["Astro/Captures"]);
        Assert.True(note?.Warning);
        Assert.Contains("inside the Capture Folder", note?.Text);
    }
}
