using System.Diagnostics;
using System.IO;
using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace JenaNote;

/// <summary>The WebView2 editor page and the messages exchanged with it.</summary>
sealed class EditorView : WebView2
{
    const string AppHost = "app.jenanote.local";
    const string DocumentHost = "doc.jenanote.local";

    static readonly string[] ImageExtensions = { ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg" };
    static readonly string[] ToolbarKeys =
    {
        "toolbar.bold", "toolbar.italic", "toolbar.code", "toolbar.body", "toolbar.h1", "toolbar.h2", "toolbar.h3",
        "toolbar.ul", "toolbar.ol", "toolbar.quote", "doc.codeBlock", "toolbar.hr", "toolbar.link",
        "menu.format.textColor", "doc.linkPrompt", "doc.ok", "ai.work.cancel",
        "toolbar.find", "find.replacePlaceholder", "find.replace", "find.replaceAll",
        "reader.scroll", "reader.paged", "toolbar.appearance", "reader.fontSize", "reader.bookmark.toggle", "reader.bookmark.list",
        "reader.bookmark.empty", "reader.bookmark.untitled", "paperSize.title", "reader.width", "reader.widthMobile", "reader.widthBook",
        "reader.font", "reader.weight", "reader.weight.light", "reader.weight.regular", "reader.weight.bold", "reader.lineSpacing",
        "reader.lineTight", "reader.lineNormal", "reader.lineWide", "reader.letterSpacing", "toolbar.zoom",
        "source.title", "source.hint", "source.description", "source.copyAll",
        "ai.title", "ai.guide", "ai.edit", "ai.send", "ai.stop", "ai.waiting", "ai.selection", "ai.wholeEdit", "ai.wholeContext",
        "ai.cancelled", "ai.composer.placeholder", "ai.composer.keyboard", "ai.settings", "ai.model", "ai.modelHint",
        "ai.defaultModel", "ai.composer.customModel", "ai.composer.apply", "ai.accountUsage", "ai.conversationTokens",
        "ai.conversationTokensHint", "ai.refreshUsage", "ai.loadingUsage", "ai.metadataUnavailable", "ai.quotaUnavailable",
        "ai.quotaHint", "ai.geminiQuotaHint", "ai.editConflict", "ai.attachmentConflict", "ai.editTooLarge", "doc.aiApplied", "doc.untitled",
        "ai.index.sources", "ai.work.row.off", "ai.work.row.settingsButton", "ai.work.row.saveFirst", "ai.work.row.disabled",
        "ai.work.row.enableButton", "ai.work.row.corrupt", "ai.work.row.resetButton",
        "toolbar.lists", "toolbar.insert", "toolbar.more", "toolbar.textColor", "menu.format.body", "menu.format.h1", "menu.format.h2", "menu.format.h3",
        "menu.format.ul", "menu.format.ol", "menu.format.quote", "menu.format.code", "reader.fontDown", "reader.fontUp",
        "menu.format.punctuation.dialogue", "menu.format.punctuation.quotation", "menu.format.punctuation.thought",
        "punctuation.short.dialogue", "punctuation.short.quotation", "punctuation.short.thought",
        "proof.button", "proof.original", "proof.suggestion", "proof.apply", "proof.select", "proof.unchanged", "dictionary.add",
    };

    static Task<CoreWebView2Environment>? sharedEnvironment;

    readonly TaskCompletionSource pageReady = new();
    readonly Dictionary<int, TaskCompletionSource<JsonElement>> pendingContent = new();
    int nextRequest;
    AiChatHost? aiChat;

    public string? DocumentFolder { get; set; }

    /// <summary>The document's file, which decides which personal dictionary terms apply.</summary>
    public string? DocumentPath { get; set; }

    /// <summary>Raised with a word the author wants to allow.</summary>
    public event Action<string>? AddToDictionaryRequested;
    /// <summary>Raised with text to show the author.</summary>
    public event Action<string>? AlertRequested;

    /// <summary>Raised with the editor's revision whenever the author changes the document.</summary>
    public event Action<int>? Changed;
    /// <summary>Raised with the document's characters without and with spaces.</summary>
    public event Action<int, int>? CountsChanged;
    /// <summary>Raised with a command name from a keyboard shortcut inside the editor.</summary>
    public event Action<string>? CommandRequested;
    /// <summary>Raised with the marks that are on, in the order they were turned on.</summary>
    public event Action<string[]>? PunctuationChanged;
    /// <summary>Self test results as raw JSON.</summary>
    public event Action<JsonElement>? SelfTestFinished;

    public async Task InitializeAsync()
    {
        sharedEnvironment ??= CoreWebView2Environment.CreateAsync(userDataFolder:
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "JenaNote", "WebView2"));
        await EnsureCoreWebView2Async(await sharedEnvironment);

        var web = CoreWebView2;
        web.Settings.IsWebMessageEnabled = true;
        web.Settings.AreHostObjectsAllowed = false;
        web.Settings.AreDefaultScriptDialogsEnabled = false;
        web.Settings.IsStatusBarEnabled = false;
        web.Settings.AreBrowserAcceleratorKeysEnabled = false;
        web.Settings.IsZoomControlEnabled = false;
        web.Settings.IsGeneralAutofillEnabled = false;
        web.Settings.IsPasswordAutosaveEnabled = false;
#if !DEBUG
        web.Settings.AreDevToolsEnabled = false;
#endif

        web.SetVirtualHostNameToFolderMapping(AppHost, Path.Combine(AppContext.BaseDirectory, "editor"),
            CoreWebView2HostResourceAccessKind.DenyCors);
        web.AddWebResourceRequestedFilter($"https://{DocumentHost}/*", CoreWebView2WebResourceContext.Image);
        web.WebResourceRequested += ServeDocumentImage;

        // The page never leaves the editor. Dropped files and stray links must not replace it.
        web.NavigationStarting += (_, e) =>
        {
            if (!e.Uri.StartsWith($"https://{AppHost}/", StringComparison.Ordinal)) e.Cancel = true;
        };
        web.NewWindowRequested += (_, e) => e.Handled = true;
        web.WebMessageReceived += ReceiveMessage;

        web.Navigate($"https://{AppHost}/index.html");
        await pageReady.Task;

        ApplySettings();
    }

