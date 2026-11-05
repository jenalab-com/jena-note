using System.Diagnostics;
using System.IO;
using System.Text.Json;

namespace JenaNote;

/// <summary>
/// Copies of unsaved documents, kept outside the document's own file. If the app ends without
/// closing a document properly, its copy stays behind and is offered at the next start.
/// </summary>
static class RecoveryStore
{
    public sealed record Entry(string Id, int ProcessId, string? Path, bool Plain, string Text);

    sealed record StoredEntry(int ProcessId, string? Path, bool Plain, string Text);

    public static string Folder { get; set; } =
        System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "JenaNote", "Recovery");

    static string FileOf(string id) => System.IO.Path.Combine(Folder, id + ".json");

    public static void Save(string id, string? path, bool plain, string text)
    {
        Directory.CreateDirectory(Folder);
        DocumentFile.Write(FileOf(id), JsonSerializer.Serialize(new StoredEntry(Environment.ProcessId, path, plain, text)));
    }

    public static void Delete(string id)
    {
        try
        {
            File.Delete(FileOf(id));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            Trace.TraceWarning("Could not remove a recovery copy: {0}", error.Message);
        }
    }

    /// <summary>Copies whose app is gone. Another running window keeps its own.</summary>
    public static List<Entry> Orphans()
    {
        var result = new List<Entry>();
        if (!Directory.Exists(Folder)) return result;
        foreach (var file in Directory.GetFiles(Folder, "*.json"))
        {
            try
            {
                var stored = JsonSerializer.Deserialize<StoredEntry>(File.ReadAllBytes(file));
                if (stored == null || IsRunning(stored.ProcessId)) continue;
                result.Add(new Entry(System.IO.Path.GetFileNameWithoutExtension(file), stored.ProcessId, stored.Path, stored.Plain, stored.Text));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
            {
                // An unreadable copy may still be repaired by hand, so it stays where it is.
                Trace.TraceWarning("Skipped a recovery copy: {0}", error.Message);
            }
        }
        return result;
    }

    static bool IsRunning(int processId)
    {
        if (processId == Environment.ProcessId) return true;
        try
        {
            using var process = Process.GetProcessById(processId);
            return process.ProcessName.Equals("JenaNote", StringComparison.OrdinalIgnoreCase);
        }
        catch (ArgumentException)
        {
            return false;
        }
    }
}
