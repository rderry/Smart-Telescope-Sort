using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using Microsoft.Win32;
using SmartTelescopeSort.Core.Common;

namespace SmartTelescopeSort.App.Platform;

/// <summary>Opens web links, mail links, files and folders with their default Windows apps.</summary>
public static class Desktop
{
    public static bool Open(string target)
    {
        try
        {
            Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
            return true;
        }
        catch (Exception e) when (e is Win32Exception or InvalidOperationException or FileNotFoundException)
        {
            return false;
        }
    }

    /// <summary>The bundled user manual PDF next to the app (inside the package when installed from the Store).</summary>
    public static string ManualPath => Path.Combine(AppContext.BaseDirectory, "Assets", "Telescope-Data-Sort-User-Manual.pdf");

    /// <summary>Opens the PDF manual, avoiding Windows' "Pick an app" picker where it can (see <see cref="ManualRoute"/>).</summary>
    public static bool OpenManualPdf()
    {
        var path = ManualPath;
        if (!File.Exists(path)) return false;
        foreach (var step in ManualRoute.Plan(path, AssocExecutable(".pdf", isProtocol: false), EdgePath(), AssocExecutable("http", isProtocol: true)))
        {
            if (step.IsShell ? Open(step.Argument) : Start(step.Program!, step.Argument)) return true;
        }
        return false;
    }

    public static void CopyToClipboard(string text)
    {
        try
        {
            Clipboard.SetText(text);
        }
        catch (COMException)
        {
        }
    }

    private static bool Start(string program, string argument)
    {
        if (!File.Exists(program)) return false;
        try
        {
            var start = new ProcessStartInfo(program) { UseShellExecute = false };
            start.ArgumentList.Add(argument);
            return Process.Start(start) is not null;
        }
        catch (Exception e) when (e is Win32Exception or InvalidOperationException or FileNotFoundException)
        {
            return false;
        }
    }

    private static string? EdgePath()
    {
        const string appPath = @"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe";
        foreach (var hive in new[] { Registry.CurrentUser, Registry.LocalMachine })
        {
            try
            {
                using var key = hive.OpenSubKey(appPath);
                if (key?.GetValue(null) is string registered && File.Exists(registered.Trim('"'))) return registered.Trim('"');
            }
            catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException)
            {
            }
        }
        foreach (var folder in new[] { Environment.SpecialFolder.ProgramFilesX86, Environment.SpecialFolder.ProgramFiles })
        {
            var candidate = Path.Combine(Environment.GetFolderPath(folder), "Microsoft", "Edge", "Application", "msedge.exe");
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    private static string? AssocExecutable(string assoc, bool isProtocol)
    {
        const uint ignoreUnknown = 0x400, isProtocolFlag = 0x1000, executable = 2;
        var flags = ignoreUnknown | (isProtocol ? isProtocolFlag : 0);
        uint size = 1024;
        var buffer = new StringBuilder((int)size);
        return AssocQueryString(flags, executable, assoc, "open", buffer, ref size) == 0 ? buffer.ToString() : null;
    }

    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode)]
    private static extern int AssocQueryString(uint flags, uint str, string pszAssoc, string? pszExtra, StringBuilder pszOut, ref uint pcchOut);
}
