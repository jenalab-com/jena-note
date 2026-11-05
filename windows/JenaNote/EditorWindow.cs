using System.ComponentModel;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Win32;

namespace JenaNote;

/// <summary>One document in one window.</summary>
sealed class EditorWindow : Window
{
    readonly EditorView editor = new();
    string? filePath;
    bool plainText;
    int currentRevision;
    int savedRevision;
    bool closeConfirmed;
    bool saving;
    Task? ready;

    bool IsDirty => currentRevision != savedRevision;
    bool IsPristine => filePath == null && !IsDirty;

    public EditorWindow(string? path = null, string? initialText = null)
    {
        Width = 1100;
        Height = 800;
        MinWidth = 480;
        MinHeight = 320;

        var layout = new DockPanel();
        var menu = BuildMenu();
        DockPanel.SetDock(menu, Dock.Top);
        layout.Children.Add(menu);
        layout.Children.Add(editor);
        Content = layout;

        filePath = path;
        plainText = path != null && DocumentFile.IsPlainText(path);
        editor.DocumentFolder = path != null ? Path.GetDirectoryName(Path.GetFullPath(path)) : null;
        UpdateTitle();

        editor.Changed += revision =>
        {
            currentRevision = revision + revisionOffset;
            UpdateTitle();
        };
        editor.CommandRequested += RunCommand;
        editor.DocumentPath = path;
        editor.AddToDictionaryRequested += term => DictionaryWindow.Present(this, filePath, term);
        editor.AlertRequested += text => MessageBox.Show(this, text, "Jena Note", MessageBoxButton.OK, MessageBoxImage.Information);
        Action dictionaryChanged = editor.DictionaryChanged;
        DictionaryWindow.Changed += dictionaryChanged;
        Closed += (_, _) => DictionaryWindow.Changed -= dictionaryChanged;
        Loaded += (_, _) => ready = StartEditorAsync(initialText ?? "");
        Activated += (_, _) => editor.Focus();
    }

    /// <summary>The page restarts its count on load; this keeps window revisions increasing.</summary>
    int revisionOffset;

    public EditorView Editor => editor;

    public Task WhenReady() => ready ?? Task.CompletedTask;

    async Task StartEditorAsync(string text)
    {
        await editor.InitializeAsync();
        LoadIntoEditor(text);
    }

    void LoadIntoEditor(string text)
    {
        revisionOffset = currentRevision + 1;
        currentRevision = revisionOffset;
        savedRevision = currentRevision;
        if (plainText) editor.LoadPlainText(text);
        else editor.LoadMarkdown(text);
        // Focus inside the page is not enough. Keys go to the native control that holds focus.
        editor.Focus();
        UpdateTitle();
    }

    void UpdateTitle()
    {
        var name = filePath != null ? Path.GetFileName(filePath) : NativeCore.Tr("doc.untitled");
        Title = $"{(IsDirty ? "● " : "")}{name} - Jena Note";
    }

    // MARK: - Menu