    /// <summary>Sends the current text sizes, colors and interface language to the page.</summary>
    public void ApplySettings()
    {
        if (CoreWebView2 == null) return;
        var settings = AppSettings.Current;
        CoreWebView2.Profile.PreferredColorScheme = settings.ColorMode switch
        {
            "light" => CoreWebView2PreferredColorScheme.Light,
            "dark" => CoreWebView2PreferredColorScheme.Dark,
            _ => CoreWebView2PreferredColorScheme.Auto,
        };
        Send(new { type = "strings", strings = ToolbarKeys.ToDictionary(key => key, NativeCore.Tr) });
        Send(new
        {
            type = "settings",
            bodySize = settings.BodySize,
            letterSpacing = settings.LetterSpacing,
            paper = settings.PaperColor,
            reading = new
            {
                mode = settings.ReadingMode,
                fontScale = settings.ReadingFontScale,
                font = settings.ReadingFont,
                weight = settings.ReadingWeight,
                lineSpacing = settings.ReadingLineSpacing,
                lineLength = settings.ReadingLineLength,
                pageWidth = settings.ReadingPageWidth,
                marginLeft = settings.ReadingMarginLeft,
                marginRight = settings.ReadingMarginRight,
                paper = settings.PaperSize,
            },
            ai = new { provider = settings.AiProvider, model = settings.AiModels.GetValueOrDefault(settings.AiProvider, "") },
            fonts = ReadingFaces.Available(),
            paperSizes = ReadingFaces.PaperSizes(),
        });
        SendPunctuationSettings();
    }

    public void SendPunctuationSettings()
    {
        if (CoreWebView2 == null) return;
        var settings = AppSettings.Current;
        Send(new
        {
            type = "punctuationSettings",
            styles = AppSettings.PunctuationKinds.ToDictionary(kind => kind, kind =>
            {
                var style = settings.PunctuationFor(kind);
                return new { opening = style.Opening, closing = style.Closing, leadingSpaces = style.LeadingSpaces, trigger = style.Trigger };
            }),
            triggers = settings.PunctuationTriggersEnabled,
            closesOnReturn = settings.PunctuationClosesOnReturn,
            shiftTarget = settings.PunctuationShiftTarget,
        });
    }

    /// <summary>
    /// Turns a mark on or off from the menu. `force` sends it to the document even when the page
    /// has a field focused, because the focus was outside the page.
    /// </summary>
    public void TogglePunctuation(string kind, bool force)
    {
        Focus();
        Send(new { type = "punctuation", kind, force });
    }

    void Send(object message) => CoreWebView2.PostWebMessageAsString(JsonSerializer.Serialize(message));

