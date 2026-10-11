using System.Globalization;
using System.Net.NetworkInformation;
using SmartTelescopeSort.Core.Common;

namespace SmartTelescopeSort.Core.Terms;

/// <summary>
/// The user's acceptance of the launch terms: a hidden, read-only PDF locked with Password, holding the terms shown, this
/// PC's network hardware (MAC) address and the date and time they were accepted. It lives in the app's data folder:
/// %LOCALAPPDATA%\SmartTelescopeSort\Terms-Acceptance.pdf (inside the package's private folder for the Store build).
/// </summary>
public sealed class AgreementRecord
{
    /// <summary>Written into the record so it shows which wording was accepted.</summary>
    public const string TermsVersion = "2026-10-08";

    public const string Password = "MontanaSky";

    public sealed record Contents(string TermsVersion, string AgreedAt, string MacAddress, string AppVersion);

    public AgreementRecord(string folder) => Folder = folder;

    public string Folder { get; }

    public string FilePath => Path.Combine(Folder, "Terms-Acceptance.pdf");

    /// <summary>True once the record exists. It is written once and never replaced.</summary>
    public bool IsAccepted => File.Exists(FilePath);

    /// <summary>When the record says the terms were accepted, for showing to the user.</summary>
    public DateTimeOffset? AcceptedDate =>
        Read() is { } contents && DateTimeOffset.TryParse(contents.AgreedAt, CultureInfo.InvariantCulture, DateTimeStyles.None, out var date) ? date : null;

    /// <summary>Unlocks the PDF and reads the record kept in its Keywords.</summary>
    public Contents? Read()
    {
        try
        {
            if (!File.Exists(FilePath) || LockedPdf.ReadInfo(File.ReadAllBytes(FilePath), Password) is not { } info
                || !info.TryGetValue("Keywords", out var keywords)) return null;
            var fields = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var pair in keywords.Split("; "))
            {
                var equals = pair.IndexOf('=');
                if (equals > 0) fields[pair[..equals]] = pair[(equals + 1)..];
            }
            if (!fields.TryGetValue("termsVersion", out var version) || !fields.TryGetValue("agreedAt", out var agreedAt)) return null;
            return new Contents(version, agreedAt, fields.GetValueOrDefault("macAddress", "unknown"), fields.GetValueOrDefault("appVersion", "unknown"));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or FormatException)
        {
            return null;
        }
    }

    /// <summary>Records acceptance of `terms`. Does nothing when a record already exists, so the first acceptance is kept.</summary>
    public void Record(IReadOnlyList<string> terms, DateTimeOffset? at = null, string? macAddress = null)
    {
        if (IsAccepted) return;
        var now = at ?? DateTimeOffset.Now;
        var contents = new Contents(TermsVersion, now.ToString("yyyy-MM-dd'T'HH:mm:sszzz", CultureInfo.InvariantCulture),
                                    macAddress ?? PrimaryMacAddress() ?? "unknown", AppInfo.Version);
        var keywords = string.Join("; ", $"termsVersion={contents.TermsVersion}", $"agreedAt={contents.AgreedAt}",
                                   $"macAddress={contents.MacAddress}", $"appVersion={contents.AppVersion}");
        var lines = new List<LockedPdf.Line>
        {
            new("Telescope Data Sort — Terms Acceptance", 18, true, 14),
            new($"Accepted: {now.ToString("F", CultureInfo.CurrentCulture)}  ({contents.AgreedAt})", 12, false, 6),
            new($"PC network address: {contents.MacAddress}", 12, false, 6),
            new($"App version: {contents.AppVersion}    Terms version: {contents.TermsVersion}", 12, false, 14),
            new("Terms shown and accepted:", 13, true, 8),
        };
        lines.AddRange(terms.Select(t => new LockedPdf.Line("•  " + t, 11, false, 5)));
        lines.Add(new LockedPdf.Line("", 6, false, 0));
        lines.Add(new LockedPdf.Line("[X]  I have read and accept the above", 12, true, 0));
        var info = new Dictionary<string, string>
        {
            ["Title"] = "Telescope Data Sort — Terms Acceptance",
            ["Author"] = "Big Sky Astro",
            ["Creator"] = $"Telescope Data Sort {contents.AppVersion} for Windows",
            ["Subject"] = $"Terms accepted {contents.AgreedAt}",
            ["Keywords"] = keywords,
        };
        var data = LockedPdf.Write(lines, info, Password);

        Directory.CreateDirectory(Folder);
        using (var stream = new FileStream(FilePath, FileMode.CreateNew, FileAccess.Write))
            stream.Write(data);
        try
        {
            var file = new FileInfo(FilePath);
            if (OperatingSystem.IsWindows()) file.Attributes |= FileAttributes.Hidden | FileAttributes.ReadOnly;
            else File.SetUnixFileMode(FilePath, UnixFileMode.UserRead);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }

    /// <summary>The hardware address of the network adapter in use, e.g. "a4:83:e7:12:34:56".</summary>
    public static string? PrimaryMacAddress()
    {
        try
        {
            var adapters = NetworkInterface.GetAllNetworkInterfaces()
                .Where(n => n.NetworkInterfaceType is not (NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel)
                            && n.GetPhysicalAddress().GetAddressBytes().Length == 6)
                .OrderByDescending(n => n.OperationalStatus == OperationalStatus.Up)
                .ThenByDescending(n => n.GetIPProperties().GatewayAddresses.Count > 0)
                .ThenByDescending(n => n.NetworkInterfaceType == NetworkInterfaceType.Ethernet)
                .ToList();
            var bytes = adapters.FirstOrDefault()?.GetPhysicalAddress().GetAddressBytes();
            return bytes is null ? null : string.Join(':', bytes.Select(b => b.ToString("x2", CultureInfo.InvariantCulture)));
        }
        catch (NetworkInformationException)
        {
            return null;
        }
    }
}
