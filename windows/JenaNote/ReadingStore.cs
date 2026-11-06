using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows.Media;

namespace JenaNote;

/// <summary>
/// Where each document was being read, and its bookmarks, keyed by file path. macOS keeps these
/// in its user defaults. A file here stays out of the registry and follows JENANOTE_TEST_DATA.
/// </summary>
static class ReadingStore
{
    const int MaxProgressEntries = 300;
    const int MaxBookmarksPerDocument = 100;

    sealed class Contents
    {
        public Dictionary<string, JsonNode> Progress { get; set; } = new(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, JsonArray> Bookmarks { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    }

    static Contents? contents;

    static string FilePath => Path.Combine(AppSettings.Folder, "reading.json");

    static Contents Current => contents ??= Read();

    /// <summary>Forgets what was loaded, because the settings folder changed.</summary>
    public static void Unload() => contents = null;

    static Contents Read()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                var read = JsonSerializer.Deserialize<Contents>(File.ReadAllBytes(FilePath)) ?? new Contents();
                // Deserializing makes plain dictionaries, which would compare paths by case.
                return new Contents
                {
                    Progress = new(read.Progress ?? new(), StringComparer.OrdinalIgnoreCase),
                    Bookmarks = new(read.Bookmarks ?? new(), StringComparer.OrdinalIgnoreCase),
                };
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            // Losing a reading place is better than failing to open documents.
            Trace.TraceWarning("Reading positions ignored: {0}", error.Message);
        }
        return new Contents();
    }

    static void Save()
    {
        try
        {
            Directory.CreateDirectory(AppSettings.Folder);
            DocumentFile.Write(FilePath, JsonSerializer.Serialize(Current));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            Trace.TraceWarning("Reading positions not saved: {0}", error.Message);
        }
    }

    public static JsonNode? Progress(string path) => Current.Progress.GetValueOrDefault(Path.GetFullPath(path));

    public static JsonArray? Bookmarks(string path) => Current.Bookmarks.GetValueOrDefault(Path.GetFullPath(path));

    /// <summary>Null clears the entry. The start of a document needs none.</summary>
    public static void SetProgress(string path, JsonNode? anchor)
    {
        var key = Path.GetFullPath(path);
        if (anchor == null)
        {
            if (Current.Progress.Remove(key)) Save();
            return;
        }
        Current.Progress[key] = anchor.DeepClone();
        // The documents not looked at for longest go first.
        if (Current.Progress.Count > MaxProgressEntries)
        {
            Current.Progress = Current.Progress.OrderByDescending(entry => entry.Value["updatedAt"]?.GetValue<double>() ?? 0)
                .Take(MaxProgressEntries)
                .ToDictionary(entry => entry.Key, entry => entry.Value, StringComparer.OrdinalIgnoreCase);
        }
        Save();
    }

    public static void SetBookmarks(string path, JsonArray list)
    {
        var key = Path.GetFullPath(path);
        if (list.Count == 0)
        {
            if (Current.Bookmarks.Remove(key)) Save();
            return;
        }
        Current.Bookmarks[key] = new JsonArray(list.Take(MaxBookmarksPerDocument).Select(item => item?.DeepClone()).ToArray());
        Save();
    }

    /// <summary>Reading places and bookmarks stay with documents the app renamed.</summary>
    public static void Moved(string source, string destination)
    {
        var changed = false;
        foreach (var key in Current.Progress.Keys.ToList())
        {
            var moved = SidebarFiles.Relocated(key, source, destination);
            if (moved == null || moved == key) continue;
            Current.Progress.Remove(key, out var value);
            Current.Progress[moved] = value!;
            changed = true;
        }
        foreach (var key in Current.Bookmarks.Keys.ToList())
        {
            var moved = SidebarFiles.Relocated(key, source, destination);
            if (moved == null || moved == key) continue;
            Current.Bookmarks.Remove(key, out var value);
            Current.Bookmarks[moved] = value!;
            changed = true;
        }
        if (changed) Save();
    }
}

/// <summary>The typefaces a document can be read in, and the paper widths it can be shown at.</summary>
static class ReadingFaces
{
    sealed record Face(string Id, string[] Families, string Generic, bool AlwaysAvailable = false);

    /// <summary>Bundled with the app, like KoPub Batang on macOS.</summary>
    const string Bundled = "KoPub Batang App";

    static readonly Face[] Faces =
    {
        new("serif", new[] { Bundled, "Nanum Myeongjo", "NanumMyeongjo", "Batang" }, "serif", true),
        new("sans", new[] { "Malgun Gothic", "Segoe UI" }, "sans-serif", true),
        new("kopubBatang", new[] { Bundled }, "serif", true),
        new("nanumMyeongjo", new[] { "Nanum Myeongjo", "NanumMyeongjo", "NanumMyeongjoOTF" }, "serif"),
        new("kimjungchulMyungjo", new[] { "Kim jung chul Myungjo", "KimjungchulMyungjo" }, "serif"),
        new("batang", new[] { "Batang" }, "serif"),
        new("malgunGothic", new[] { "Malgun Gothic" }, "sans-serif"),
        new("nanumGothic", new[] { "Nanum Gothic", "NanumGothic" }, "sans-serif"),
        new("notoSansKR", new[] { "Noto Sans CJK KR", "Noto Sans KR" }, "sans-serif"),
        new("pretendard", new[] { "Pretendard" }, "sans-serif"),
    };

    static readonly (string Id, double Width)[] Papers =
    {
        ("a3", 297), ("a4", 210), ("a5", 148), ("a6", 105), ("b3", 353), ("b4", 250), ("b5", 176), ("b6", 125),
        ("jisB4", 257), ("jisB5", 182), ("letter", 215.9), ("legal", 215.9),
    };

    static HashSet<string>? installed;

    static HashSet<string> Installed => installed ??= Fonts.SystemFontFamilies
        .SelectMany(family => family.FamilyNames.Values.Append(family.Source))
        .ToHashSet(StringComparer.OrdinalIgnoreCase);

    static string Css(Face face) =>
        string.Join(", ", face.Families.Select(name => $"\"{name}\"")) + ", " + face.Generic;

    /// <summary>Only what can really be drawn on this machine, in the order macOS lists them.</summary>
    public static object[] Available() => Faces
        .Where(face => face.AlwaysAvailable || face.Families.Any(Installed.Contains))
        .Select(face => (object)new { id = face.Id, label = NativeCore.Tr($"reader.font.{face.Id}"), css = Css(face) })
        .ToArray();

    public static bool IsPaper(string id) => id == "automatic" || Papers.Any(paper => paper.Id == id);

    public static object[] PaperSizes()
    {
        static string Name(string id) => id switch
        {
            "jisB4" => "B4 (JIS)",
            "jisB5" => "B5 (JIS)",
            "b3" or "b4" or "b5" or "b6" => id.ToUpperInvariant() + " (ISO)",
            "letter" => "Letter",
            "legal" => "Legal",
            _ => id.ToUpperInvariant(),
        };
        var list = new List<object> { new { id = "automatic", label = NativeCore.Tr("paperSize.automatic"), width = 0.0 } };
        list.AddRange(Papers.Select(paper => (object)new
        {
            id = paper.Id,
            label = $"{Name(paper.Id)} · {paper.Width:0.#} mm",
            width = paper.Width * 72 / 25.4,
        }));
        return list.ToArray();
    }
}
