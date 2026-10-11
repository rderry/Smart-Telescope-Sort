using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;
using SmartTelescopeSort.Core.Common;
using SmartTelescopeSort.Core.Manual;
using Xunit;

namespace SmartTelescopeSort.Core.Tests;

/// <summary>Screen readers name list rows from ToString(), so no row may read as a type name.</summary>
public sealed class AccessibleNameTests
{
    [Fact]
    public void CaptureRowReadsLikeTheTable()
    {
        Assert.Equal(@"Origin\M31_2026-09-05, M31, 2026-09, 4 files, 4 duplicates, to Targets 2026\M31",
            AccessibleNames.CaptureRow(@"Origin\M31_2026-09-05", "M31", "2026", "09", 4, "4 duplicates", @"Targets 2026\M31"));
        Assert.Contains(", 1 file,", AccessibleNames.CaptureRow("a", "M42", "2026", "09", 1, "1 new", @"Targets 2026\M42"));
    }

    [Fact]
    public void PlanFileReadsLikeThePlan()
    {
        Assert.Equal(@"light_001.fits, NGC6888, 2026-09-09 22:10, New, to Targets 2026\NGC6888",
            AccessibleNames.PlanFile("light_001.fits", "NGC6888", "2026-09-09 22:10", "New", @"Targets 2026\NGC6888"));
    }

    [Fact]
    public void ManualSectionsReadAsTheirTitles()
    {
        var sections = ManualContent.LoadBundled().Sections;
        Assert.NotEmpty(sections);
        foreach (var section in sections)
        {
            Assert.Equal(ManualContent.Plain(section.Title), section.ToString());
            Assert.DoesNotContain("SmartTelescopeSort", section.ToString());
        }
    }

    /// <summary>The app's list item types (the WPF project isn't referenced here, so this reads their source).</summary>
    [Theory]
    [InlineData(@"ViewModels/MainViewModel.cs", "class EntryRow")]
    [InlineData(@"ViewModels/MainViewModel.cs", "record Choice")]
    [InlineData(@"ViewModels/MainViewModel.cs", "record StatusLight")]
    [InlineData(@"Dialogs/PlanReviewWindow.xaml.cs", "record PlanRow")]
    [InlineData(@"Shell/MainWindow.xaml.cs", "record HowItWorksLine")]
    public void AppListItemsOverrideToString(string file, string declaration)
    {
        var source = File.ReadAllText(Path.Combine(AppSource(), file));
        var at = source.IndexOf(declaration, StringComparison.Ordinal);
        Assert.True(at >= 0, $"{declaration} not found in {file}");
        var next = Regex.Match(source[(at + declaration.Length)..], @"\n(public|internal) (sealed )?(partial )?(class|record|enum|static) ");
        var body = next.Success ? source.Substring(at, declaration.Length + next.Index) : source[at..];
        Assert.Contains("public override string ToString()", body);
    }

    /// <summary>Table cells drawn by a template have no text of their own, so each template column names its cells.</summary>
    [Theory]
    [InlineData(@"Shell/MainWindow.xaml")]
    [InlineData(@"Dialogs/PlanReviewWindow.xaml")]
    public void TemplateColumnsNameTheirCells(string file)
    {
        var xaml = File.ReadAllText(Path.Combine(AppSource(), file));
        var columns = Regex.Matches(xaml, @"<DataGridTemplateColumn [\s\S]*?</DataGridTemplateColumn>");
        Assert.NotEmpty(columns);
        foreach (Match column in columns)
            Assert.Contains("AutomationProperties.Name", column.Value);
    }

    private static string AppSource([CallerFilePath] string here = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(here)!, "..", "..", "src", "SmartTelescopeSort.App"));
}

public sealed class ManualRouteTests
{
    private const string Pdf = @"C:\Program Files\WindowsApps\Pkg\Assets\Telescope-Data-Sort-User-Manual.pdf";
    private const string Edge = @"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe";
    private const string Chrome = @"C:\Program Files\Google\Chrome\Application\chrome.exe";

    [Fact]
    public void ReportedPdfAppIsStartedDirectlyBeforeTheShell()
    {
        var steps = ManualRoute.Plan(Pdf, Edge, Edge, Chrome);
        Assert.Equal(Edge, steps[0].Program);
        Assert.Equal(Pdf, steps[0].Argument);
        Assert.Equal(Chrome, steps[1].Program);
        Assert.True(steps[^1].IsShell);
        Assert.Equal(3, steps.Count);
    }

    [Fact]
    public void OtherPdfAppThenEdge()
    {
        var acrobat = @"C:\Program Files\Adobe\Acrobat DC\Acrobat\Acrobat.exe";
        var steps = ManualRoute.Plan(Pdf, $"\"{acrobat}\"", Edge, Edge);
        Assert.Equal(new[] { acrobat, Edge, null }, steps.Select(s => s.Program));
        Assert.StartsWith("file:///", steps[1].Argument);
    }

    [Fact]
    public void NoPdfAppOrOnlyThePickerGoesToEdge()
    {
        foreach (var handler in new[] { null, "", @"C:\WINDOWS\system32\OpenWith.exe", "\"C:\\Windows\\System32\\OPENWITH.EXE\"" })
        {
            var steps = ManualRoute.Plan(Pdf, handler, Edge, Chrome);
            Assert.Equal(new[] { Edge, Chrome, null }, steps.Select(s => s.Program));
            Assert.StartsWith("file:///", steps[0].Argument);
        }
    }

    [Fact]
    public void ShellOnlyWhenNothingElseCanShowIt()
    {
        var steps = ManualRoute.Plan(Pdf, null, null, @"C:\WINDOWS\system32\OpenWith.exe");
        Assert.Single(steps);
        Assert.True(steps[0].IsShell);
        Assert.Equal(Pdf, steps[0].Argument);
    }

    [Fact]
    public void FileUrlEscapesSpaces()
    {
        var url = ManualRoute.FileUrl(Path.Combine(Path.GetTempPath(), "Telescope Data Sort", "Manual.pdf"));
        Assert.StartsWith("file:///", url);
        Assert.Contains("Telescope%20Data%20Sort", url);
    }
}
