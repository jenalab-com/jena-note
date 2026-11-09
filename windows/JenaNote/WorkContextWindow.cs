using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;

namespace JenaNote;

/// <summary>Keeps each work's index current, off the UI thread, and says when it changed.</summary>
static class WorkIndex
{
    static readonly HashSet<string> Running = new(StringComparer.OrdinalIgnoreCase);
    static readonly Dictionary<string, CancellationTokenSource> Pending = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Raised on the UI thread when a window should read the status again.</summary>
    public static event Action? Changed;

    public static void NotifyChanged() => Changed?.Invoke();

    /// <summary>Saves often come in bursts, so a change waits 0.8 seconds for the next, as on macOS.</summary>
    public static async void Schedule(string path)
    {
        if (Pending.Remove(path, out var previous)) previous.Cancel();
        var wait = new CancellationTokenSource();
        Pending[path] = wait;
        try
        {
            await Task.Delay(800, wait.Token);
        }
        catch (TaskCanceledException)
        {
            return;
        }
        Pending.Remove(path);
        await PrepareAsync(path);
    }

    public static async Task PrepareAsync(string path)
    {
        if (!Running.Add(path)) return;
        Changed?.Invoke();
        try
        {
            await Task.Run(() => NativeCore.WorkPrepare(path));
        }
        catch (InvalidOperationException error)
        {
            // A file that cannot be read stops the index, not the writing. The status row shows it.
            LastError = error.Message;
            Trace.TraceWarning("The work index did not update: {0}", error.Message);
            Running.Remove(path);
            Changed?.Invoke();
            return;
        }
        LastError = null;
        Running.Remove(path);
        Changed?.Invoke();
    }

    public static string? LastError { get; private set; }
    public static bool IsRunning(string path) => Running.Contains(path);
}

/// <summary>Which folders make up a work: its settings, its writing folder and its title.</summary>
sealed class WorkContextWindow : Window
{
    static readonly Dictionary<string, WorkContextWindow> Open = new(StringComparer.OrdinalIgnoreCase);

    readonly string file;
    string root;
    JsonNode config;
    bool provisional;
    string? rejection;
    readonly TabControl tabs = new() { Margin = new Thickness(10) };
    readonly StackPanel sources = new() { Margin = new Thickness(16) };
    readonly StackPanel episodes = new() { Margin = new Thickness(16) };
    readonly StackPanel folders = new() { Margin = new Thickness(16) };
    TextBox? titleBox;

    public string Root => root;
    public bool IsProvisional => provisional;
    public string ConfigJson => config.ToJsonString();
    public string? Rejection => rejection;

    /// <summary>Brings forward the window for this work, or opens one. Tab 0 is sources, 2 is folders.</summary>
    public static WorkContextWindow Present(Window owner, string file, int tab)
    {
        using var state = JsonDocument.Parse(NativeCore.WorkWindowOpen(file));
        var root = state.RootElement.GetProperty("root").GetString()!;
        if (!Open.TryGetValue(root, out var window))
        {
            window = new WorkContextWindow(file, state.RootElement) { Owner = owner };
            Open[root] = window;
            window.Show();
            window.tabs.SelectedIndex = tab;
        }
        else
        {
            window.Activate();
        }
        return window;
    }

