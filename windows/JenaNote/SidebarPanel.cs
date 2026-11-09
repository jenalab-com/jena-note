using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Threading;
using Microsoft.Win32;

namespace JenaNote;

/// <summary>The registered folders as a tree, and search across their documents.</summary>
sealed class SidebarPanel : DockPanel
{
    sealed record Node(string Path, bool IsDirectory, bool IsRoot, bool IsMissing);
    sealed record Hit(string Path, int Ordinal, string Query);

    readonly EditorWindow window;
    readonly TreeView tree = new() { BorderThickness = new Thickness(0) };
    readonly TreeView results = new() { BorderThickness = new Thickness(0), Visibility = Visibility.Collapsed };
    readonly TextBox search = new() { Margin = new Thickness(6, 0, 6, 6) };
    readonly TextBlock searchHint = new() { IsHitTestVisible = false, Opacity = 0.55, Margin = new Thickness(16, 6, 0, 0) };
    readonly TextBlock notice = new() { Margin = new Thickness(10, 4, 10, 4), TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
    readonly StackPanel empty = new() { Margin = new Thickness(12), Visibility = Visibility.Collapsed };
    readonly TextBlock emptyMessage = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8) };
    readonly Button emptyButton = new() { HorizontalAlignment = HorizontalAlignment.Left, Padding = new Thickness(10, 2, 10, 2) };
    readonly DockPanel header = new() { Margin = new Thickness(8, 6, 6, 6), LastChildFill = true };
    readonly DispatcherTimer searchTimer = new() { Interval = TimeSpan.FromMilliseconds(250) };
    int searchRequest;
    string? currentFile;

    public SidebarPanel(EditorWindow window)
    {
        this.window = window;
        Build();
        searchTimer.Tick += async (_, _) =>
        {
            searchTimer.Stop();
            await RunSearchAsync();
        };
        search.TextChanged += (_, _) =>
        {
            searchHint.Visibility = search.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            searchTimer.Stop();
            if (search.Text.Trim().Length == 0) ExitSearch();
            else searchTimer.Start();
        };
        search.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                search.Clear();
                e.Handled = true;
            }
        };
        tree.PreviewMouseLeftButtonUp += (_, e) => ActivateClicked(e);
        results.PreviewMouseLeftButtonUp += (_, e) => ActivateClicked(e);
        tree.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter && tree.SelectedItem is TreeViewItem { Tag: Node node })
            {
                Activate(node);
                e.Handled = true;
            }
        };
        emptyButton.Click += (_, _) => AddFolder();

        Action reload = Reload;
        Action settings = () =>
        {
            ApplyStrings();
            Reload();
        };
        FolderWatch.Changed += reload;
        AppSettings.Changed += settings;
        Unloaded += (_, _) =>
        {
            FolderWatch.Changed -= reload;
            AppSettings.Changed -= settings;
        };
        Loaded += (_, _) =>
        {
            FolderWatch.Changed -= reload;
            AppSettings.Changed -= settings;
            FolderWatch.Changed += reload;
            AppSettings.Changed += settings;
        };
        ApplyStrings();
        Reload();
    }

    public void FocusSearch()
    {
        search.Focus();
        search.SelectAll();
    }

    void Build()
    {
        SetDock(header, Dock.Top);
        Children.Add(header);

        var searchHost = new Grid();
        searchHost.Children.Add(search);
        searchHost.Children.Add(searchHint);
        SetDock(searchHost, Dock.Top);
        Children.Add(searchHost);

        SetDock(notice, Dock.Top);
        Children.Add(notice);

        empty.Children.Add(emptyMessage);
        empty.Children.Add(emptyButton);
        SetDock(empty, Dock.Top);
        Children.Add(empty);

        var content = new Grid();
        content.Children.Add(tree);
        content.Children.Add(results);
        Children.Add(content);
    }


    void ApplyStrings()
    {
        header.Children.Clear();
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        // Glyphs of Segoe Fluent Icons: Sort, Document, NewFolder and Add, in the macOS order.
        var sort = Palette.IconButton("\uE8CB", NativeCore.Tr("sidebar.sort.tooltip"), (_, _) => { });
        sort.Click += (_, _) =>
        {
            var menu = SortMenu();
            menu.PlacementTarget = sort;
            menu.IsOpen = true;
        };
        buttons.Children.Add(sort);
        buttons.Children.Add(Palette.IconButton("\uE8A5", NativeCore.Tr("sidebar.create.document"), (_, _) => CreateIn(TargetFolder(), isDirectory: false)));
        buttons.Children.Add(Palette.IconButton("\uE8F4", NativeCore.Tr("sidebar.create.folder"), (_, _) => CreateIn(TargetFolder(), isDirectory: true)));
        buttons.Children.Add(Palette.IconButton("\uE710", NativeCore.Tr("sidebar.add.tooltip"), (_, _) => AddFolder()));
        SetDock(buttons, Dock.Right);
        header.Children.Add(buttons);
        var title = new TextBlock { Text = NativeCore.Tr("sidebar.title"), FontWeight = FontWeights.SemiBold, FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
        title.SetResourceReference(TextBlock.ForegroundProperty, Palette.Muted);
        header.Children.Add(title);

        searchHint.Text = NativeCore.Tr("sidebar.search.placeholder");
        emptyMessage.Text = NativeCore.Tr("sidebar.empty.message");
        emptyButton.Content = NativeCore.Tr("sidebar.empty.button");
    }

    ContextMenu SortMenu()
    {
        MenuItem Choice(string key, bool isChecked, Action<AppSettings> change)
        {
            var item = new MenuItem { Header = NativeCore.Tr(key), IsCheckable = true, IsChecked = isChecked };
            item.Click += (_, _) => AppSettings.Update(change);
            return item;
        }
        var settings = AppSettings.Current;
        var menu = new ContextMenu();
        menu.Items.Add(Choice("sidebar.sort.name", settings.SidebarSortKey == "name", s => s.SidebarSortKey = "name"));
        menu.Items.Add(Choice("sidebar.sort.date", settings.SidebarSortKey == "date", s => s.SidebarSortKey = "date"));
        menu.Items.Add(new Separator());
        menu.Items.Add(Choice("sidebar.sort.asc", settings.SidebarAscending, s => s.SidebarAscending = true));
        menu.Items.Add(Choice("sidebar.sort.desc", !settings.SidebarAscending, s => s.SidebarAscending = false));
        return menu;
    }

    // MARK: - Tree

    /// <summary>
    /// Brings the tree up to date in place. This runs on every save in a watched folder, so the
    /// scroll position, selection and open folders have to survive it.
    /// </summary>
    public void Reload()
    {
        var selected = (tree.SelectedItem as TreeViewItem)?.Tag as Node;
        var folders = AppSettings.Current.SidebarFolders;
        empty.Visibility = folders.Count == 0 && results.Visibility != Visibility.Visible ? Visibility.Visible : Visibility.Collapsed;
        Sync(tree, folders.Select(folder => new Node(folder, true, true, !Directory.Exists(folder))).ToList());
        if (selected != null && tree.SelectedItem == null) SelectPath(selected.Path);
        ShowCurrentFile(currentFile);
    }

    void Sync(ItemsControl parent, List<Node> nodes)
    {
        var items = parent.Items;
        var wanted = nodes.Select(node => node.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        for (var index = items.Count - 1; index >= 0; index--)
        {
            // This also drops the placeholder of a folder that has not been opened yet.
            if (items[index] is not TreeViewItem { Tag: Node node } || !wanted.Contains(node.Path)) items.RemoveAt(index);
        }
        var existing = items.OfType<TreeViewItem>().ToDictionary(item => ((Node)item.Tag).Path, StringComparer.OrdinalIgnoreCase);
        for (var index = 0; index < nodes.Count; index++)
        {
            var node = nodes[index];
            if (existing.TryGetValue(node.Path, out var item) && Equals(item.Tag, node))
            {
                if (!ReferenceEquals(items[index], item))
                {
                    items.Remove(item);
                    items.Insert(index, item);
                }
                Refresh(item, node);
            }
            else
            {
                if (item != null) items.Remove(item);
                items.Insert(index, MakeItem(node));
            }
        }
    }

    static string Label(Node node)
    {
        var name = Path.GetFileName(node.Path.TrimEnd(Path.DirectorySeparatorChar));
        if (name.Length == 0) name = node.Path;
        return node.IsMissing ? name + " — " + NativeCore.Tr("sidebar.missing") : name;
    }

    /// <summary>The name with a folder or document glyph in front, as in the macOS sidebar.</summary>
    static StackPanel Header(Node node)
    {
        var glyph = new TextBlock
        {
            Text = node.IsDirectory ? "\uE8B7" : "\uE8A5",
            FontFamily = Palette.Icons,
            FontSize = 13,
            Margin = new Thickness(0, 1, 7, 0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        glyph.SetResourceReference(TextBlock.ForegroundProperty, Palette.Muted);
        var header = new StackPanel { Orientation = Orientation.Horizontal, Opacity = node.IsMissing ? 0.6 : 1 };
        header.Children.Add(glyph);
        header.Children.Add(new TextBlock { Text = Label(node), VerticalAlignment = VerticalAlignment.Center });
        return header;
    }

    static string HeaderText(TreeViewItem item) => item.Header switch
    {
        string text => text,
        StackPanel { Children.Count: > 0 } panel => (panel.Children[^1] as TextBlock)?.Text ?? "",
        _ => "",
    };

    void Refresh(TreeViewItem item, Node node)
    {
        item.Header = Header(node);
        if (!node.IsDirectory || node.IsMissing) return;
        if (item.IsExpanded) Fill(item, node);
        else if (AppSettings.Current.SidebarExpanded.Contains(node.Path)) item.IsExpanded = true;
    }

    TreeViewItem MakeItem(Node node)
    {
        var item = new TreeViewItem { Tag = node, Header = Header(node), ToolTip = node.Path };
        // Filled when it opens, so it follows the language and is not replaced by a reload while open.
        var menu = new ContextMenu();
        item.ContextMenu = menu;
        item.ContextMenuOpening += (_, _) => FillContextMenu(menu, node);
        if (node.IsDirectory && !node.IsMissing)
        {
            // Children load when opened, so a large folder costs nothing until then.
            item.Items.Add(new TreeViewItem());
            item.Expanded += (_, e) =>
            {
                if (ReferenceEquals(e.OriginalSource, item)) Fill(item, node);
            };
            item.Collapsed += (_, e) =>
            {
                if (ReferenceEquals(e.OriginalSource, item)) RememberExpanded(node.Path, false);
            };
            if (AppSettings.Current.SidebarExpanded.Contains(node.Path)) item.IsExpanded = true;
        }
        return item;
    }

    void Fill(TreeViewItem item, Node node)
    {
        RememberExpanded(node.Path, true);
        var settings = AppSettings.Current;
        Sync(item, SidebarFiles.List(node.Path, settings.SidebarSortKey, settings.SidebarAscending)
            .Select(entry => new Node(entry.Path, entry.IsDirectory, false, false)).ToList());
    }

    static void RememberExpanded(string path, bool expanded)
    {
        var set = AppSettings.Current.SidebarExpanded;
        if (expanded ? set.Add(path) : set.Remove(path)) AppSettings.SaveQuietly();
    }

    IEnumerable<TreeViewItem> AllItems(ItemsControl parent)
    {
        foreach (var child in parent.Items.OfType<TreeViewItem>())
        {
            yield return child;
            foreach (var inner in AllItems(child)) yield return inner;
        }
    }

    void SelectPath(string path)
    {
        var item = AllItems(tree).FirstOrDefault(entry => entry.Tag is Node node && string.Equals(node.Path, path, StringComparison.OrdinalIgnoreCase));
        if (item != null) item.IsSelected = true;
    }

    /// <summary>Marks the open document in the tree.</summary>
    public void ShowCurrentFile(string? path)
    {
        currentFile = path;
        foreach (var item in AllItems(tree))
        {
            if (item.Tag is Node node)
                item.FontWeight = !node.IsDirectory && path != null && string.Equals(node.Path, path, StringComparison.OrdinalIgnoreCase)
                    ? FontWeights.SemiBold
                    : FontWeights.Normal;
        }
    }

    // MARK: - Clicks

    static TreeViewItem? ItemUnder(object source)
    {
        var element = source as DependencyObject;
        while (element != null)
        {
            if (element is TreeViewItem item) return item;
            // The expander arrow opens and closes by itself.
            if (element is System.Windows.Controls.Primitives.ToggleButton) return null;
            element = element is System.Windows.Media.Visual or System.Windows.Media.Media3D.Visual3D
                ? System.Windows.Media.VisualTreeHelper.GetParent(element)
                : LogicalTreeHelper.GetParent(element);
        }
        return null;
    }

    void ActivateClicked(MouseButtonEventArgs e)
    {
        var item = ItemUnder(e.OriginalSource);
        switch (item?.Tag)
        {
            case Node node:
                if (node.IsDirectory) item.IsExpanded = !item.IsExpanded;
                else Activate(node);
                break;
            case Hit hit:
                _ = window.OpenFromSidebarAsync(hit.Path, hit.Query, hit.Ordinal);
                break;
        }
    }

    void Activate(Node node)
    {
        if (!node.IsDirectory) _ = window.OpenFromSidebarAsync(node.Path, null, 0);
    }

    string? TargetFolder()
    {
        if (tree.SelectedItem is TreeViewItem { Tag: Node node } && !node.IsMissing)
            return node.IsDirectory ? node.Path : Path.GetDirectoryName(node.Path);
        return AppSettings.Current.SidebarFolders.FirstOrDefault(Directory.Exists);
    }

    void FillContextMenu(ContextMenu menu, Node node)
    {
        menu.Items.Clear();
        void Add(string text, Action action)
        {
            var item = new MenuItem { Header = text };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }
        if (node.IsDirectory && !node.IsMissing)
        {
            Add(NativeCore.Tr("menu.file.new"), () => CreateIn(node.Path, false));
            Add(NativeCore.Tr("sidebar.action.newFolder"), () => CreateIn(node.Path, true));
            menu.Items.Add(new Separator());
        }
        if (!node.IsMissing)
        {
            Add(NativeCore.Tr("sidebar.action.rename"), () => _ = RenameAsync(node));
            Add(NativeCore.Tr("doc.recycle"), () => _ = DeleteAsync(node));
            menu.Items.Add(new Separator());
            Add(NativeCore.Tr("doc.revealExplorer"), () => Reveal(node.Path));
        }
        if (node.IsMissing) Add(NativeCore.Tr("sidebar.locate"), () => LocateFolder(node.Path));
        if (node.IsRoot) Add(NativeCore.Tr("sidebar.context.remove"), () => RemoveFolder(node.Path));
    }

    // MARK: - Actions

    public static void AddFolderPath(string path)
    {
        // Keeps the separator of a drive root, because "C:" alone means another folder.
        var full = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
        if (AppSettings.Current.SidebarFolders.Contains(full, StringComparer.OrdinalIgnoreCase)) return;
        AppSettings.Update(settings => settings.SidebarFolders.Add(full));
        FolderWatch.Follow(AppSettings.Current.SidebarFolders);
    }

    void AddFolder()
    {
        var dialog = new OpenFolderDialog { Title = NativeCore.Tr("sidebar.openPanel.title") };
        if (dialog.ShowDialog(window) == true) AddFolderPath(dialog.FolderName);
    }

    void LocateFolder(string path)
    {
        var dialog = new OpenFolderDialog { Title = NativeCore.Tr("sidebar.locate") };
        if (dialog.ShowDialog(window) != true) return;
        var located = Path.TrimEndingDirectorySeparator(Path.GetFullPath(dialog.FolderName));
        AppSettings.Update(settings =>
        {
            var index = settings.SidebarFolders.FindIndex(folder => string.Equals(folder, path, StringComparison.OrdinalIgnoreCase));
            if (index < 0) return;
            if (settings.SidebarFolders.Contains(located, StringComparer.OrdinalIgnoreCase)) settings.SidebarFolders.RemoveAt(index);
            else settings.SidebarFolders[index] = located;
        });
        FolderWatch.Follow(AppSettings.Current.SidebarFolders);
    }

    static void RemoveFolder(string path)
    {
        AppSettings.Update(settings => settings.SidebarFolders.RemoveAll(folder => string.Equals(folder, path, StringComparison.OrdinalIgnoreCase)));
        FolderWatch.Follow(AppSettings.Current.SidebarFolders);
    }

    void CreateIn(string? parent, bool isDirectory)
    {
        if (parent == null)
        {
            AddFolder();
            return;
        }
        var suggested = NativeCore.Tr(isDirectory ? "sidebar.create.folderName" : "sidebar.create.documentName");
        var title = NativeCore.Tr(isDirectory ? "sidebar.action.newFolder" : "menu.file.new");
        var name = TextPrompt.Ask(window, title, suggested, NativeCore.Tr("sidebar.create.confirm"));
        if (name == null) return;
        try
        {
            var created = isDirectory ? SidebarFiles.CreateFolder(parent, name) : SidebarFiles.CreateDocument(parent, name);
            RememberExpanded(parent, true);
            Reload();
            SelectPath(created);
            if (!isDirectory) _ = window.OpenFromSidebarAsync(created, null, 0);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
        {
            ShowError(error.Message);
        }
    }

    async Task RenameAsync(Node node)
    {
        var title = NativeCore.Tr("sidebar.action.rename");
        var name = TextPrompt.Ask(window, title, Path.GetFileName(node.Path.TrimEnd(Path.DirectorySeparatorChar)), title);
        if (name == null) return;
        try
        {
            if (!await EditorWindow.SaveDocumentsInsideAsync(node.Path)) return;
            var target = SidebarFiles.Rename(node.Path, name);
            EditorWindow.DocumentsMoved(node.Path, target);
            FolderMoved(node.Path, target);
            Reload();
            SelectPath(target);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
        {
            ShowError(error.Message);
        }
    }

    /// <summary>Registered folders and open folders keep following what was renamed.</summary>
    public static void FolderMoved(string source, string target)
    {
        AppSettings.Update(settings =>
        {
            settings.SidebarFolders = settings.SidebarFolders.Select(folder => SidebarFiles.Relocated(folder, source, target) ?? folder).ToList();
            settings.SidebarExpanded = settings.SidebarExpanded.Select(folder => SidebarFiles.Relocated(folder, source, target) ?? folder)
                .ToHashSet(StringComparer.OrdinalIgnoreCase);
        });
        FolderWatch.Follow(AppSettings.Current.SidebarFolders);
    }

    async Task DeleteAsync(Node node)
    {
        var answer = MessageBox.Show(window, $"{node.Path}\n\n{NativeCore.Tr("doc.recycleInfo")}", NativeCore.Tr("doc.recycle"),
            MessageBoxButton.OKCancel, MessageBoxImage.Warning);
        if (answer != MessageBoxResult.OK) return;
        try
        {
            if (!await EditorWindow.SaveDocumentsInsideAsync(node.Path)) return;
            // Windows let go of the documents only after this, so a refused delete keeps every change.
            SidebarFiles.MoveToRecycleBin(node.Path);
            EditorWindow.DocumentsDeleted(node.Path);
            AppSettings.Update(settings => settings.SidebarFolders.RemoveAll(folder => SidebarFiles.Relocated(folder, node.Path, node.Path) != null));
            FolderWatch.Follow(AppSettings.Current.SidebarFolders);
            Reload();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or OperationCanceledException)
        {
            ShowError(error.Message);
        }
    }

    static void Reveal(string path)
    {
        try
        {
            Process.Start(new ProcessStartInfo("explorer.exe") { ArgumentList = { "/select,", path }, UseShellExecute = false });
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            Trace.TraceWarning("Could not open Explorer: {0}", error.Message);
        }
    }

    void ShowError(string message)
    {
        if (!EditorWindow.IsSelfTesting) MessageBox.Show(window, message, "Jena Note", MessageBoxButton.OK, MessageBoxImage.Warning);
    }

    // MARK: - Search

    void ExitSearch()
    {
        searchRequest++;
        results.Items.Clear();
        results.Visibility = Visibility.Collapsed;
        tree.Visibility = Visibility.Visible;
        notice.Visibility = Visibility.Collapsed;
        empty.Visibility = AppSettings.Current.SidebarFolders.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    void ShowNotice(string? text)
    {
        notice.Text = text ?? "";
        notice.Visibility = text == null ? Visibility.Collapsed : Visibility.Visible;
    }

    public async Task RunSearchAsync()
    {
        var query = search.Text.Trim();
        if (query.Length == 0) return;
        var request = ++searchRequest;
        tree.Visibility = Visibility.Collapsed;
        results.Visibility = Visibility.Visible;
        empty.Visibility = Visibility.Collapsed;
        var folders = AppSettings.Current.SidebarFolders;
        if (folders.Count == 0)
        {
            results.Items.Clear();
            ShowNotice(NativeCore.Tr("sidebar.empty.message"));
            return;
        }

        string json;
        try
        {
            json = await NativeCore.SearchFiles(query, JsonSerializer.Serialize(folders));
        }
        catch (InvalidOperationException error)
        {
            Trace.TraceWarning("Search failed: {0}", error.Message);
            return;
        }
        // A newer search has started, or the field was cleared.
        if (request != searchRequest) return;

        results.Items.Clear();
        using var document = JsonDocument.Parse(json);
        var files = document.RootElement.GetProperty("results");
        foreach (var file in files.EnumerateArray())
        {
            var path = file.GetProperty("path").GetString()!;
            var fileItem = new TreeViewItem { Header = Path.GetFileName(path), ToolTip = path, IsExpanded = true, FontWeight = FontWeights.SemiBold };
            foreach (var hit in file.GetProperty("hits").EnumerateArray())
            {
                fileItem.Items.Add(new TreeViewItem
                {
                    Header = Snippet(hit),
                    Tag = new Hit(path, hit.GetProperty("ordinal").GetInt32(), query),
                    FontWeight = FontWeights.Normal,
                });
            }
            results.Items.Add(fileItem);
        }
        ShowNotice(files.GetArrayLength() == 0
            ? NativeCore.Tr("sidebar.search.noResults")
            : document.RootElement.GetProperty("truncated").GetBoolean() ? NativeCore.Tr("sidebar.search.truncated") : null);
    }

    public int ResultFileCount => results.Items.Count;
    public IEnumerable<string> ResultPaths => AllItems(results).Select(item => item.Tag).OfType<Hit>().Select(hit => hit.Path);
    public object? ItemFor(string path) => AllItems(tree).FirstOrDefault(item => item.Tag is Node node && string.Equals(node.Path, path, StringComparison.OrdinalIgnoreCase));
    public string SearchText { get => search.Text; set => search.Text = value; }
    public int RootCount => tree.Items.Count;
    public IEnumerable<string> VisibleNames => AllItems(tree).Where(item => item.Tag is Node).Select(HeaderText);

    static TextBlock Snippet(JsonElement hit)
    {
        var text = hit.GetProperty("text").GetString() ?? "";
        var start = Math.Clamp(hit.GetProperty("start").GetInt32(), 0, text.Length);
        var length = Math.Clamp(hit.GetProperty("length").GetInt32(), 0, text.Length - start);
        var block = new TextBlock { TextTrimming = TextTrimming.CharacterEllipsis };
        block.Inlines.Add(new Run(text[..start]));
        block.Inlines.Add(new Bold(new Run(text.Substring(start, length))));
        block.Inlines.Add(new Run(text[(start + length)..]));
        return block;
    }
}

/// <summary>Asks for one line of text, such as a file name.</summary>
sealed class TextPrompt : Window
{
    readonly TextBox box = new() { Margin = new Thickness(0, 0, 0, 12), MinWidth = 320 };
    string? answer;

    TextPrompt(Window owner, string title, string text, string confirm)
    {
        Title = title;
        Owner = owner;
        SizeToContent = SizeToContent.WidthAndHeight;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;
        box.Text = text;

        var ok = new Button { Content = confirm, IsDefault = true, MinWidth = 80, Padding = new Thickness(10, 2, 10, 2) };
        ok.Click += (_, _) =>
        {
            answer = box.Text;
            DialogResult = true;
        };
        var cancel = new Button { Content = NativeCore.Tr("confirm.cancel"), IsCancel = true, MinWidth = 80, Padding = new Thickness(10, 2, 10, 2), Margin = new Thickness(6, 0, 0, 0) };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        buttons.Children.Add(ok);
        buttons.Children.Add(cancel);
        var layout = new StackPanel { Margin = new Thickness(14) };
        layout.Children.Add(box);
        layout.Children.Add(buttons);
        Content = layout;

        Loaded += (_, _) =>
        {
            box.Focus();
            // Selects the name but not the extension, so typing replaces only the name.
            var dot = text.LastIndexOf('.');
            box.Select(0, dot > 0 ? dot : text.Length);
        };
    }

    public static string? Ask(Window owner, string title, string text, string confirm)
    {
        var prompt = new TextPrompt(owner, title, text, confirm);
        return prompt.ShowDialog() == true ? prompt.answer : null;
    }
}
