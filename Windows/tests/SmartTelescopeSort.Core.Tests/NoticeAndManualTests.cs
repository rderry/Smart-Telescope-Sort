using System.IO.Compression;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.RegularExpressions;
using SmartTelescopeSort.Core.Common;
using SmartTelescopeSort.Core.Manual;
using SmartTelescopeSort.Core.Sorting;
using Xunit;

namespace SmartTelescopeSort.Core.Tests;

/// <summary>
/// The bold "not tested with other telescopes" notice opens the main window and page 1 of the manual, word for word as
/// on the Mac; no "© 2026 BigSkyAstro" line is left; the manual carries the same screenshots as the Mac manual.
/// </summary>
public sealed class NoticeAndManualTests
{
    private const string Notice =
        "This has not been tested with other telescopes, but there is no reason it will not work with almost any data that it supports!";

    [Fact]
    public void NoticeWordingMatchesTheMac()
    {
        Assert.Equal(Notice, TelescopeKinds.UntestedNotice);
        Assert.Equal(Notice, ManualContent.LoadBundled().Notice);
    }

    [Fact]
    public void MainWindowOpensWithTheBoldNotice()
    {
        var xaml = File.ReadAllText(Path.Combine(Root(), "src", "SmartTelescopeSort.App", "Shell", "MainWindow.xaml"));
        var notice = Regex.Match(xaml, @"<TextBlock x:Name=""UntestedNotice""[^>]*/>");
        Assert.True(notice.Success, "MainWindow.xaml has the UntestedNotice TextBlock");
        Assert.Contains(@"Text=""{x:Static sorting:TelescopeKinds.UntestedNotice}""", notice.Value);
        Assert.Contains(@"FontWeight=""Bold""", notice.Value);
        Assert.True(notice.Index < xaml.IndexOf("<!-- Sidebar -->", StringComparison.Ordinal), "the notice comes before the sidebar and workspace");
        Assert.Contains(@"<Border Grid.Row=""1""", xaml[..notice.Index]);
    }

    [Fact]
    public void ManualWindowShowsTheNoticeInBold()
    {
        var code = File.ReadAllText(Path.Combine(Root(), "src", "SmartTelescopeSort.App", "Dialogs", "ManualWindow.cs"));
        var at = code.IndexOf("new Run(manual.Notice)", StringComparison.Ordinal);
        Assert.True(at > 0, "ManualWindow adds manual.Notice");
        Assert.Contains("FontWeight = FontWeights.Bold", code.Substring(at, 200));
        Assert.True(at < code.IndexOf("foreach (var section in manual.Sections)", StringComparison.Ordinal), "the notice comes before the sections");
    }