    WorkContextWindow(string file, JsonElement state)
    {
        this.file = file;
        root = state.GetProperty("root").GetString()!;
        config = JsonNode.Parse(state.GetProperty("config").GetRawText())!;
        provisional = state.GetProperty("provisional").GetBoolean();
        Width = 620;
        Height = 560;
        MinWidth = 480;
        MinHeight = 380;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        tabs.Items.Add(new TabItem { Header = NativeCore.Tr("ai.work.tab.sources"), MinWidth = 72, Content = new ScrollViewer { Content = sources, VerticalScrollBarVisibility = ScrollBarVisibility.Auto } });
        tabs.Items.Add(new TabItem { Header = NativeCore.Tr("ai.work.tab.episodes"), MinWidth = 72, Content = new ScrollViewer { Content = episodes, VerticalScrollBarVisibility = ScrollBarVisibility.Auto } });
        tabs.Items.Add(new TabItem { Header = NativeCore.Tr("ai.work.tab.folders"), MinWidth = 72, Content = new ScrollViewer { Content = folders, VerticalScrollBarVisibility = ScrollBarVisibility.Auto } });
        Content = tabs;

        Closing += (_, _) => CommitPendingChanges();
        Action changed = Render;
        WorkIndex.Changed += changed;
        Closed += (_, _) =>
        {
            WorkIndex.Changed -= changed;
            Open.Remove(root);
        };
        Render();
    }

    /// <summary>
    /// Closing saves, as on macOS: a title still being typed, and a first setup that is valid as
    /// suggested. One that is not valid yet stays unsaved.
    /// </summary>
    public void CommitPendingChanges()
    {
        var typed = titleBox?.Text.Trim();
        var saved = config["title"]?.GetValue<string>();
        if (provisional || (typed != null && typed != saved)) Apply(new { op = "setTitle", title = string.IsNullOrEmpty(typed) ? saved : typed });
    }

    /// <summary>One change, applied the way macOS does it. A refusal shows in the window and changes nothing.</summary>
    public void Apply(object edit)
    {
        using var state = JsonDocument.Parse(NativeCore.WorkWindowEdit(root, config.ToJsonString(), provisional, JsonSerializer.Serialize(edit)));
        var result = state.RootElement;
        var newRoot = result.GetProperty("root").GetString()!;
        if (!string.Equals(newRoot, root, StringComparison.OrdinalIgnoreCase))
        {
            Open.Remove(root);
            Open[newRoot] = this;
            root = newRoot;
        }
        config = JsonNode.Parse(result.GetProperty("config").GetRawText())!;
        provisional = result.GetProperty("provisional").GetBoolean();
        rejection = result.TryGetProperty("error", out var error) ? error.GetString() : null;
        Render();
        if (rejection == null)
        {
            if (!provisional) WorkIndex.Schedule(file);
            WorkIndex.NotifyChanged();
        }
    }

    static TextBlock Text(string text, double size = 13, bool muted = false, bool bold = false) => new()
    {
        Text = text,
        TextWrapping = TextWrapping.Wrap,
        FontSize = size,
        Opacity = muted ? 0.7 : 1,
        FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
        Margin = new Thickness(0, 0, 0, 8),
    };

    static Button Action(string text, Action click)
    {
        var button = new Button { Content = text, Padding = new Thickness(10, 2, 10, 2), Margin = new Thickness(0, 0, 6, 0), HorizontalAlignment = HorizontalAlignment.Left };
        button.Click += (_, _) => click();
        return button;
    }

    static string Size(long bytes) => bytes >= 1_000_000 ? $"{bytes / 1_000_000.0:0.0}MB" : $"{Math.Round(bytes / 1000.0)}KB";

    int renderRequest;

    /// <summary>Listing a long work takes seconds, so the window stays usable while the rows arrive.</summary>
    async void Render()
    {
        var title = config["title"]?.GetValue<string>() ?? "";
        Title = NativeCore.Tr("ai.work.window.title").Replace("%@", title);
        // Rendering again must not take the title out from under someone typing it.
        if (titleBox?.IsKeyboardFocusWithin != true) RenderFolders();
        var request = ++renderRequest;
        var (currentRoot, currentConfig) = (root, config.ToJsonString());
        try
        {
            var json = await Task.Run(() => NativeCore.WorkWindowDescribe(currentRoot, currentConfig, file));
            if (request != renderRequest) return;
            using var described = JsonDocument.Parse(json);
            RenderSources(described.RootElement);
            RenderEpisodes(described.RootElement);
        }
        catch (InvalidOperationException error)
        {
            Trace.TraceWarning("Could not list the work: {0}", error.Message);
        }
    }