    Menu BuildMenu()
    {
        static MenuItem Top(string key, params object[] items)
        {
            var item = new MenuItem { Header = NativeCore.Tr(key) };
            foreach (var child in items) item.Items.Add(child);
            return item;
        }
        static MenuItem Item(string key, string gesture, Action action)
        {
            var item = new MenuItem { Header = NativeCore.Tr(key), InputGestureText = gesture };
            item.Click += (_, _) => action();
            return item;
        }

        var menu = new Menu();
        menu.Items.Add(Top("menu.file",
            Item("menu.file.new", "Ctrl+N", () => RunCommand("new")),
            Item("menu.file.open", "Ctrl+O", () => RunCommand("open")),
            new Separator(),
            Item("menu.file.save", "Ctrl+S", () => RunCommand("save")),
            Item("menu.file.saveAs", "Ctrl+Shift+S", () => RunCommand("saveAs")),
            new Separator(),
            Top("menu.file.export",
                Item("menu.file.export.docx", "", () => RunCommand("exportDocx")),
                Item("menu.file.export.hwpx", "", () => RunCommand("exportHwpx"))),
            new Separator(),
            Item("menu.file.close", "", Close)));
        menu.Items.Add(Top("menu.edit",
            Item("menu.edit.undo", "Ctrl+Z", () => editor.RunNative("undo")),
            Item("menu.edit.redo", "Ctrl+Y", () => editor.RunNative("redo")),
            new Separator(),
            Item("menu.edit.cut", "Ctrl+X", () => editor.RunNative("cut")),
            Item("menu.edit.copy", "Ctrl+C", () => editor.RunNative("copy")),
            Item("menu.edit.selectAll", "Ctrl+A", () => editor.RunNative("selectAll"))));
        menu.Items.Add(Top("menu.format",
            Item("menu.format.bold", "Ctrl+B", () => editor.Run("bold")),
            Item("menu.format.italic", "Ctrl+I", () => editor.Run("italic")),
            Item("menu.format.code", "", () => editor.Run("code")),
            new Separator(),
            Item("menu.format.body", "", () => editor.Run("body")),
            Item("menu.format.h1", "", () => editor.Run("h1")),
            Item("menu.format.h2", "", () => editor.Run("h2")),
            Item("menu.format.h3", "", () => editor.Run("h3")),
            new Separator(),
            Item("menu.format.ul", "", () => editor.Run("ul")),
            Item("menu.format.ol", "", () => editor.Run("ol")),
            Item("menu.format.quote", "", () => editor.Run("quote")),
            new Separator(),
            Item("menu.format.link", "", () => editor.Run("link")),
            Item("menu.format.textColor", "", () => editor.Run("color")),
            new Separator(),
            Item("proof.button", "", () => editor.Run("proofSelection")),
            Item("dictionary.title", "", () => DictionaryWindow.Present(this, filePath, ""))));

        // Shortcuts when the focus is on the menu rather than in the page.
        InputBindings.Add(new KeyBinding(new RelayCommand(() => RunCommand("save")), Key.S, ModifierKeys.Control));
        InputBindings.Add(new KeyBinding(new RelayCommand(() => RunCommand("saveAs")), Key.S, ModifierKeys.Control | ModifierKeys.Shift));
        InputBindings.Add(new KeyBinding(new RelayCommand(() => RunCommand("open")), Key.O, ModifierKeys.Control));
        InputBindings.Add(new KeyBinding(new RelayCommand(() => RunCommand("new")), Key.N, ModifierKeys.Control));
        return menu;
    }

    sealed class RelayCommand(Action action) : ICommand
    {
        public event EventHandler? CanExecuteChanged { add { } remove { } }
        public bool CanExecute(object? parameter) => true;
        public void Execute(object? parameter) => action();
    }

    async void RunCommand(string name)
    {
        switch (name)
        {
            case "new":
                new EditorWindow().Show();
                break;
            case "open":
                OpenWithDialog();
                break;
            case "save":
                await SaveAsync(chooseLocation: false);
                break;
            case "saveAs":
                await SaveAsync(chooseLocation: true);
                break;
            case "exportDocx":
                await ExportWithDialogAsync("docx");
                break;
            case "exportHwpx":
                await ExportWithDialogAsync("hwpx");
                break;
        }
    }

    // MARK: - Open

    static string FileFilter() =>
        $"{NativeCore.Tr("doc.filter.markdown")} (*.md)|*.md;*.markdown|{NativeCore.Tr("doc.filter.text")} (*.txt)|*.txt";

    void OpenWithDialog()
    {
        var dialog = new OpenFileDialog { Filter = FileFilter() };
        if (dialog.ShowDialog(this) != true) return;
        if (Open(dialog.FileName, IsPristine ? this : null) is null) return;
    }

    /// <summary>Opens a file, reusing `target` when given. Returns null when the file cannot be read.</summary>
    public static EditorWindow? Open(string path, EditorWindow? target)
    {
        string text;
        try
        {
            text = DocumentFile.Read(path);
        }
        catch (DocumentFile.NotUtf8Exception)
        {
            MessageBox.Show(NativeCore.Tr("open.notUTF8"), "Jena Note", MessageBoxButton.OK, MessageBoxImage.Warning);
            return null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            MessageBox.Show(NativeCore.Tr("doc.openFailed").Replace("%@", error.Message), "Jena Note",
                MessageBoxButton.OK, MessageBoxImage.Warning);
            return null;
        }

        if (target == null)
        {
            var window = new EditorWindow(path, text);
            window.Show();
            return window;
        }
        target.filePath = path;
        target.plainText = DocumentFile.IsPlainText(path);
        target.editor.DocumentFolder = Path.GetDirectoryName(Path.GetFullPath(path));
        target.editor.DocumentPath = path;
        target.LoadIntoEditor(text);
        return target;
    }

    // MARK: - Save