    public static IEnumerable<object[]> TextFiles()
    {
        var root = Root();
        var src = Directory.EnumerateFiles(Path.Combine(root, "src"), "*", SearchOption.AllDirectories)
            .Where(f => !f.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}")
                        && !f.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}"))
            .Where(f => new[] { ".cs", ".xaml", ".csproj", ".json", ".manifest" }.Contains(Path.GetExtension(f)));
        var other = new[] { Path.Combine(root, "scripts", "build-user-manual.py"), Path.Combine(root, "installer", "Store", "AppxManifest.xml") };
        return src.Concat(other).Select(f => new object[] { Path.GetRelativePath(root, f) });
    }

    [Theory]
    [MemberData(nameof(TextFiles))]
    public void NoCopyrightLine(string file)
    {
        var text = File.ReadAllText(Path.Combine(Root(), file));
        Assert.DoesNotContain("©", text);
        Assert.DoesNotContain("2026 BigSkyAstro", text);
    }

    [Fact]
    public void AboutSaysOpenSourceFreeware()
    {
        Assert.Equal("Open-source freeware", AppInfo.Freeware);
        Assert.DoesNotContain("Copyright", AppInfo.MitNotice);
        Assert.StartsWith(AppInfo.Freeware, AppInfo.MitNotice);
        var csproj = File.ReadAllText(Path.Combine(Root(), "src", "SmartTelescopeSort.App", "SmartTelescopeSort.App.csproj"));
        Assert.Contains("<Copyright>Open-source freeware</Copyright>", csproj);
    }

    /// <summary>The Mac manual's four figures: the main window, Review file plan, a backup running and a finished folder.</summary>
    [Fact]
    public void ManualFiguresAreBundled()
    {
        var manual = ManualContent.LoadBundled();
        var names = manual.Sections.SelectMany(s => s.Blocks).Where(b => b.Type == "figure").Select(b => b.Image!)
            .Prepend(manual.Cover?.Image ?? "").ToList();
        Assert.Equal(new[] { "01-main", "02-review-file-plan", "04-backup-progress", "05-finished-folder" }, names);
        foreach (var name in names)
            Assert.True(File.Exists(Path.Combine(Root(), "src", "SmartTelescopeSort.App", "Assets", "Manual", $"{name}.png")), $"Assets/Manual/{name}.png");
    }

    [Fact]
    public void PdfManualOpensWithTheNoticeAndHasTheFigures()
    {
        var pdf = Path.Combine(Root(), "src", "SmartTelescopeSort.App", "Assets", "Telescope-Data-Sort-User-Manual.pdf");
        var text = Regex.Replace(PdfText(pdf), @"\s+", " ");
        var firstSection = text.IndexOf("1. Assumptions", StringComparison.Ordinal);
        Assert.True(firstSection > 0, "the PDF text is readable");
        Assert.Contains(Notice, text[..firstSection]);
        Assert.DoesNotContain("©", text);
        Assert.Contains("Open-source freeware", text);

        var images = Regex.Matches(Encoding.Latin1.GetString(File.ReadAllBytes(pdf)), @"/Subtype /Image").Count;
        Assert.True(images >= 5, $"logo and four screenshots embedded, found {images} images");

        var script = File.ReadAllText(Path.Combine(Root(), "scripts", "build-user-manual.py"));
        Assert.Matches(@"""notice"": ParagraphStyle\(""notice"", parent=base\[""Normal""\], fontName=""Helvetica-Bold""", script);
    }

    /// <summary>Text shown with Tj in the PDF's page streams (reportlab writes them ASCII85 + Flate encoded).</summary>
    private static string PdfText(string path)
    {
        var raw = Encoding.Latin1.GetString(File.ReadAllBytes(path));
        var text = new StringBuilder();
        foreach (Match stream in Regex.Matches(raw, @"/Filter \[ /ASCII85Decode /FlateDecode \][^>]*>>\s*stream\r?\n([\s\S]*?)~>"))
        {
            string content;
            try
            {
                using var inflate = new ZLibStream(new MemoryStream(Ascii85(stream.Groups[1].Value)), CompressionMode.Decompress);
                using var reader = new StreamReader(inflate, Encoding.Latin1);
                content = reader.ReadToEnd();
            }
            catch (InvalidDataException)
            {
                continue;
            }
            foreach (Match shown in Regex.Matches(content, @"\(((?:\\.|[^\\)])*)\)\s*Tj"))
                text.Append(Unescape(shown.Groups[1].Value)).Append(' ');
        }
        return text.ToString();
    }

    private static byte[] Ascii85(string encoded)
    {
        var bytes = new List<byte>();
        var group = new List<int>();
        foreach (var c in encoded.Where(c => !char.IsWhiteSpace(c)))
        {
            if (c == 'z' && group.Count == 0)
            {
                bytes.AddRange(new byte[4]);
                continue;
            }
            group.Add(c - '!');
            if (group.Count == 5) Flush(5);
        }
        if (group.Count > 0) Flush(group.Count);
        return bytes.ToArray();

        void Flush(int count)
        {
            while (group.Count < 5) group.Add(84);
            var value = group.Aggregate(0u, (acc, digit) => acc * 85 + (uint)digit);
            var four = new[] { (byte)(value >> 24), (byte)(value >> 16), (byte)(value >> 8), (byte)value };
            bytes.AddRange(four.Take(count - 1));
            group.Clear();
        }
    }

    private static string Unescape(string s) => Regex.Replace(s, @"\\([0-7]{1,3}|.)", m =>
    {
        var e = m.Groups[1].Value;
        if (char.IsDigit(e[0])) return ((char)Convert.ToInt32(e, 8)).ToString();
        return e switch { "n" => "\n", "r" => "\r", "t" => "\t", _ => e };
    });

    private static string Root([CallerFilePath] string here = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(here)!, "..", ".."));
}