    void RenderSources(JsonElement info)
    {
        sources.Children.Clear();
        sources.Children.Add(Text(NativeCore.Tr("ai.work.sources.header"), bold: true));
        sources.Children.Add(Text(NativeCore.Tr("doc.aiIndexAutomatic"), 12, muted: true));
        if (rejection != null) sources.Children.Add(Text(rejection, 12));

        var list = info.GetProperty("sources");
        if (list.GetArrayLength() == 0) sources.Children.Add(Text(NativeCore.Tr("ai.work.sources.empty"), 12, muted: true));
        foreach (var source in list.EnumerateArray())
        {
            var path = source.GetProperty("path").GetString()!;
            var row = new DockPanel { Margin = new Thickness(0, 0, 0, 4) };
            var remove = Action(NativeCore.Tr("ai.work.remove"), () => Apply(new { op = "removeSource", path }));
            remove.Margin = new Thickness(8, 0, 0, 0);
            DockPanel.SetDock(remove, Dock.Right);
            row.Children.Add(remove);
            var label = path;
            if (source.GetProperty("isDirectory").GetBoolean()) label += $"  ·  {source.GetProperty("fileCount").GetInt32()}";
            if (!source.GetProperty("exists").GetBoolean()) label += "  ·  " + NativeCore.Tr("sidebar.missing");
            row.Children.Add(new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
            sources.Children.Add(row);
        }

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 12) };
        actions.Children.Add(Action(NativeCore.Tr("ai.work.sources.addFolder"), () =>
        {
            var dialog = new OpenFolderDialog { InitialDirectory = root };
            if (dialog.ShowDialog(this) == true) Apply(new { op = "addSource", path = dialog.FolderName });
        }));
        actions.Children.Add(Action(NativeCore.Tr("ai.work.sources.addFile"), () =>
        {
            var dialog = new OpenFileDialog { InitialDirectory = root, Filter = "Markdown (*.md;*.markdown;*.txt)|*.md;*.markdown;*.txt" };
            if (dialog.ShowDialog(this) == true) Apply(new { op = "addSource", path = dialog.FileName });
        }));
        sources.Children.Add(actions);

        var invalid = info.GetProperty("invalidPaths").EnumerateArray().Select(item => item.GetString()).ToList();
        if (invalid.Count > 0) sources.Children.Add(Text(NativeCore.Tr("ai.work.invalidPaths").Replace("%@", string.Join(", ", invalid)), 12));