    /// <summary>For requests that finish after a wait, when the window may have closed meanwhile.</summary>
    public void Post(object message) => PostRaw(JsonSerializer.Serialize(message));

    public void PostRaw(string json)
    {
        if (CoreWebView2 == null) return;
        try
        {
            CoreWebView2.PostWebMessageAsString(json);
        }
        catch (Exception error) when (error is ObjectDisposedException or InvalidOperationException or System.Runtime.InteropServices.COMException)
        {
            Trace.TraceWarning("The page is gone: {0}", error.Message);
        }
    }

    public void ToggleAi()
    {
        Focus();
        Send(new { type = "aiToggle" });
    }

    public void CancelAi() => aiChat?.CancelAll();

    public void RefreshWorkStatus() => aiChat?.SendWorkStatus();

    public void LoadMarkdown(string markdown)
    {
        // The block list is already JSON, so it goes into the envelope as it is.
        CoreWebView2.PostWebMessageAsString($"{{\"type\":\"load\",\"blocks\":{NativeCore.MarkdownToJson(markdown)}}}");
    }

    public void LoadPlainText(string text) => Send(new { type = "load", plain = true, text });

    public void Run(string command)
    {
        Focus();
        Send(new { type = "run", name = command });
    }

    /// <summary>Undo, redo, cut, copy, paste or select all, performed inside the page.</summary>
    public void RunNative(string command)
    {
        Focus();
        Send(new { type = "native", name = command });
    }

    /// <summary>Where this document was being read, sent right after its text.</summary>
    public void SendReadingState()
    {
        var path = DocumentPath;
        Send(new
        {
            type = "readingState",
            path,
            progress = path != null ? ReadingStore.Progress(path) : null,
            bookmarks = path != null ? ReadingStore.Bookmarks(path) : null,
        });
    }

    /// <summary>Shows or updates the read-only view of what would be saved.</summary>
    public void ShowSource(string text)
    {
        Focus();
        Send(new { type = "source", text });
    }

    public void HideSource()
    {
        Focus();
        Send(new { type = "sourceHide" });
    }

    /// <summary>The document kept its text but has a new file.</summary>
    public void SendReadingPath() => Send(new { type = "readingPath", path = DocumentPath });

    /// <summary>"scroll", "paged", "fontUp", "fontDown", "appearance", "bookmarkToggle" or "bookmarkList".</summary>
    public void ReadingCommand(string name)
    {
        Focus();
        Send(new { type = "readingCommand", name });
    }

    /// <summary>"open", "replace", "next" or "previous".</summary>
    public void Find(string action)
    {
        Focus();
        Send(new { type = "find", action });
    }

    /// <summary>Goes to a match of the search that opened this document.</summary>
    public void JumpTo(string query, int ordinal) => Send(new { type = "jump", query, ordinal });

    public void RunSelfTestStep(string step) => Send(new { type = "selftestStep", step });

    public void StartSelfTest(string casesJson) =>
        CoreWebView2.PostWebMessageAsString($"{{\"type\":\"selftest\",\"cases\":{casesJson}}}");

    /// <summary>Reads the document as the editor holds it. `format` is "blocks" or "text".</summary>
    public Task<JsonElement> GetContentAsync(string format)
    {
        var id = ++nextRequest;
        var completion = new TaskCompletionSource<JsonElement>();
        pendingContent[id] = completion;
        Send(new { type = "getContent", id, format });
        return completion.Task;
    }

