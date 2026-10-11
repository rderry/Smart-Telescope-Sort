using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace SmartTelescopeSort.Core.Terms;

/// <summary>
/// A small PDF writer for the terms acceptance record: Helvetica text pages, the document info (title, author, keywords…),
/// and the PDF standard security handler (revision 3, 128-bit RC4) with one password for opening and owning it, printing
/// allowed and copying not, as CoreGraphics writes it on the Mac. It can read back the keywords of a file it wrote.
/// </summary>
public static partial class LockedPdf
{
    public sealed record Line(string Text, double Size, bool Bold, double SpaceAfter);

    private static readonly byte[] Padding =
    {
        0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08,
        0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80, 0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A,
    };

    /// <summary>Print (bit 3) and high-quality print (bit 12) allowed; copy, modify and annotate not.</summary>
    public const int Permissions = -1852;

    private const double PageWidth = 612;
    private const double PageHeight = 792;
    private const double Margin = 54;

    public static byte[] Write(IReadOnlyList<Line> lines, IReadOnlyDictionary<string, string> info, string password)
    {
        var id = RandomNumberGenerator.GetBytes(16);
        var owner = OwnerKey(password, password);
        var key = FileKey(password, owner, Permissions, id);
        var user = UserKey(key, id);

        var pages = Layout(lines);
        // Objects: 1 catalog, 2 pages, 3 Helvetica, 4 Helvetica-Bold, then a page and its contents per page, info, encrypt.
        var objects = new List<byte[]>();
        var pageIds = new List<int>();
        var next = 5;
        var bodies = new List<(int Id, string Text)>();
        foreach (var page in pages)
        {
            pageIds.Add(next);
            bodies.Add((next + 1, page));
            next += 2;
        }
        var infoId = next;
        var encryptId = next + 1;

        string Ref(int n) => $"{n} 0 R";
        var output = new MemoryStream();
        var offsets = new SortedDictionary<int, long>();
        void Put(string text) => output.Write(Encoding.Latin1.GetBytes(text));
        void Object(int n, string body)
        {
            offsets[n] = output.Position;
            Put($"{n} 0 obj\n{body}\nendobj\n");
        }

        Put("%PDF-1.4\n%\u00E2\u00E3\u00CF\u00D3\n");
        Object(1, $"<< /Type /Catalog /Pages {Ref(2)} >>");
        Object(2, $"<< /Type /Pages /Kids [{string.Join(' ', pageIds.Select(Ref))}] /Count {pageIds.Count} >>");
        Object(3, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>");
        Object(4, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>");
        for (var i = 0; i < pageIds.Count; i++)
        {
            Object(pageIds[i], $"<< /Type /Page /Parent {Ref(2)} /MediaBox [0 0 {PageWidth} {PageHeight}] "
                + $"/Resources << /Font << /F1 {Ref(3)} /F2 {Ref(4)} >> >> /Contents {Ref(bodies[i].Id)} >>");
            var stream = Rc4(ObjectKey(key, bodies[i].Id), Encoding.Latin1.GetBytes(bodies[i].Text));
            offsets[bodies[i].Id] = output.Position;
            Put($"{bodies[i].Id} 0 obj\n<< /Length {stream.Length} >>\nstream\n");
            output.Write(stream);
            Put("\nendstream\nendobj\n");
        }
        var infoKey = ObjectKey(key, infoId);
        Object(infoId, "<< " + string.Join(' ', info.Select(kv => $"/{kv.Key} <{Hex(Rc4(infoKey, WinAnsi(kv.Value)))}>")) + " >>");
        Object(encryptId, $"<< /Filter /Standard /V 2 /R 3 /Length 128 /P {Permissions} /O <{Hex(owner)}> /U <{Hex(user)}> >>");

        var xref = output.Position;
        Put($"xref\n0 {encryptId + 1}\n0000000000 65535 f \n");
        for (var n = 1; n <= encryptId; n++) Put($"{offsets[n]:D10} 00000 n \n");
        Put($"trailer\n<< /Size {encryptId + 1} /Root {Ref(1)} /Info {Ref(infoId)} /Encrypt {Ref(encryptId)} /ID [<{Hex(id)}> <{Hex(id)}>] >>\n");
        Put($"startxref\n{xref}\n%%EOF\n");
        return output.ToArray();
    }

    /// <summary>The document info strings of a PDF this class wrote, unlocked with `password`; null when it doesn't open.</summary>
    public static Dictionary<string, string>? ReadInfo(byte[] pdf, string password)
    {
        var text = Encoding.Latin1.GetString(pdf);
        var id = IdPattern().Match(text);
        var owner = OwnerPattern().Match(text);
        var user = UserPattern().Match(text);
        var permissions = PermissionsPattern().Match(text);
        var infoRef = InfoRefPattern().Match(text);
        if (!id.Success || !owner.Success || !user.Success || !permissions.Success || !infoRef.Success) return null;

        var key = FileKey(password, FromHex(owner.Groups[1].Value), int.Parse(permissions.Groups[1].Value, CultureInfo.InvariantCulture), FromHex(id.Groups[1].Value));
        if (!UserKey(key, FromHex(id.Groups[1].Value)).AsSpan(0, 16).SequenceEqual(FromHex(user.Groups[1].Value).AsSpan(0, 16))) return null;

        var infoId = int.Parse(infoRef.Groups[1].Value, CultureInfo.InvariantCulture);
        var body = Regex.Match(text, $@"(?m)^{infoId} 0 obj\n<<(.*?)>>\nendobj");
        if (!body.Success) return null;
        var objectKey = ObjectKey(key, infoId);
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (Match entry in InfoEntryPattern().Matches(body.Groups[1].Value))
            values[entry.Groups[1].Value] = FromWinAnsi(Rc4(objectKey, FromHex(entry.Groups[2].Value)));
        return values;
    }

    public static bool IsEncrypted(byte[] pdf) => Encoding.Latin1.GetString(pdf).Contains("/Encrypt ", StringComparison.Ordinal);

    private static List<string> Layout(IReadOnlyList<Line> lines)
    {
        var pages = new List<string>();
        var page = new StringBuilder();
        var y = PageHeight - Margin;
        foreach (var line in lines)
        {
            var leading = line.Size * 1.25;
            foreach (var row in Wrap(line.Text, line.Size, line.Bold, PageWidth - 2 * Margin))
            {
                if (y - leading < Margin)
                {
                    pages.Add(page.ToString());
                    page.Clear();
                    y = PageHeight - Margin;
                }
                y -= leading;
                page.Append(CultureInfo.InvariantCulture, $"BT /{(line.Bold ? "F2" : "F1")} {line.Size:0.##} Tf {Margin:0.##} {y:0.##} Td (");
                foreach (var b in WinAnsi(row))
                {
                    if (b is (byte)'(' or (byte)')' or (byte)'\\') page.Append('\\');
                    page.Append((char)b);
                }
                page.Append(") Tj ET\n");
            }
            y -= line.SpaceAfter;
        }
        pages.Add(page.ToString());
        return pages;
    }

    private static IEnumerable<string> Wrap(string text, double size, bool bold, double width)
    {
        if (text.Length == 0)
        {
            yield return "";
            yield break;
        }
        var perChar = size * (bold ? 0.56 : 0.52);
        var max = Math.Max(10, (int)(width / perChar));
        var line = new StringBuilder();
        foreach (var word in text.Split(' '))
        {
            if (line.Length > 0 && line.Length + 1 + word.Length > max)
            {
                yield return line.ToString();
                line.Clear();
            }
            if (line.Length > 0) line.Append(' ');
            line.Append(word);
        }
        if (line.Length > 0) yield return line.ToString();
    }

    private static byte[] Pad(string password)
    {
        var bytes = WinAnsi(password);
        var padded = new byte[32];
        var n = Math.Min(bytes.Length, 32);
        Array.Copy(bytes, padded, n);
        Array.Copy(Padding, 0, padded, n, 32 - n);
        return padded;
    }

    /// <summary>Algorithm 3: the /O value.</summary>
    private static byte[] OwnerKey(string ownerPassword, string userPassword)
    {
        var hash = MD5.HashData(Pad(ownerPassword));
        for (var i = 0; i < 50; i++) hash = MD5.HashData(hash);
        var result = Rc4(hash, Pad(userPassword));
        for (var i = 1; i <= 19; i++) result = Rc4(hash.Select(b => (byte)(b ^ i)).ToArray(), result);
        return result;
    }

    /// <summary>Algorithm 2: the file encryption key.</summary>
    private static byte[] FileKey(string password, byte[] owner, int permissions, byte[] id)
    {
        var input = new List<byte>(Pad(password));
        input.AddRange(owner);
        input.AddRange(BitConverter.GetBytes(permissions));
        input.AddRange(id);
        var hash = MD5.HashData(input.ToArray());
        for (var i = 0; i < 50; i++) hash = MD5.HashData(hash);
        return hash;
    }

    /// <summary>Algorithm 5: the /U value.</summary>
    private static byte[] UserKey(byte[] key, byte[] id)
    {
        var result = Rc4(key, MD5.HashData(Padding.Concat(id).ToArray()));
        for (var i = 1; i <= 19; i++) result = Rc4(key.Select(b => (byte)(b ^ i)).ToArray(), result);
        return result.Concat(new byte[16]).ToArray();
    }

    /// <summary>Algorithm 1: the key for one object's strings and streams.</summary>
    private static byte[] ObjectKey(byte[] key, int objectNumber)
    {
        var input = key.Concat(new[] { (byte)objectNumber, (byte)(objectNumber >> 8), (byte)(objectNumber >> 16), (byte)0, (byte)0 }).ToArray();
        return MD5.HashData(input);
    }

    private static byte[] Rc4(byte[] key, byte[] data)
    {
        var s = Enumerable.Range(0, 256).Select(i => (byte)i).ToArray();
        for (int i = 0, j = 0; i < 256; i++)
        {
            j = (j + s[i] + key[i % key.Length]) & 0xFF;
            (s[i], s[j]) = (s[j], s[i]);
        }
        var output = new byte[data.Length];
        for (int k = 0, i = 0, j = 0; k < data.Length; k++)
        {
            i = (i + 1) & 0xFF;
            j = (j + s[i]) & 0xFF;
            (s[i], s[j]) = (s[j], s[i]);
            output[k] = (byte)(data[k] ^ s[(s[i] + s[j]) & 0xFF]);
        }
        return output;
    }

    private static readonly Dictionary<char, byte> WinAnsiExtras = new()
    {
        ['€'] = 0x80, ['…'] = 0x85, ['‘'] = 0x91, ['’'] = 0x92, ['“'] = 0x93, ['”'] = 0x94, ['•'] = 0x95, ['–'] = 0x96, ['—'] = 0x97,
    };

    private static byte[] WinAnsi(string text) =>
        text.Select(c => WinAnsiExtras.TryGetValue(c, out var b) ? b : c <= 0xFF && c is not (>= '\u0080' and <= '\u009F') ? (byte)c : (byte)'?').ToArray();

    private static string FromWinAnsi(byte[] bytes) =>
        new(bytes.Select(b => WinAnsiExtras.FirstOrDefault(kv => kv.Value == b) is { Key: not '\0' } kv ? kv.Key : (char)b).ToArray());

    private static string Hex(byte[] bytes) => Convert.ToHexString(bytes);

    private static byte[] FromHex(string hex) => Convert.FromHexString(hex);

    [GeneratedRegex(@"/ID \[<([0-9A-Fa-f]+)>")]
    private static partial Regex IdPattern();

    [GeneratedRegex(@"/O <([0-9A-Fa-f]+)>")]
    private static partial Regex OwnerPattern();

    [GeneratedRegex(@"/U <([0-9A-Fa-f]+)>")]
    private static partial Regex UserPattern();

    [GeneratedRegex(@"/P (-?\d+)")]
    private static partial Regex PermissionsPattern();

    [GeneratedRegex(@"/Info (\d+) 0 R")]
    private static partial Regex InfoRefPattern();

    [GeneratedRegex(@"/(\w+) <([0-9A-Fa-f]*)>")]
    private static partial Regex InfoEntryPattern();
}