        sources.Children.Add(Text(NativeCore.Tr("ai.index.files").Replace("%d", info.GetProperty("included").GetInt32().ToString()), bold: true));
        sources.Children.Add(Text(info.GetProperty("status").GetString() ?? "", 12, muted: true));
        foreach (var item in info.GetProperty("files").EnumerateArray())
        {
            var path = item.GetProperty("path").GetString()!;
            var bytes = item.GetProperty("bytes").GetInt64();
            var unreadable = item.GetProperty("unreadable").GetBoolean();
            var label = $"{path}  ·  {Size(bytes)}";
            if (bytes > 200_000) label += "  ·  " + NativeCore.Tr("ai.work.largeFile");
            if (unreadable) label += "  ·  " + NativeCore.Tr("ai.work.unreadable");
            var box = new CheckBox { Content = label, IsChecked = item.GetProperty("included").GetBoolean(), Margin = new Thickness(0, 0, 0, 2) };
            box.Click += (_, _) => Apply(new { op = "toggleInclude", path });
            sources.Children.Add(box);
        }
    }

    void RenderEpisodes(JsonElement info)
    {
        episodes.Children.Clear();
        episodes.Children.Add(Text(NativeCore.Tr("doc.aiIndexAutomatic"), 12, muted: true));
        var running = WorkIndex.IsRunning(file);
        episodes.Children.Add(Text(running ? NativeCore.Tr("ai.index.waiting") : info.GetProperty("status").GetString() ?? ""));
        if (WorkIndex.LastError != null && !running) episodes.Children.Add(Text(NativeCore.Tr("ai.index.failed") + " " + WorkIndex.LastError, 12));
        episodes.Children.Add(Text(info.GetProperty("counts").GetString() ?? "", 12, muted: true));
        foreach (var reason in info.GetProperty("reasons").EnumerateArray()) episodes.Children.Add(Text(reason.GetString() ?? "", 12, muted: true));
        var retry = Action(NativeCore.Tr("ai.index.retry"), () => _ = WorkIndex.PrepareAsync(file));
        retry.IsEnabled = !provisional && config["enabled"]?.GetValue<bool>() == true && !running;
        retry.Margin = new Thickness(0, 0, 0, 12);
        episodes.Children.Add(retry);
        foreach (var item in info.GetProperty("previous").EnumerateArray())
        {
            episodes.Children.Add(Text($"{item.GetProperty("path").GetString()}  ·  {item.GetProperty("ready").GetInt32()}/{item.GetProperty("total").GetInt32()}", 12));
        }
    }

    void RenderFolders()
    {
        folders.Children.Clear();
        if (rejection != null) folders.Children.Add(Text(rejection, 12));

        UIElement Row(string label, UIElement main, UIElement? trailing)
        {
            var row = new DockPanel { Margin = new Thickness(0, 0, 0, 10) };
            var name = new TextBlock { Text = label, Width = 90, VerticalAlignment = VerticalAlignment.Center };
            DockPanel.SetDock(name, Dock.Left);
            row.Children.Add(name);
            if (trailing != null)
            {
                DockPanel.SetDock(trailing, Dock.Right);
                row.Children.Add(trailing);
            }
            row.Children.Add(main);
            return row;
        }

        string? Pick(string start)
        {
            var dialog = new OpenFolderDialog { InitialDirectory = start };
            return dialog.ShowDialog(this) == true ? dialog.FolderName : null;
        }

        folders.Children.Add(Row(NativeCore.Tr("ai.work.folders.root"),
            new TextBlock { Text = root, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, ToolTip = root },
            Action(NativeCore.Tr("ai.work.folders.change"), () =>
            {
                if (Pick(root) is { } chosen) Apply(new { op = "setRoot", path = chosen });
            })));

        var writingRelative = config["writingFolder"]?.GetValue<string>() ?? "";
        var writing = writingRelative.Length == 0 ? root : Path.Combine(root, writingRelative.Replace('/', Path.DirectorySeparatorChar));
        folders.Children.Add(Row(NativeCore.Tr("ai.work.folders.writing"),
            new TextBlock { Text = writing, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, ToolTip = writing },
            Action(NativeCore.Tr("ai.work.folders.change"), () =>
            {
                if (Pick(writing) is { } chosen) Apply(new { op = "setWriting", path = chosen });
            })));

        var title = new TextBox { Text = config["title"]?.GetValue<string>() ?? "" };
        titleBox = title;
        title.LostFocus += (_, _) =>
        {
            if (title.Text.Trim() != config["title"]?.GetValue<string>()) Apply(new { op = "setTitle", title = title.Text });
        };
        folders.Children.Add(Row(NativeCore.Tr("ai.work.folders.title"), title, null));

        var hasSources = (config["settingsSources"]?.AsArray().Count ?? 0) > 0;
        var enable = new CheckBox
        {
            Content = NativeCore.Tr("ai.work.folders.enable"),
            IsChecked = config["enabled"]?.GetValue<bool>() == true,
            IsEnabled = hasSources,
            Margin = new Thickness(90, 4, 0, 4),
        };
        enable.Click += (_, _) => Apply(new { op = "setEnabled", on = enable.IsChecked == true });
        folders.Children.Add(enable);
        if (!hasSources) folders.Children.Add(new TextBlock { Text = NativeCore.Tr("ai.work.folders.needsSources"), Margin = new Thickness(90, 0, 0, 0), FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap });
    }
}
