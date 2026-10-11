namespace SmartTelescopeSort.Core.Common;

/// <summary>One way to open the PDF manual: start Program with Argument, or hand Argument to the Windows shell.</summary>
public sealed record ManualLaunch(string? Program, string Argument)
{
    public bool IsShell => Program is null;
}

/// <summary>
/// How Help → User Manual (PDF) opens the bundled PDF, as Weather Wizard for Windows does. Shell-opening a PDF shows the
/// "Pick an app" picker instead of the manual when no PDF app is set, and also when Windows reports one but no longer
/// trusts the saved choice. So the reported PDF app is started directly; with none (or only the picker), Microsoft Edge
/// and then the default browser open it; the shell is tried last.
/// </summary>
public static class ManualRoute
{
    public static IReadOnlyList<ManualLaunch> Plan(string pdfPath, string? pdfHandler, string? edge, string? browser)
    {
        var steps = new List<ManualLaunch>();
        void Add(string? program, string argument)
        {
            if (!IsRealHandler(program)) return;
            var clean = Clean(program!);
            if (steps.Any(s => string.Equals(s.Program, clean, StringComparison.OrdinalIgnoreCase))) return;
            steps.Add(new ManualLaunch(clean, argument));
        }

        Add(pdfHandler, pdfPath);
        Add(edge, FileUrl(pdfPath));
        Add(browser, FileUrl(pdfPath));
        steps.Add(new ManualLaunch(null, pdfPath));
        return steps;
    }

    /// <summary>False for nothing, and for the Open With picker itself.</summary>
    public static bool IsRealHandler(string? executable)
    {
        if (string.IsNullOrWhiteSpace(executable)) return false;
        var name = Clean(executable).Split('\\', '/').Last();
        return name.Length > 0 && !string.Equals(name, "OpenWith.exe", StringComparison.OrdinalIgnoreCase);
    }

    public static string FileUrl(string path) => new Uri(Path.GetFullPath(path)).AbsoluteUri;

    private static string Clean(string executable) => executable.Trim().Trim('"');
}
