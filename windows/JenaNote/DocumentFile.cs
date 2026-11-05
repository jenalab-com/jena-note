using System.IO;
using System.Text;

namespace JenaNote;

/// <summary>Reads and writes document files as UTF-8 with LF line endings, like the macOS app.</summary>
static class DocumentFile
{
    public sealed class NotUtf8Exception : Exception { }

    public static bool IsPlainText(string path) =>
        string.Equals(Path.GetExtension(path), ".txt", StringComparison.OrdinalIgnoreCase);

    public static string Read(string path) => Decode(File.ReadAllBytes(path));

    /// <summary>
    /// Refuses data that is not UTF-8. Opening it as empty or garbled text would let the next
    /// save overwrite the original.
    /// </summary>
    public static string Decode(byte[] bytes)
    {
        string text;
        try
        {
            text = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true).GetString(bytes);
        }
        catch (ArgumentException)
        {
            throw new NotUtf8Exception();
        }
        if (text.Length > 0 && text[0] == '﻿') text = text[1..];
        return text.Replace("\r\n", "\n").Replace('\r', '\n');
    }

    /// <summary>Writes to a temporary file first, so a failed write leaves the original intact.</summary>
    public static void Write(string path, string text) =>
        WriteBytes(path, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false).GetBytes(text));

    public static void WriteBytes(string path, byte[] bytes)
    {
        var folder = Path.GetDirectoryName(Path.GetFullPath(path))!;
        var temporary = Path.Combine(folder, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }
}
