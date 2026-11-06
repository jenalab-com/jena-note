using System.Diagnostics;
using System.IO;
using System.Windows.Threading;
using Microsoft.VisualBasic.FileIO;

namespace JenaNote;

/// <summary>What the sidebar shows and does to files. Nothing here ever overwrites a file.</summary>
static class SidebarFiles
{
    public sealed record Entry(string Path, bool IsDirectory, DateTime Modified)
    {
        public string Name => System.IO.Path.GetFileName(Path);
    }

    static readonly HashSet<string> ReservedNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

    /// <summary>For tests, so they leave nothing in the author's Recycle Bin.</summary>
    public static Action<string>? DeleteForTest { get; set; }

    /// <summary>A name usable on Windows, without the leading dot that hides files here.</summary>
    public static bool IsValidName(string name)
    {
        if (name.Length == 0 || name.Length > 200 || name.StartsWith('.') || name.EndsWith('.') || name.EndsWith(' ')) return false;
        if (name.IndexOfAny(new[] { '/', '\\', ':', '*', '?', '"', '<', '>', '|' }) >= 0 || name.Any(char.IsControl)) return false;
        var stem = name.Split('.')[0].TrimEnd();
        return !ReservedNames.Contains(stem);
    }

    /// <summary>Hidden and dot files stay out of the tree, as on macOS.</summary>
    static bool IsHidden(FileSystemInfo info) =>
        info.Name.StartsWith('.') || info.Attributes.HasFlag(FileAttributes.Hidden) || info.Attributes.HasFlag(FileAttributes.System);

    /// <summary>Folders first, then Markdown files, each group in the chosen order.</summary>
    public static List<Entry> List(string folder, string sortKey, bool ascending)
    {
        var folders = new List<Entry>();
        var files = new List<Entry>();
        try
        {
            foreach (var info in new DirectoryInfo(folder).EnumerateFileSystemInfos())
            {
                if (IsHidden(info)) continue;
                if (info is DirectoryInfo) folders.Add(new Entry(info.FullName, true, info.LastWriteTimeUtc));
                else if (info.Extension.Equals(".md", StringComparison.OrdinalIgnoreCase)) files.Add(new Entry(info.FullName, false, info.LastWriteTimeUtc));
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            // A folder that cannot be read shows as empty, as on macOS.
            Trace.TraceWarning("Could not read {0}: {1}", folder, error.Message);
        }
        Sort(folders, sortKey, ascending);
        Sort(files, sortKey, ascending);
        folders.AddRange(files);
        return folders;
    }

    static void Sort(List<Entry> entries, string sortKey, bool ascending)
    {
        entries.Sort((a, b) =>
        {
            var byName = string.Compare(a.Name, b.Name, StringComparison.CurrentCultureIgnoreCase);
            var order = sortKey == "date" ? a.Modified.CompareTo(b.Modified) : byName;
            // Equal dates fall back to the name in ascending order, for a stable list.
            if (order == 0) return byName;
            return ascending ? order : -order;
        });
    }

    public static string CreateDocument(string parent, string rawName)
    {
        var name = rawName.Trim();
        if (!name.EndsWith(".md", StringComparison.OrdinalIgnoreCase)) name += ".md";
        var path = Checked(parent, name);
        // CreateNew fails if another program made this name in the meantime.
        using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write);
        return path;
    }

    public static string CreateFolder(string parent, string rawName)
    {
        var path = Checked(parent, rawName.Trim());
        if (Directory.Exists(path) || File.Exists(path)) throw new IOException(path);
        Directory.CreateDirectory(path);
        return path;
    }

    /// <summary>A Markdown file keeps its extension unless the author typed another one.</summary>
    public static string NameForRename(string source, string rawName)
    {
        var name = rawName.Trim();
        var keepsExtension = !Directory.Exists(source)
            && Path.GetExtension(source).Equals(".md", StringComparison.OrdinalIgnoreCase)
            && Path.GetExtension(name).Length == 0;
        return keepsExtension ? name + ".md" : name;
    }

    public static string Rename(string source, string rawName)
    {
        var folder = Path.GetDirectoryName(source)!;
        var name = NameForRename(source, rawName);
        var target = Path.Combine(folder, name);
        if (string.Equals(source, target, StringComparison.Ordinal)) return source;
        var changesOnlyCase = string.Equals(source, target, StringComparison.OrdinalIgnoreCase);
        if (!IsValidName(name)) throw new ArgumentException(NativeCore.Tr("doc.invalidName"));
        if (!changesOnlyCase && (File.Exists(target) || Directory.Exists(target))) throw new IOException(target);
        if (Directory.Exists(source)) Directory.Move(source, target);
        else File.Move(source, target, overwrite: false);
        return target;
    }

    static string Checked(string parent, string name)
    {
        if (!IsValidName(name)) throw new ArgumentException(NativeCore.Tr("doc.invalidName"));
        return Path.Combine(parent, name);
    }

    public static void MoveToRecycleBin(string path)
    {
        if (DeleteForTest != null) DeleteForTest(path);
        else if (Directory.Exists(path)) FileSystem.DeleteDirectory(path, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin);
        else FileSystem.DeleteFile(path, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin);
    }

    /// <summary>Where a path ends up after `source` moved, or null when it is outside `source`.</summary>
    public static string? Relocated(string path, string source, string destination)
    {
        var full = Path.GetFullPath(path);
        var root = Path.GetFullPath(source).TrimEnd(Path.DirectorySeparatorChar);
        if (string.Equals(full, root, StringComparison.OrdinalIgnoreCase)) return destination;
        return full.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
            ? destination + full[root.Length..]
            : null;
    }
}

/// <summary>Reports changes inside the registered folders, gathered for 200 ms as on macOS.</summary>
static class FolderWatch
{
    static readonly List<FileSystemWatcher> Watchers = new();
    static DispatcherTimer? debounce;

    public static event Action? Changed;

    public static void Follow(IEnumerable<string> folders)
    {
        foreach (var watcher in Watchers) watcher.Dispose();
        Watchers.Clear();
        debounce ??= new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(200) };
        debounce.Tick -= Fire;
        debounce.Tick += Fire;
        foreach (var folder in folders)
        {
            if (!Directory.Exists(folder)) continue;
            try
            {
                var watcher = new FileSystemWatcher(folder)
                {
                    IncludeSubdirectories = true,
                    NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite,
                };
                watcher.Created += Note;
                watcher.Deleted += Note;
                watcher.Renamed += Note;
                watcher.Changed += Note;
                // A burst of changes can overflow the buffer. Reloading covers whatever was missed.
                watcher.Error += (_, _) => Schedule();
                watcher.EnableRaisingEvents = true;
                Watchers.Add(watcher);
            }
            catch (Exception error) when (error is IOException or ArgumentException or UnauthorizedAccessException)
            {
                Trace.TraceWarning("Could not watch {0}: {1}", folder, error.Message);
            }
        }
    }

    static void Note(object sender, FileSystemEventArgs e)
    {
        // Saving writes a temporary dot file first. It says nothing the real name will not.
        if (Path.GetFileName(e.Name ?? "").StartsWith('.')) return;
        Schedule();
    }

    static void Schedule()
    {
        System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
        {
            debounce?.Stop();
            debounce?.Start();
        });
    }

    static void Fire(object? sender, EventArgs e)
    {
        debounce?.Stop();
        Changed?.Invoke();
    }
}