    public async Task<bool> SaveAsync(bool chooseLocation)
    {
        // A second Ctrl+S during a slow save must not race the first one to the same file.
        if (saving) return false;
        var path = filePath;
        if (path == null || chooseLocation)
        {
            var dialog = new SaveFileDialog
            {
                Filter = FileFilter(),
                FileName = filePath != null ? Path.GetFileName(filePath) : NativeCore.Tr("doc.untitled"),
                FilterIndex = plainText ? 2 : 1,
                DefaultExt = plainText ? ".txt" : ".md",
                AddExtension = true,
            };
            if (filePath != null) dialog.InitialDirectory = Path.GetDirectoryName(Path.GetFullPath(filePath));
            if (dialog.ShowDialog(this) != true) return false;
            path = dialog.FileName;
        }

        saving = true;
        try
        {
            var saveAsPlain = DocumentFile.IsPlainText(path);
            var content = await editor.GetContentAsync(saveAsPlain ? "text" : "blocks");
            var text = TextToSave(content, saveAsPlain);
            DocumentFile.Write(path, text);

            var pageRevision = content.GetProperty("revision").GetInt32();
            var modeChanged = saveAsPlain != plainText;
            filePath = path;
            plainText = saveAsPlain;
            editor.DocumentFolder = Path.GetDirectoryName(Path.GetFullPath(path));
            editor.DocumentPath = path;
            if (modeChanged)
            {
                LoadIntoEditor(text);
            }
            else
            {
                // Typing that arrived while saving stays unsaved, because its revision is newer.
                savedRevision = pageRevision + revisionOffset;
                UpdateTitle();
            }
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException or ArgumentException or NotSupportedException)
        {
            MessageBox.Show(this, NativeCore.Tr("doc.saveFailed").Replace("%@", error.Message), "Jena Note",
                MessageBoxButton.OK, MessageBoxImage.Warning);
            return false;
        }
        finally
        {
            saving = false;
        }
    }

    string TextToSave(JsonElement content, bool asPlain)
    {
        if (content.TryGetProperty("text", out var text))
        {
            // A plain text document saved as Markdown keeps its characters.
            return text.GetString() ?? "";
        }
        return NativeCore.JsonToMarkdown(content.GetProperty("blocks").GetRawText());
    }

    // MARK: - Export

    /// <summary>A separate file, not a save: the document keeps its own file and changed state.</summary>
    async Task ExportWithDialogAsync(string format)
    {
        var baseName = filePath != null ? Path.GetFileNameWithoutExtension(filePath) : NativeCore.Tr("doc.untitled");
        var dialog = new SaveFileDialog
        {
            FileName = $"{baseName}.{format}",
            DefaultExt = "." + format,
            Filter = $"{NativeCore.Tr($"menu.file.export.{format}")}|*.{format}",
            AddExtension = true,
        };
        if (dialog.ShowDialog(this) != true) return;
        await ExportAsync(format, dialog.FileName);
    }

    public async Task<int?> ExportAsync(string format, string path)
    {
        try
        {
            var content = await editor.GetContentAsync("export");
            var (data, skipped) = NativeCore.Export(content.GetProperty("blocks").GetRawText(), format, editor.DocumentFolder);
            DocumentFile.WriteBytes(path, data);
            if (skipped > 0 && !IsSelfTesting)
            {
                MessageBox.Show(this, NativeCore.Tr("export.warn.imageSkipped").Replace("%d", skipped.ToString()),
                    NativeCore.Tr("export.warn.title"), MessageBoxButton.OK, MessageBoxImage.Warning);
            }
            return skipped;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException or ArgumentException or NotSupportedException)
        {
            if (!IsSelfTesting)
            {
                MessageBox.Show(this, NativeCore.Tr("export.error.message"), NativeCore.Tr("export.error.title"),
                    MessageBoxButton.OK, MessageBoxImage.Error);
            }
            return null;
        }
    }

    /// <summary>Message boxes would stop the unattended self test.</summary>
    public static bool IsSelfTesting { get; set; }

    // MARK: - Close

    protected override async void OnClosing(CancelEventArgs e)
    {
        base.OnClosing(e);
        if (closeConfirmed || !IsDirty) return;

        // Closing waits for the answer and for the save, so it starts again afterwards.
        e.Cancel = true;
        var name = filePath != null ? Path.GetFileName(filePath) : NativeCore.Tr("doc.untitled");
        var answer = MessageBox.Show(this, NativeCore.Tr("doc.unsaved").Replace("%@", name), "Jena Note",
            MessageBoxButton.YesNoCancel, MessageBoxImage.Question);
        if (answer == MessageBoxResult.Cancel) return;
        if (answer == MessageBoxResult.Yes && !await SaveAsync(chooseLocation: false)) return;
        closeConfirmed = true;
        Close();
    }
}
