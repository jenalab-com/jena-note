using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using Microsoft.Win32;

namespace JenaNote;

/// <summary>One document in one window.</summary>
sealed class EditorWindow : Window
{
    readonly EditorView editor = new();
    readonly Menu menu = new();
    string? filePath;
    bool plainText;
    int currentRevision;
    int savedRevision;
    bool closeConfirmed;
    bool saving;
    bool closeInProgress;
    bool editorStarted;
    bool reportedBackupFailure;
    (DateTime Modified, long Length)? diskStamp;
    Task? ready;
    readonly string recoveryId;
    readonly DispatcherTimer autosaveTimer = new();
    readonly DispatcherTimer recoveryTimer = new();

    /// <summary>In-place saving, on by default as on macOS. The settings window will control these.</summary>
    public static bool AutosaveEnabled { get; set; } = true;
    public static TimeSpan AutosaveDelay { get; set; } = TimeSpan.FromSeconds(60);
    /// <summary>How soon an unsaved change gets a recovery copy.</summary>
    public static TimeSpan RecoveryDelay { get; set; } = TimeSpan.FromSeconds(5);
    /// <summary>The self test's answer to the save question on closing.</summary>
    public static MessageBoxResult CloseAnswerForTest { get; set; } = MessageBoxResult.Cancel;
    /// <summary>The self test's answer to the overwrite question, since nobody can click it.</summary>
    public static bool OverwriteAnswerForTest { get; set; }

    bool IsDirty => currentRevision != savedRevision;
    bool IsPristine => filePath == null && !IsDirty;

