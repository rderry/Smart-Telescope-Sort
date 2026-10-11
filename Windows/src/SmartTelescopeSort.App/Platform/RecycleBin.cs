using System.IO;
using System.Runtime.InteropServices;

namespace SmartTelescopeSort.App.Platform;

/// <summary>
/// Sends files and folders to the Recycle Bin (the Mac's trashItem). Returns false when the item couldn't be recycled,
/// for example on a network share or a drive without a Recycle Bin, and FileOps then deletes it outright as the Mac does.
/// </summary>
public static class RecycleBin
{
    private const uint FoDelete = 0x0003;
    private const ushort FofSilent = 0x0004;
    private const ushort FofNoConfirmation = 0x0010;
    private const ushort FofAllowUndo = 0x0040;
    private const ushort FofNoErrorUi = 0x0400;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ShFileOpStruct
    {
        public IntPtr Hwnd;
        public uint Func;
        [MarshalAs(UnmanagedType.LPWStr)] public string From;
        [MarshalAs(UnmanagedType.LPWStr)] public string? To;
        public ushort Flags;
        [MarshalAs(UnmanagedType.Bool)] public bool AnyOperationsAborted;
        public IntPtr NameMappings;
        [MarshalAs(UnmanagedType.LPWStr)] public string? ProgressTitle;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHFileOperation(ref ShFileOpStruct operation);

    /// <summary>
    /// Shell paths can't carry the \\?\ prefix or be longer than MAX_PATH, so long paths fall back to deletion by
    /// returning false; read-only items are recycled like any other.
    /// </summary>
    public static bool Send(string path)
    {
        if (!OperatingSystem.IsWindows()) return false;
        var full = Path.GetFullPath(path);
        if (full.StartsWith(@"\\?\", StringComparison.Ordinal) || full.Length >= 260) return false;
        if (!File.Exists(full) && !Directory.Exists(full)) return false;
        var operation = new ShFileOpStruct
        {
            Func = FoDelete,
            From = full + "\0\0",
            Flags = (ushort)(FofAllowUndo | FofNoConfirmation | FofNoErrorUi | FofSilent),
        };
        // Without FOF_WANTNUKEWARNING the shell deletes outright on a drive with no Recycle Bin, as the questions say.
        return SHFileOperation(ref operation) == 0 && !operation.AnyOperationsAborted;
    }
}
