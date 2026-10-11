using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace SmartTelescopeSort.App.Platform;

/// <summary>Dark title bar and rounded corners on Windows 11, matching the dark Mac window.</summary>
public static class WindowBackdrop
{
    private const int DwmwaUseImmersiveDarkMode = 20;
    private const int DwmwaWindowCornerPreference = 33;
    private const int DwmwaCaptionColor = 35;
    private const int DwmwcpRound = 2;

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    /// <summary>Call from the constructor: applies once the window has a handle.</summary>
    public static void UseDark(Window window, uint? captionBgr = 0x2E170D)
    {
        window.SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(window).Handle;
            if (hwnd == IntPtr.Zero) return;
            try
            {
                var dark = 1;
                DwmSetWindowAttribute(hwnd, DwmwaUseImmersiveDarkMode, ref dark, sizeof(int));
                var corner = DwmwcpRound;
                DwmSetWindowAttribute(hwnd, DwmwaWindowCornerPreference, ref corner, sizeof(int));
                if (captionBgr is { } color)
                {
                    var value = (int)color;
                    DwmSetWindowAttribute(hwnd, DwmwaCaptionColor, ref value, sizeof(int));
                }
            }
            catch (DllNotFoundException)
            {
            }
            catch (EntryPointNotFoundException)
            {
            }
        };
    }
}