    public EditorWindow(string? path = null, string? initialText = null, string? recoveredId = null)
    {
        recoveryId = recoveredId ?? Guid.NewGuid().ToString("N");
        autosaveTimer.Tick += async (_, _) => await AutosaveTickAsync();
        recoveryTimer.Tick += async (_, _) => await RecoveryTickAsync();
        Width = 1100;
        Height = 800;
        MinWidth = 480;
        MinHeight = 320;

        var layout = new DockPanel();
        FillMenu();
        AddShortcuts();
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
            StartTimers();
        };
        editor.CommandRequested += RunCommand;
        editor.DocumentPath = path;
        editor.AddToDictionaryRequested += term => DictionaryWindow.Present(this, filePath, term);
        editor.AlertRequested += text => MessageBox.Show(this, text, "Jena Note", MessageBoxButton.OK, MessageBoxImage.Information);
        Action dictionaryChanged = editor.DictionaryChanged;
        DictionaryWindow.Changed += dictionaryChanged;
        Action settingsChanged = ApplySettings;
        AppSettings.Changed += settingsChanged;
        Closed += (_, _) =>
        {
            AppSettings.Changed -= settingsChanged;
            DictionaryWindow.Changed -= dictionaryChanged;
            autosaveTimer.Stop();
            recoveryTimer.Stop();
            RecoveryStore.Delete(recoveryId);
            // Tool windows must not keep the app alive once the last document is gone.
            var application = Application.Current;
            if (!IsSelfTesting && application != null && !application.Windows.OfType<EditorWindow>().Any(window => window != this))
                application.Shutdown();
        };
        Loaded += (_, _) => ready = StartEditorAsync(initialText ?? "", recoveredId != null);
        Activated += (_, _) =>
        {
            editor.Focus();
            CheckDiskChange();
        };
    }

    /// <summary>The page restarts its count on load; this keeps window revisions increasing.</summary>
    int revisionOffset;

    public EditorView Editor => editor;
    public string FirstMenuHeader => (menu.Items[0] as MenuItem)?.Header as string ?? "";

    public Task WhenReady() => ready ?? Task.CompletedTask;

    async Task StartEditorAsync(string text, bool recovered)
    {
        await editor.InitializeAsync();
        editorStarted = true;
        LoadIntoEditor(text, dirty: recovered);
    }

    void LoadIntoEditor(string text, bool dirty = false)
    {
        revisionOffset = currentRevision + 1;
        currentRevision = revisionOffset;
        savedRevision = dirty ? currentRevision - 1 : currentRevision;
        diskStamp = filePath != null ? DocumentFile.Stamp(filePath) : null;
        if (plainText) editor.LoadPlainText(text);
        else editor.LoadMarkdown(text);
        // Focus inside the page is not enough. Keys go to the native control that holds focus.
        editor.Focus();
        UpdateTitle();
        StartTimers();
    }

    void UpdateTitle()
    {
        var name = filePath != null ? Path.GetFileName(filePath) : NativeCore.Tr("doc.untitled");
        Title = $"{(IsDirty ? "● " : "")}{name} - Jena Note";
    }

    // MARK: - Menu

    void FillMenu()
    {
        menu.Items.Clear();
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
            Item("backup.title", "", () => RunCommand("history")),
            new Separator(),
            Item("menu.app.settings", "Ctrl+,", () => RunCommand("settings")),
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
    }

    void AddShortcuts()
    {
        // Shortcuts when the focus is on the menu rather than in the page.
        InputBindings.Add(new KeyBinding(new RelayCommand(() => RunCommand("save")), Key.S, ModifierKeys.Control));
        InputBindings.Add(new KeyBinding(new RelayCommand(() => RunCommand("saveAs")), Key.S, ModifierKeys.Control | ModifierKeys.Shift));
        InputBindings.Add(new KeyBinding(new RelayCommand(() => RunCommand("open")), Key.O, ModifierKeys.Control));
        InputBindings.Add(new KeyBinding(new RelayCommand(() => RunCommand("new")), Key.N, ModifierKeys.Control));
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
            case "settings":
                SettingsWindow.Present(this);
                break;
            case "history":
                if (filePath == null)
                    MessageBox.Show(this, NativeCore.Tr("backup.saveFirst"), "Jena Note", MessageBoxButton.OK, MessageBoxImage.Information);
                else
                    new HistoryWindow(this, filePath).Show();
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

        return await WriteAsync(path, automatic: false);
    }

    /// <summary>
    /// Writes the document, keeping history around the write. Automatic saves never interrupt:
    /// they stay quiet on failure and leave a file that another program changed alone.
    /// </summary>
    async Task<bool> WriteAsync(string path, bool automatic)
    {
        if (saving) return false;
        saving = true;
        try
        {
            var sameFile = filePath != null && string.Equals(Path.GetFullPath(filePath), Path.GetFullPath(path), StringComparison.OrdinalIgnoreCase);
            var changedOnDisk = sameFile && ChangedOnDisk(path);
            if (changedOnDisk && (automatic || !ConfirmOverwrite(path))) return false;

            var saveAsPlain = DocumentFile.IsPlainText(path);
            var content = await editor.GetContentAsync(saveAsPlain ? "text" : "blocks");
            var text = TextToSave(content, saveAsPlain);
            var bytes = new UTF8Encoding(false).GetBytes(text);

            KeepHistoryBeforeWrite(path, changedOnDisk);
            DocumentFile.WriteBytes(path, bytes);
            KeepHistoryAfterWrite(path, bytes, automatic);

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
                diskStamp = DocumentFile.Stamp(path);
                // Typing that arrived while saving stays unsaved, because its revision is newer.
                savedRevision = pageRevision + revisionOffset;
                UpdateTitle();
                StartTimers();
            }
            if (!IsDirty)
            {
                recoveryTimer.Stop();
                RecoveryStore.Delete(recoveryId);
            }
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException or ArgumentException or NotSupportedException)
        {
            if (automatic || IsSelfTesting)
                Trace.TraceWarning("Save failed: {0}", error.Message);
            else
                MessageBox.Show(this, NativeCore.Tr("doc.saveFailed").Replace("%@", error.Message), "Jena Note",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
            return false;
        }
        finally
        {
            saving = false;
        }
    }

    bool ChangedOnDisk(string path)
    {
        var stamp = DocumentFile.Stamp(path);
        return stamp != null && stamp != diskStamp;
    }

    bool ConfirmOverwrite(string path)
    {
        if (IsSelfTesting) return OverwriteAnswerForTest;
        return MessageBox.Show(this, NativeCore.Tr("doc.changedOnDisk").Replace("%@", Path.GetFileName(path)), "Jena Note",
            MessageBoxButton.YesNo, MessageBoxImage.Warning) == MessageBoxResult.Yes;
    }

    /// <summary>The version about to be replaced goes into history first.</summary>
    void KeepHistoryBeforeWrite(string path, bool changedOnDisk)
    {
        try
        {
            if (File.Exists(path) && (changedOnDisk || !NativeCore.BackupHasSnapshots(path)))
                NativeCore.BackupRecord(path, File.ReadAllBytes(path));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            ReportBackupFailure(error);
        }
    }

    void KeepHistoryAfterWrite(string path, byte[] bytes, bool automatic)
    {
        try
        {
            NativeCore.BackupRecord(path, bytes, automatic);
            reportedBackupFailure = false;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            ReportBackupFailure(error);
        }
    }

    /// <summary>The document itself saved, so this warns once rather than on every autosave.</summary>
    void ReportBackupFailure(Exception error)
    {
        Trace.TraceWarning("Backup failed: {0}", error.Message);
        if (reportedBackupFailure || IsSelfTesting) return;
        reportedBackupFailure = true;
        MessageBox.Show(this, NativeCore.Tr("backup.failed"), "Jena Note", MessageBoxButton.OK, MessageBoxImage.Warning);
    }

    // MARK: - Settings

    void ApplySettings()
    {
        FillMenu();
        UpdateTitle();
        editor.ApplySettings();
        if (AutosaveEnabled)
        {
            // A new interval starts counting from now, and turning this on must catch up.
            autosaveTimer.Stop();
            StartTimers();
        }
        else
        {
            autosaveTimer.Stop();
        }
    }

    // MARK: - Autosave and recovery

    void StartTimers()
    {
        if (!IsDirty) return;
        if (!recoveryTimer.IsEnabled)
        {
            recoveryTimer.Interval = RecoveryDelay;
            recoveryTimer.Start();
        }
        if (AutosaveEnabled && filePath != null && !autosaveTimer.IsEnabled)
        {
            autosaveTimer.Interval = AutosaveDelay;
            autosaveTimer.Start();
        }
    }

    async Task AutosaveTickAsync()
    {
        autosaveTimer.Stop();
        if (IsDirty && filePath != null && AutosaveEnabled) await WriteAsync(filePath, automatic: true);
    }

    async Task RecoveryTickAsync()
    {
        recoveryTimer.Stop();
        if (!IsDirty || closeConfirmed) return;
        try
        {
            RecoveryStore.Save(recoveryId, filePath, plainText, await CurrentTextAsync());
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            Trace.TraceWarning("Recovery copy failed: {0}", error.Message);
        }
    }

    /// <summary>A clean document follows its file. A changed one is settled when it next saves.</summary>
    public void CheckDiskChange()
    {
        if (!editorStarted || filePath == null || IsDirty || saving || !ChangedOnDisk(filePath)) return;
        try
        {
            LoadIntoEditor(DocumentFile.Read(filePath));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or DocumentFile.NotUtf8Exception)
        {
            // A file still being written can fail here. The next activation tries again.
            Trace.TraceWarning("Reload failed: {0}", error.Message);
        }
    }

    // MARK: - History

    public async Task<string> CurrentTextAsync() => TextToSave(await editor.GetContentAsync(plainText ? "text" : "blocks"), plainText);

    public async Task CreateNamedVersionAsync(string name)
    {
        if (filePath == null) throw new InvalidOperationException(NativeCore.Tr("backup.saveFirst"));
        NativeCore.BackupRecord(filePath, new UTF8Encoding(false).GetBytes(await CurrentTextAsync()), name: name);
    }

    /// <summary>Current text goes into history first, so a restore can always be taken back.</summary>
    public async Task RestoreVersionAsync(string id)
    {
        if (filePath == null) throw new InvalidOperationException(NativeCore.Tr("backup.saveFirst"));
        var text = NativeCore.BackupText(filePath, id);
        var encoding = new UTF8Encoding(false);
        NativeCore.BackupRecord(filePath, encoding.GetBytes(await CurrentTextAsync()));
        NativeCore.BackupRecord(filePath, encoding.GetBytes(text), force: true);
        LoadIntoEditor(DocumentFile.Normalize(text), dirty: true);
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
            var settings = AppSettings.Current;
            var (data, skipped) = NativeCore.Export(content.GetProperty("blocks").GetRawText(), format, editor.DocumentFolder,
                settings.BodySize, settings.LetterSpacing);
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
        if (closeConfirmed) return;
        if (closeInProgress)
        {
            e.Cancel = true;
            return;
        }
        if (!IsDirty && !saving) return;

        // Closing waits for the answer and for the save, so it starts again afterwards.
        e.Cancel = true;
        closeInProgress = true;
        try
        {
            await FinishClosingAsync();
        }
        finally
        {
            closeInProgress = false;
        }
    }

    /// <summary>For the self test, which cannot answer the question below.</summary>
    public void DiscardAndClose()
    {
        closeConfirmed = true;
        Close();
    }

    async Task FinishClosingAsync()
    {
        // WPF refuses Close() while the Closing event is still running, so leave it first.
        await Dispatcher.Yield(DispatcherPriority.Background);
        while (saving) await Task.Delay(20);

        // A saved document with autosave on closes without asking, as on macOS.
        if (IsDirty && AutosaveEnabled && filePath != null) await WriteAsync(filePath, automatic: true);
        if (!IsDirty)
        {
            closeConfirmed = true;
            Close();
            return;
        }

        var name = filePath != null ? Path.GetFileName(filePath) : NativeCore.Tr("doc.untitled");
        var answer = IsSelfTesting ? CloseAnswerForTest : MessageBox.Show(this, NativeCore.Tr("doc.unsaved").Replace("%@", name), "Jena Note",
            MessageBoxButton.YesNoCancel, MessageBoxImage.Question);
        if (answer == MessageBoxResult.Cancel) return;
        if (answer == MessageBoxResult.Yes && !await SaveAsync(chooseLocation: false)) return;
        closeConfirmed = true;
        Close();
    }
}