    void ReceiveMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        if (!e.Source.StartsWith($"https://{AppHost}/", StringComparison.Ordinal)) return;
        using var document = JsonDocument.Parse(e.TryGetWebMessageAsString());
        var message = document.RootElement.Clone();
        switch (message.GetProperty("type").GetString())
        {
            case "ready":
                pageReady.TrySetResult();
                break;
            case "changed":
                Changed?.Invoke(message.GetProperty("revision").GetInt32());
                break;
            case "command":
                CommandRequested?.Invoke(message.GetProperty("name").GetString() ?? "");
                break;
            case "content":
                var id = message.GetProperty("id").GetInt32();
                if (pendingContent.Remove(id, out var completion)) completion.SetResult(message);
                break;
            case "proofread":
                _ = ProofreadAsync(message);
                break;
            case "proofreadSelection":
                _ = ProofreadSelectionAsync(message);
                break;
            case "addToDictionary":
                AddToDictionaryRequested?.Invoke(message.GetProperty("term").GetString() ?? "");
                break;
            case "alert":
                AlertRequested?.Invoke(message.GetProperty("text").GetString() ?? "");
                break;
            case "openLink":
                OpenExternally(message.GetProperty("url").GetString());
                break;
            case "selftest":
                SelfTestFinished?.Invoke(message);
                break;
            case "aiSend":
            case "aiCancel":
            case "aiMetadata":
            case "aiWorkRefresh":
                aiChat ??= new AiChatHost(this);
                aiChat.Handle(message.GetProperty("type").GetString()!, message);
                break;
            case "readingChange":
                AppSettings.ApplyFromPage(message.GetProperty("values"));
                break;
            case "progress":
                ReadingStore.SetProgress(message.GetProperty("path").GetString()!, JsonNode.Parse(message.GetProperty("anchor").GetRawText()));
                break;
            case "bookmarks":
                ReadingStore.SetBookmarks(message.GetProperty("path").GetString()!, JsonNode.Parse(message.GetProperty("list").GetRawText())!.AsArray());
                break;
            case "punctuationState":
                PunctuationChanged?.Invoke(message.GetProperty("active").EnumerateArray().Select(item => item.GetString() ?? "").ToArray());
                break;
            case "counts":
                CountsChanged?.Invoke(message.GetProperty("noSpaces").GetInt32(), message.GetProperty("withSpaces").GetInt32());
                break;
        }
    }

    /// <summary>Tells the page that dictionary terms changed, so it should check again.</summary>
    public void DictionaryChanged() => Send(new { type = "dictionaryChanged" });

    /// <summary>
    /// Live checking is a quiet aid. Failures are logged and never interrupt the author.
    /// </summary>
    async Task ProofreadAsync(JsonElement message)
    {
        try
        {
            var results = await NativeCore.Proofread(message.GetProperty("items").GetRawText(), NativeCore.DictionaryTerms(DocumentPath));
            var requestId = message.GetProperty("requestId").GetInt32();
            CoreWebView2.PostWebMessageAsString($"{{\"type\":\"proofreadResult\",\"requestId\":{requestId},\"results\":{results}}}");
        }
        catch (InvalidOperationException error)
        {
            Trace.TraceWarning("Proofreading failed: {0}", error.Message);
        }
    }

    async Task ProofreadSelectionAsync(JsonElement message)
    {
        var id = message.GetProperty("id").GetInt32();
        try
        {
            var corrected = await NativeCore.ProofreadSelection(message.GetProperty("text").GetString() ?? "", NativeCore.DictionaryTerms(DocumentPath));
            Send(new { type = "proofreadSelectionResult", id, corrected });
        }
        catch (InvalidOperationException error)
        {
            Send(new { type = "proofreadSelectionResult", id, error = error.Message });
        }
    }

    /// <summary>Only web and mail links leave the app. File and script addresses in a document do not.</summary>
    public static bool IsExternallyOpenable(string? url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri)
        && (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps || uri.Scheme == Uri.UriSchemeMailto);

    static void OpenExternally(string? url)
    {
        if (IsExternallyOpenable(url)) Process.Start(new ProcessStartInfo(url!) { UseShellExecute = true });
    }

    /// <summary>
    /// Serves images a document refers to. Relative paths may climb out of the document's folder,
    /// as on macOS, but only image files can be read this way.
    /// </summary>
    void ServeDocumentImage(object? sender, CoreWebView2WebResourceRequestedEventArgs e)
    {
        var response = ImageResponse(e.Request.Uri);
        if (response != null) e.Response = response;
    }

    CoreWebView2WebResourceResponse? ImageResponse(string address)
    {
        var environment = CoreWebView2.Environment;
        CoreWebView2WebResourceResponse NotFound() =>
            environment.CreateWebResourceResponse(null, (int)HttpStatusCode.NotFound, "Not Found", "");

        if (DocumentFolder == null) return NotFound();
        var query = new Uri(address).Query;
        if (!query.StartsWith("?p=", StringComparison.Ordinal)) return NotFound();
        try
        {
            var path = Path.GetFullPath(Path.Combine(DocumentFolder, Uri.UnescapeDataString(query[3..])));
            var extension = Path.GetExtension(path).ToLowerInvariant();
            if (!ImageExtensions.Contains(extension) || !File.Exists(path)) return NotFound();
            var contentType = extension == ".svg" ? "image/svg+xml" : "image/" + extension[1..].Replace("jpg", "jpeg");
            return environment.CreateWebResourceResponse(new MemoryStream(File.ReadAllBytes(path)),
                (int)HttpStatusCode.OK, "OK", $"Content-Type: {contentType}");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return NotFound();
        }
    }
}
