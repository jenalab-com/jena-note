using System.IO;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;

namespace JenaNote;

/// <summary>
/// `JenaNote.exe --selftest corpus.json report.txt`. Runs the file handling and the real editor
/// page through the real DLL. The exit code is the number of failures.
/// </summary>
static class SelfTest
{
    public static async void Run(Application app, string corpusPath, string reportPath)
    {
        var report = new StringBuilder();
        var failures = 0;
        var total = 0;
        void Check(string name, bool ok, string detail = "")
        {
            total++;
            if (name.StartsWith("reading: long manuscript", StringComparison.Ordinal)) report.AppendLine(name);
            if (ok) return;
            failures++;
            report.AppendLine($"FAIL  {name}{(detail.Length > 0 ? "\n      " + detail.Replace("\n", "\\n") : "")}");
        }

        var dictionaryFolder = Directory.CreateTempSubdirectory("jena-selftest-dictionary-").FullName;
        NativeCore.UseDictionaryFile(Path.Combine(dictionaryFolder, "dictionary.json"));
        EditorWindow.IsSelfTesting = true;
        NativeCore.UseBackupDirectory(Path.Combine(dictionaryFolder, "backups"));
        RecoveryStore.Folder = Path.Combine(dictionaryFolder, "recovery");
        AppSettings.Folder = dictionaryFolder;
        AppSettings.Load();
        var recycled = new List<string>();
        SidebarFiles.DeleteForTest = path =>
        {
            recycled.Add(path);
            if (Directory.Exists(path)) Directory.Delete(path, recursive: true);
            else File.Delete(path);
        };

        try
        {
            var fileChecks = RunFileChecks(Check);
            var window = new EditorWindow();
            window.Show();
            while (!window.IsLoaded) await Task.Delay(20);
            await window.WhenReady();

            using var corpus = JsonDocument.Parse(File.ReadAllText(corpusPath));
            var cases = corpus.RootElement.EnumerateArray().Select(item => new
            {
                name = item.GetProperty("name").GetString()!,
                input = item.GetProperty("input").GetString()!,
                expected = item.GetProperty("expected").GetString()!,
            }).ToList();

            var payload = "[" + string.Join(",", cases.Select(item =>
                $"{{\"name\":{JsonSerializer.Serialize(item.name)},\"blocks\":{NativeCore.MarkdownToJson(item.input)}}}")) + "]";

            var finished = new TaskCompletionSource<JsonElement>();
            window.Editor.SelfTestFinished += result => finished.TrySetResult(result);
            window.Editor.StartSelfTest(payload);
            var results = await finished.Task.WaitAsync(TimeSpan.FromSeconds(120));

            var expected = cases.ToDictionary(item => item.name, item => item.expected);
            var roundTrips = 0;
            foreach (var result in results.GetProperty("roundTrips").EnumerateArray())
            {
                var name = result.GetProperty("name").GetString()!;
                var actual = NativeCore.JsonToMarkdown(result.GetProperty("blocks").GetRawText());
                Check($"round trip: {name}", actual == expected[name], $"expected {expected[name]}\n      actual   {actual}");
                roundTrips++;
            }

            var interactions = 0;
            foreach (var result in results.GetProperty("interactions").EnumerateArray())
            {
                var name = result.GetProperty("name").GetString()!;
                var want = result.GetProperty("expected").GetString()!;
                if (result.TryGetProperty("error", out var error))
                {
                    Check($"interaction: {name}", false, error.GetString() ?? "");
                }
                else
                {
                    var actual = NativeCore.JsonToMarkdown(result.GetProperty("blocks").GetRawText());
                    Check($"interaction: {name}", actual == want, $"expected {want}\n      actual   {actual}");
                }
                interactions++;
            }

            await RunProofreadingChecks(window, Check);
            await RunExportChecks(window, Check);
            await RunPersistenceChecks(window, Check);
            await RunSettingsChecks(window, Check);
            await RunClosingChecks(Check);
            await RunSidebarChecks(window, recycled, Check);
            await RunReadingChecks(window, Check);
            await RunSourceChecks(window, Check);

            var longDocument = results.GetProperty("longDocument");
            Check("a long document survives a round trip", longDocument.GetProperty("ok").GetBoolean());
            report.AppendLine($"long document: render {longDocument.GetProperty("renderMs").GetInt32()} ms, read {longDocument.GetProperty("readMs").GetInt32()} ms");
            report.AppendLine($"long document: find {longDocument.GetProperty("findTotal").GetInt32()} matches in {longDocument.GetProperty("findMs").GetInt32()} ms, replace {longDocument.GetProperty("replaceTotal").GetInt32()} in {longDocument.GetProperty("replaceMs").GetInt32()} ms");

            // Saving through the window, with the page as the source of the text.
            var folder = Directory.CreateTempSubdirectory("jena-selftest-").FullName;
            var saved = EditorWindow.Open(WriteFixture(folder, "doc.md", "# 제목\r\n\r\n본문 **굵게**\r\n"), window);
            Check("open reuses a pristine window", saved == window);
            await Task.Delay(200);
            Check("opening leaves the document clean", !window.Title.StartsWith('\u25CF'), window.Title);
            var ok = await window.SaveAsync(chooseLocation: false);
            Check("save succeeds", ok);
            Check("save writes UTF-8 with LF", File.ReadAllText(Path.Combine(folder, "doc.md")) == "# 제목\n\n본문 **굵게**\n",
                File.ReadAllText(Path.Combine(folder, "doc.md")));

            var plain = EditorWindow.Open(WriteFixture(folder, "note.txt", "**그대로**\n\n# 글\n"), window);
            await Task.Delay(200);
            Check("plain text save keeps marks as characters", await window.SaveAsync(chooseLocation: false)
                && File.ReadAllText(Path.Combine(folder, "note.txt")) == "**그대로**\n\n# 글\n",
                File.ReadAllText(Path.Combine(folder, "note.txt")));
            Directory.Delete(folder, recursive: true);

            report.Insert(0, $"file checks {fileChecks}, round trips {roundTrips}, interactions {interactions}, all checks {total}, failures {failures}\n");
            window.Close();
        }
        catch (Exception error)
        {
            failures++;
            report.AppendLine($"FAIL  self test stopped: {error}");
        }

        Directory.Delete(dictionaryFolder, recursive: true);
        File.WriteAllText(reportPath, report.ToString(), Encoding.UTF8);
        app.Shutdown(failures);
    }

    /// <summary>Runs one step of proof-selftest in the page and returns its result.</summary>
    static async Task<JsonElement> ProofStep(EditorWindow window, string step)
    {
        var finished = new TaskCompletionSource<JsonElement>();
        Action<JsonElement> handler = finished.SetResult;
        window.Editor.SelfTestFinished += handler;
        window.Editor.RunSelfTestStep(step);
        try { return await finished.Task.WaitAsync(TimeSpan.FromSeconds(60)); }
        finally { window.Editor.SelfTestFinished -= handler; }
    }

    static async Task RunProofreadingChecks(EditorWindow window, Action<string, bool, string> check)
    {
        void Report(JsonElement steps)
        {
            foreach (var step in steps.GetProperty("checks").EnumerateArray())
            {
                check("proofreading: " + step.GetProperty("name").GetString(), step.GetProperty("ok").GetBoolean(),
                    step.TryGetProperty("detail", out var detail) ? detail.ToString() : "");
            }
        }

        Report(await ProofStep(window, "marks"));

        // A word in the dictionary stops being marked, without running the engine again.
        NativeCore.DictionaryAdd("오랫만에", null, false);
        window.Editor.DictionaryChanged();
        Report(await ProofStep(window, "afterDictionary"));

        using (var list = JsonDocument.Parse(NativeCore.DictionaryList(null)))
        {
            var ids = list.RootElement.GetProperty("entries").EnumerateArray().Select(entry => entry.GetProperty("id").GetString()!).ToList();
            check("dictionary lists what was added", ids.Count == 1, ids.Count.ToString());
            check("dictionary terms are active", NativeCore.DictionaryTerms(null).Contains("오랫만에"), NativeCore.DictionaryTerms(null));
            NativeCore.DictionaryRemove(ids);
            check("dictionary removes", !NativeCore.DictionaryTerms(null).Contains("오랫만에"), NativeCore.DictionaryTerms(null));
        }
        window.Editor.DictionaryChanged();
        Report(await ProofStep(window, "afterRemoval"));
        Report(await ProofStep(window, "selection"));
    }

    static async Task<bool> Eventually(Func<bool> condition, int milliseconds = 4000)
    {
        for (var waited = 0; waited < milliseconds; waited += 25)
        {
            if (condition()) return true;
            await Task.Delay(25);
        }
        return condition();
    }

    static async Task RunPersistenceChecks(EditorWindow window, Action<string, bool, string> check)
    {
        var folder = Directory.CreateTempSubdirectory("jena-selftest-persist-").FullName;
        EditorWindow.AutosaveDelay = TimeSpan.FromMilliseconds(100);
        EditorWindow.RecoveryDelay = TimeSpan.FromMilliseconds(100);
        const string dirtyMark = "\u25CF";
        string Read(string path) => File.ReadAllText(path);
        int Versions(string path)
        {
            using var list = JsonDocument.Parse(NativeCore.BackupList(path));
            return list.RootElement.GetArrayLength();
        }

        // Autosave writes in place and keeps the earlier text in history.
        var doc = WriteFixture(folder, "원고.md", "처음\n");
        EditorWindow.Open(doc, window);
        await Task.Delay(150);
        await ProofStep(window, "typeAtStart");
        check("autosave writes the file", await Eventually(() => Read(doc).StartsWith("쓴글처음")), Read(doc));
        check("autosave clears the mark", await Eventually(() => !window.Title.StartsWith(dirtyMark)), window.Title);
        check("first save keeps the original in history", Versions(doc) >= 1, Versions(doc).ToString());
        var first = NativeCore.BackupList(doc);
        check("history holds the original text", first.Contains("id") && HistoryContains(doc, "처음\n"), first);
        check("a clean document leaves no recovery copy", await Eventually(() => !Directory.Exists(RecoveryStore.Folder) || Directory.GetFiles(RecoveryStore.Folder).Length == 0), "");

        // A file another program changed is never overwritten without asking.
        await Task.Delay(1100); // Keeps file timestamps apart on coarse file systems.
        File.WriteAllText(doc, "밖에서 고침\n", new UTF8Encoding(false));
        window.CheckDiskChange();
        await Task.Delay(150);
        check("a clean document follows its file", (await window.CurrentTextAsync()) == "밖에서 고침\n", await window.CurrentTextAsync());

        await Task.Delay(1100);
        await ProofStep(window, "typeAtStart");
        File.WriteAllText(doc, "다시 밖에서\n", new UTF8Encoding(false));
        await Task.Delay(500);
        check("autosave leaves a changed file alone", Read(doc) == "다시 밖에서\n", Read(doc));
        check("the document stays marked unsaved", window.Title.StartsWith(dirtyMark), window.Title);
        window.CheckDiskChange();
        check("unsaved text is not replaced by the file", (await window.CurrentTextAsync()).StartsWith("쓴글"), await window.CurrentTextAsync());
        EditorWindow.OverwriteAnswerForTest = false;
        check("declining the question keeps the file", !await window.SaveAsync(false) && Read(doc) == "다시 밖에서\n", Read(doc));
        EditorWindow.OverwriteAnswerForTest = true;
        check("overwriting after asking works", await window.SaveAsync(false) && Read(doc).StartsWith("쓴글"), Read(doc));
        check("the overwritten text stays in history", HistoryContains(doc, "다시 밖에서\n"), NativeCore.BackupList(doc));

        // Named versions and restore.
        await window.CreateNamedVersionAsync("1차 완성");
        check("a named version is listed", NativeCore.BackupList(doc).Contains("1차 완성"), NativeCore.BackupList(doc));
        using (var list = JsonDocument.Parse(NativeCore.BackupList(doc)))
        {
            var original = list.RootElement.EnumerateArray().First(item => NativeCore.BackupText(doc, item.GetProperty("id").GetString()!) == "처음\n");
            var beforeRestore = await window.CurrentTextAsync();
            EditorWindow.AutosaveEnabled = false;
            await window.RestoreVersionAsync(original.GetProperty("id").GetString()!);
            await Task.Delay(150);
            check("restore shows the old text", (await window.CurrentTextAsync()) == "처음\n", await window.CurrentTextAsync());
            check("restore marks the document unsaved", window.Title.StartsWith(dirtyMark), window.Title);
            check("restore leaves the file until saved", Read(doc) == beforeRestore, Read(doc));
            check("restore keeps the replaced text", HistoryContains(doc, beforeRestore), "");
            EditorWindow.AutosaveEnabled = true;
            await window.SaveAsync(false);
        }

        // Comparison.
        using (var rows = JsonDocument.Parse(NativeCore.HistoryRows("가\n나", "가\n다")))
        {
            check("comparison aligns lines", rows.RootElement.GetArrayLength() == 2
                && rows.RootElement[1].GetProperty("kind").GetString() == "modified", rows.RootElement.ToString());
        }
        check("comparison refuses huge text", NativeCore.HistoryRows(new string('a', 1_100_000), new string('b', 1_100_000)) == "null", "");

        // Recovery copies of an untitled document.
        var untitled = new EditorWindow();
        untitled.Show();
        await Eventually(() => untitled.IsLoaded);
        await untitled.WhenReady();
        var prepared = new TaskCompletionSource();
        Action<JsonElement> onPrepared = _ => prepared.TrySetResult();
        untitled.Editor.SelfTestFinished += onPrepared;
        untitled.Editor.StartSelfTest("null");
        await prepared.Task.WaitAsync(TimeSpan.FromSeconds(20));
        untitled.Editor.SelfTestFinished -= onPrepared;
        await ProofStep(untitled, "typeAtStart");
        check("an untitled document gets a recovery copy", await Eventually(() => Directory.Exists(RecoveryStore.Folder) && Directory.GetFiles(RecoveryStore.Folder).Length == 1), "");
        check("a running window's copy is not an orphan", RecoveryStore.Orphans().Count == 0, RecoveryStore.Orphans().Count.ToString());
        untitled.DiscardAndClose();
        check("closing removes the copy", Directory.GetFiles(RecoveryStore.Folder).Length == 0, "");

        // What a crash leaves behind: a copy whose process is gone.
        Directory.CreateDirectory(RecoveryStore.Folder);
        var left = Path.Combine(RecoveryStore.Folder, "left.json");
        File.WriteAllText(left, JsonSerializer.Serialize(new { ProcessId = int.MaxValue - 1, Path = doc, Plain = false, Text = "복구할 글\n" }));
        var orphans = RecoveryStore.Orphans();
        check("a copy from a gone process is an orphan", orphans.Count == 1 && orphans[0].Text == "복구할 글\n" && orphans[0].Path == doc, orphans.Count.ToString());
        File.WriteAllText(Path.Combine(RecoveryStore.Folder, "bad.json"), "not json");
        check("an unreadable copy is skipped", RecoveryStore.Orphans().Count == 1, "");
        // Autosave would save the recovered text during this short check, which is what it should do.
        EditorWindow.AutosaveEnabled = false;
        var restored = new EditorWindow(doc, orphans[0].Text, orphans[0].Id);
        restored.Show();
        await Eventually(() => restored.IsLoaded);
        await restored.WhenReady();
        await Task.Delay(150);
        var recoveredText = await restored.CurrentTextAsync();
        check("recovered text opens as unsaved", restored.Title.StartsWith(dirtyMark) && recoveredText == "복구할 글\n", $"{restored.Title} [{recoveredText}]");
        EditorWindow.AutosaveEnabled = true;
        restored.DiscardAndClose();
        check("the copy goes away with its window", !File.Exists(left), "");
        File.Delete(Path.Combine(RecoveryStore.Folder, "bad.json"));

        EditorWindow.AutosaveDelay = TimeSpan.FromSeconds(60);
        EditorWindow.RecoveryDelay = TimeSpan.FromSeconds(5);
        EditorWindow.Open(WriteFixture(folder, "끝.md", "끝\n"), window);
        await Task.Delay(150);
        Directory.Delete(folder, recursive: true);
    }

    static async Task RunReadingChecks(EditorWindow window, Action<string, bool, string> check)
    {
        void Report(JsonElement steps, string prefix)
        {
            foreach (var step in steps.GetProperty("checks").EnumerateArray())
                check(prefix + step.GetProperty("name").GetString(), step.GetProperty("ok").GetBoolean(), step.GetProperty("detail").ToString());
        }
        EditorWindow.CloseAnswerForTest = MessageBoxResult.No;
        await window.OpenFromSidebarAsync(WriteFixture(Directory.CreateTempSubdirectory("jena-selftest-reading-").FullName, "읽기.md", "글\n"), null, 0);
        await Task.Delay(150);
        Report(await ProofStep(window, "readingFonts"), "reading: ");
        Report(await ProofStep(window, "readingMeasures"), "reading: ");
        Report(await ProofStep(window, "readingLayout"), "reading: ");
        Report(await ProofStep(window, "readingBookmarks"), "reading: ");

        // Settings from the page
        using (var document = JsonDocument.Parse("{\"mode\":\"paged\",\"fontScale\":1.27,\"weight\":\"bold\",\"paper\":\"a4\",\"lineSpacing\":9,\"marginLeft\":-5,\"unknown\":1}"))
            AppSettings.ApplyFromPage(document.RootElement);
        var current = AppSettings.Current;
        check("page changes reach the settings", current.ReadingMode == "paged" && current.ReadingWeight == "bold" && current.PaperSize == "a4", $"{current.ReadingMode} {current.ReadingWeight} {current.PaperSize}");
        check("page changes stay in range", current.ReadingFontScale == 1.3 && current.ReadingLineSpacing == 2.5 && current.ReadingMarginLeft == 0, $"{current.ReadingFontScale} {current.ReadingLineSpacing} {current.ReadingMarginLeft}");
        var settingsPath = Path.Combine(AppSettings.Folder, "settings.json");
        var stored = AppSettings.Read(settingsPath);
        check("reading settings are saved", stored.ReadingMode == "paged" && stored.PaperSize == "a4", stored.PaperSize);
        File.WriteAllText(settingsPath, "{\"ReadingMode\":\"sideways\",\"ReadingWeight\":\"x\",\"PaperSize\":\"z\",\"ReadingFontScale\":99,\"ReadingLineLength\":-1}");
        var odd = AppSettings.Read(settingsPath);
        check("odd reading settings fall back", odd.ReadingMode == "scroll" && odd.ReadingWeight == "regular" && odd.PaperSize == "automatic" && odd.ReadingFontScale == 2 && odd.ReadingLineLength == 35, "");
        AppSettings.Update(settings =>
        {
            settings.ReadingMode = "scroll";
            settings.ReadingWeight = "regular";
            settings.PaperSize = "automatic";
            settings.ReadingFontScale = 1.3;
            settings.ReadingLineSpacing = 1.5;
        });

        // Fonts offered are ones this machine can draw.
        var fonts = JsonSerializer.Serialize(ReadingFaces.Available());
        check("the automatic fonts are always offered", fonts.Contains("\"serif\"") && fonts.Contains("\"sans\"") && fonts.Contains("\"kopubBatang\""), fonts);
        check("every paper has a width", JsonSerializer.Serialize(ReadingFaces.PaperSizes()).Contains("595.27"), JsonSerializer.Serialize(ReadingFaces.PaperSizes()));
        check("the bundled font ships", File.Exists(Path.Combine(AppContext.BaseDirectory, "editor", "fonts", "KoPubBatang-Medium.ttf")), "");

        // Stored positions
        var folder = Directory.CreateTempSubdirectory("jena-selftest-readingstore-").FullName;
        var path = Path.Combine(folder, "문서.md");
        var anchor = JsonNode.Parse("{\"characterOffset\":12,\"contextSnippet\":\"글\",\"contentLength\":20,\"updatedAt\":5}");
        ReadingStore.SetProgress(path, anchor);
        ReadingStore.SetBookmarks(path, new JsonArray(anchor!.DeepClone()));
        ReadingStore.Unload();
        check("positions survive a restart", ReadingStore.Progress(path)?["characterOffset"]?.GetValue<int>() == 12 && ReadingStore.Bookmarks(path)?.Count == 1, "");
        check("positions ignore the case of a path", ReadingStore.Progress(path.ToUpperInvariant()) != null, "");
        var moved = Path.Combine(folder, "옮김.md");
        ReadingStore.Moved(path, moved);
        check("positions follow a rename", ReadingStore.Progress(moved) != null && ReadingStore.Bookmarks(moved) != null && ReadingStore.Progress(path) == null, "");
        ReadingStore.SetProgress(moved, null);
        ReadingStore.SetBookmarks(moved, new JsonArray());
        check("positions can be cleared", ReadingStore.Progress(moved) == null && ReadingStore.Bookmarks(moved) == null, "");
        File.WriteAllText(Path.Combine(AppSettings.Folder, "reading.json"), "not json");
        ReadingStore.Unload();
        check("a damaged position file is ignored", ReadingStore.Progress(moved) == null, "");
        Directory.Delete(folder, recursive: true);

        // A real save of a file with reading state does not change its text.
        var file = WriteFixture(Directory.CreateTempSubdirectory("jena-selftest-readingfile-").FullName, "저장.md", "**굵게** 글\n\n둘째\n");
        await window.OpenFromSidebarAsync(file, null, 0);
        await Task.Delay(200);
        AppSettings.Update(settings => { settings.ReadingWeight = "bold"; settings.ReadingMode = "paged"; settings.ReadingFont = "sans"; });
        await Task.Delay(150);
        await ProofStep(window, "typeAtStart");
        await Eventually(() => window.Title.StartsWith('\u25CF'));
        await window.SaveAsync(false);
        var written = File.ReadAllText(file);
        check("reading settings do not reach the file", written.Contains("**쓴글굵게** 글") && written.Contains("둘째"), written);
        AppSettings.Update(settings => { settings.ReadingWeight = "regular"; settings.ReadingMode = "scroll"; settings.ReadingFont = "serif"; });
    }

    static async Task RunSourceChecks(EditorWindow window, Action<string, bool, string> check)
    {
        void Report(JsonElement steps)
        {
            foreach (var step in steps.GetProperty("checks").EnumerateArray())
                check("source: " + step.GetProperty("name").GetString(), step.GetProperty("ok").GetBoolean(), step.GetProperty("detail").ToString());
        }
        var folder = Directory.CreateTempSubdirectory("jena-selftest-source-").FullName;
        var content = "**굵게** <b>꺾쇠</b>\n\n둘째\n";
        var file = WriteFixture(folder, "원문.md", content);
        EditorWindow.CloseAnswerForTest = MessageBoxResult.No;
        await window.OpenFromSidebarAsync(file, null, 0);
        await Task.Delay(200);

        // A change not saved yet shows up, as on macOS.
        await window.ToggleSourceAsync();
        await Task.Delay(150);
        Report(await ProofStep(window, "sourceShown"));
        check("source: viewing changes nothing", !window.Title.StartsWith('\u25CF') && File.ReadAllText(file) == content, window.Title);

        string? copied = null;
        EditorWindow.ClipboardForTest = text => copied = text;
        window.RunCommand("copySource");
        await Eventually(() => copied != null);
        EditorWindow.ClipboardForTest = null;
        check("source: copy all takes the saved form", copied == await window.CurrentTextAsync(), copied ?? "");

        await window.ToggleSourceAsync();
        await Task.Delay(150);
        Report(await ProofStep(window, "sourceHidden"));

        await ProofStep(window, "typeAtStart");
        await Eventually(() => window.Title.StartsWith('\u25CF'));
        await window.ToggleSourceAsync();
        await Task.Delay(150);
        var unsaved = await window.CurrentTextAsync();
        check("source: unsaved typing is in the document it shows", unsaved.Contains("쓴글"), unsaved);
        check("source: saving works from the source view", await window.SaveAsync(false) && File.ReadAllText(file) == unsaved, File.ReadAllText(file));

        // Opening another file while it shows keeps it showing, with the new text.
        var other = WriteFixture(folder, "다른.md", "다른 글\n");
        await window.OpenFromSidebarAsync(other, null, 0);
        await Task.Delay(200);
        check("source: another file keeps the view", window.IsShowingSource && window.DocumentPath == other, window.DocumentPath ?? "");
        // A search result goes to the document itself.
        await window.OpenFromSidebarAsync(file, "둘째", 0);
        await Task.Delay(200);
        check("source: a search result leaves the view", !window.IsShowingSource && window.DocumentPath == file, window.IsShowingSource.ToString());
        Directory.Delete(folder, recursive: true);
    }

    static async Task RunSidebarChecks(EditorWindow window, List<string> recycled, Action<string, bool, string> check)
    {
        void Report(JsonElement steps)
        {
            foreach (var step in steps.GetProperty("checks").EnumerateArray())
                check("find: " + step.GetProperty("name").GetString(), step.GetProperty("ok").GetBoolean(), step.GetProperty("detail").ToString());
        }
        Report(await ProofStep(window, "find"));

        // Names
        foreach (var bad in new[] { "", ".hidden", "a/b", @"a\b", "a:b", "a*", "a?", "a\"b", "a<b", "a>b", "a|b", "CON", "con.md", "LPT1.txt", "ends.", "ends ", "a\tb" })
            check($"the name is refused: [{bad}]", !SidebarFiles.IsValidName(bad), "");
        foreach (var good in new[] { "원고.md", "새 문서", "a.b.c", "CONSOLE", "1화" })
            check($"the name is allowed: {good}", SidebarFiles.IsValidName(good), "");

        var root = Directory.CreateTempSubdirectory("jena-selftest-sidebar-").FullName;
        Directory.CreateDirectory(Path.Combine(root, "집필"));
        Directory.CreateDirectory(Path.Combine(root, ".git"));
        Directory.CreateDirectory(Path.Combine(root, "가나다"));
        WriteFixture(root, "b.md", "오랫만에 왔다\n둘째 오랫만에\n");
        WriteFixture(root, "a.md", "**첫** 글\n");
        WriteFixture(root, "무시.txt", "x");
        WriteFixture(root, ".숨김.md", "x");
        File.SetLastWriteTimeUtc(Path.Combine(root, "a.md"), new DateTime(2020, 1, 1, 0, 0, 0, DateTimeKind.Utc));
        File.SetLastWriteTimeUtc(Path.Combine(root, "b.md"), new DateTime(2021, 1, 1, 0, 0, 0, DateTimeKind.Utc));

        string Names(string key, bool ascending) => string.Join(",", SidebarFiles.List(root, key, ascending).Select(entry => entry.Name));
        check("the tree lists folders first, without hidden files or other types", Names("name", true) == "가나다,집필,a.md,b.md", Names("name", true));
        check("the name order reverses", Names("name", false) == "집필,가나다,b.md,a.md", Names("name", false));
        check("the date order works", Names("date", false).EndsWith("b.md,a.md"), Names("date", false));

        // Files
        var made = SidebarFiles.CreateDocument(root, "새 글");
        check("a new document gets the extension", Path.GetFileName(made) == "새 글.md" && File.Exists(made), made);
        var refused = false;
        File.WriteAllText(made, "keep");
        try { SidebarFiles.CreateDocument(root, "새 글.md"); } catch (IOException) { refused = true; }
        check("creating never overwrites", refused && File.ReadAllText(made) == "keep", "");
        refused = false;
        try { SidebarFiles.CreateDocument(root, "../밖"); } catch (ArgumentException) { refused = true; }
        check("creating cannot leave the folder", refused && !File.Exists(Path.Combine(Path.GetDirectoryName(root)!, "밖.md")), "");
        refused = false;
        try { SidebarFiles.Rename(made, "a"); } catch (IOException) { refused = true; }
        check("renaming never overwrites", refused && File.Exists(made), "");
        var renamed = SidebarFiles.Rename(made, "고침");
        check("renaming keeps the extension", Path.GetFileName(renamed) == "고침.md" && File.ReadAllText(renamed) == "keep", renamed);
        var cased = SidebarFiles.Rename(renamed, "고침.MD");
        check("changing only the case works", File.Exists(cased), cased);
        check("paths follow a move", SidebarFiles.Relocated(Path.Combine(root, "집필", "a.md"), Path.Combine(root, "집필"), Path.Combine(root, "새")) == Path.Combine(root, "새", "a.md"), "");
        check("similar names are not inside", SidebarFiles.Relocated(Path.Combine(root, "집필2", "a.md"), Path.Combine(root, "집필"), Path.Combine(root, "새")) == null, "");
        File.Delete(cased);

        // The panel
        var sidebar = window.Sidebar;
        SidebarPanel.AddFolderPath(root);
        SidebarPanel.AddFolderPath(root + Path.DirectorySeparatorChar);
        check("a folder is added once", AppSettings.Current.SidebarFolders.Count == 1, AppSettings.Current.SidebarFolders.Count.ToString());
        check("the panel shows the folder", sidebar.RootCount == 1, sidebar.RootCount.ToString());

        // A change on disk reaches the panel by itself.
        var seen = new TaskCompletionSource();
        Action onChange = () => seen.TrySetResult();
        FolderWatch.Changed += onChange;
        WriteFixture(root, "c.md", "새로\n");
        await seen.Task.WaitAsync(TimeSpan.FromSeconds(5));
        FolderWatch.Changed -= onChange;
        check("the watcher reports new files", seen.Task.IsCompleted, "");
        File.Delete(Path.Combine(root, "c.md"));

        // Search across files, and jumping to a result.
        sidebar.SearchText = "오랫만";
        await sidebar.RunSearchAsync();
        check("search finds the file", sidebar.ResultFileCount == 1, sidebar.ResultFileCount.ToString());
        var resultPath = sidebar.ResultPaths.FirstOrDefault();
        check("search results are paths Windows can open", resultPath != null && File.Exists(resultPath) && Path.GetFullPath(resultPath) == Path.Combine(root, "b.md"), resultPath ?? "");
        sidebar.SearchText = "없는말xyz";
        await sidebar.RunSearchAsync();
        check("search with no match shows nothing", sidebar.ResultFileCount == 0, "");
        sidebar.SearchText = "";

        // The tree keeps its items through a reload, because a save in the folder causes one.
        AppSettings.Current.SidebarExpanded.Add(root);
        sidebar.Reload();
        var names = sidebar.VisibleNames.ToList();
        check("an open folder shows its files", names.Contains("a.md") && names.Contains("b.md") && !names.Contains("무시.txt"), string.Join(",", names));
        var kept = sidebar.ItemFor(Path.Combine(root, "b.md"));
        WriteFixture(root, "aa.md", "x\n");
        sidebar.Reload();
        check("a reload adds what is new", sidebar.VisibleNames.Contains("aa.md"), string.Join(",", sidebar.VisibleNames));
        check("a reload keeps what stayed", kept != null && ReferenceEquals(kept, sidebar.ItemFor(Path.Combine(root, "b.md"))), "");
        File.Delete(Path.Combine(root, "aa.md"));
        sidebar.Reload();
        check("a reload removes what is gone", !sidebar.VisibleNames.Contains("aa.md"), "");

        // The document the page tests left behind is in a folder that no longer exists.
        EditorWindow.CloseAnswerForTest = MessageBoxResult.No;
        var fileA = Path.Combine(root, "a.md");
        var fileB = Path.Combine(root, "b.md");
        await window.OpenFromSidebarAsync(fileA, null, 0);
        await Task.Delay(150);
        check("the sidebar opens a file in this window", window.DocumentPath == fileA && (await window.CurrentTextAsync()) == "**첫** 글\n", window.DocumentPath ?? "");

        // Changes follow the autosave rule when another file opens.
        await ProofStep(window, "typeAtStart");
        await Eventually(() => window.Title.StartsWith('\u25CF'));
        await window.OpenFromSidebarAsync(resultPath ?? fileB, "오랫만", 1);
        await Task.Delay(150);
        check("opening another file saves the changes", File.ReadAllText(fileA).Contains("쓴글"), File.ReadAllText(fileA));
        check("the other file opens", window.DocumentPath == fileB, window.DocumentPath ?? "");
        Report(await ProofStep(window, "jumpSecond"));

        // Cancelling keeps the document.
        EditorWindow.AutosaveEnabled = false;
        EditorWindow.CloseAnswerForTest = MessageBoxResult.Cancel;
        await ProofStep(window, "typeAtStart");
        await Eventually(() => window.Title.StartsWith('\u25CF'));
        await window.OpenFromSidebarAsync(fileA, null, 0);
        check("cancelling keeps the document open", window.DocumentPath == fileB, window.DocumentPath ?? "");
        EditorWindow.CloseAnswerForTest = MessageBoxResult.No;
        await window.OpenFromSidebarAsync(fileA, null, 0);
        await Task.Delay(150);
        check("declining discards and moves on", window.DocumentPath == fileA && !File.ReadAllText(fileB).StartsWith("쓴글"), File.ReadAllText(fileB));
        EditorWindow.AutosaveEnabled = true;

        // An open document follows a rename of its folder or file.
        var folder = Path.Combine(root, "집필");
        var inFolder = WriteFixture(folder, "편.md", "편\n");
        await window.OpenFromSidebarAsync(inFolder, null, 0);
        await Task.Delay(150);
        await window.CreateNamedVersionAsync("이름 전");
        var moved = SidebarFiles.Rename(folder, "원고");
        EditorWindow.DocumentsMoved(folder, moved);
        SidebarPanel.FolderMoved(folder, moved);
        check("history follows the rename", NativeCore.BackupHasSnapshots(Path.Combine(moved, "편.md")), "");
        check("an open document follows its folder", window.DocumentPath == Path.Combine(moved, "편.md"), window.DocumentPath ?? "");
        await ProofStep(window, "typeAtStart");
        await Eventually(() => window.Title.StartsWith('\u25CF'));
        check("saving after a move writes the new place", await window.SaveAsync(false) && File.ReadAllText(Path.Combine(moved, "편.md")).StartsWith("쓴글") && !Directory.Exists(folder), "");

        // Deleting what is open leaves an empty document, not a window saving into the deleted path.
        check("documents are settled before a delete", await EditorWindow.SaveDocumentsInsideAsync(moved), "");
        SidebarFiles.MoveToRecycleBin(moved);
        EditorWindow.DocumentsDeleted(moved);
        check("the document is gone from the window", window.DocumentPath == null, window.DocumentPath ?? "");
        check("delete goes through the recycle path", recycled.Contains(moved) && !Directory.Exists(moved), "");

        AppSettings.Update(settings => settings.SidebarFolders.Clear());
        FolderWatch.Follow(AppSettings.Current.SidebarFolders);
        await Task.Delay(100);
        Directory.Delete(root, recursive: true);
    }

    /// <summary>Every way a window with changes can close. The window must really go away.</summary>
    static async Task RunClosingChecks(Action<string, bool, string> check)
    {
        var folder = Directory.CreateTempSubdirectory("jena-selftest-closing-").FullName;

        static async Task<EditorWindow> Typed(string? path, string? text)
        {
            var window = new EditorWindow(path, text);
            window.Show();
            await Eventually(() => window.IsLoaded);
            await window.WhenReady();
            var prepared = new TaskCompletionSource();
            Action<JsonElement> onPrepared = _ => prepared.TrySetResult();
            window.Editor.SelfTestFinished += onPrepared;
            window.Editor.StartSelfTest("null");
            await prepared.Task.WaitAsync(TimeSpan.FromSeconds(20));
            window.Editor.SelfTestFinished -= onPrepared;
            await ProofStep(window, "typeAtStart");
            await Eventually(() => window.Title.StartsWith('\u25CF'));
            return window;
        }

        static async Task<bool> ClosesAfterClose(EditorWindow window)
        {
            var closed = false;
            window.Closed += (_, _) => closed = true;
            window.Close();
            await Eventually(() => closed, 5000);
            if (!closed) window.DiscardAndClose();
            return closed;
        }

        var saved = WriteFixture(folder, "저장.md", "글\n");
        var autosaved = await Typed(saved, "글\n");
        check("closing saves a saved document and closes", await ClosesAfterClose(autosaved), "");
        check("closing wrote the changes", File.ReadAllText(saved).StartsWith("쓴글"), File.ReadAllText(saved));

        EditorWindow.CloseAnswerForTest = MessageBoxResult.No;
        check("declining to save closes", await ClosesAfterClose(await Typed(null, "")), "");

        var declined = WriteFixture(folder, "끄기.md", "글\n");
        EditorWindow.AutosaveEnabled = false;
        check("with autosave off, declining closes", await ClosesAfterClose(await Typed(declined, "글\n")), "");
        check("declining leaves the file", File.ReadAllText(declined) == "글\n", File.ReadAllText(declined));
        EditorWindow.AutosaveEnabled = true;

        EditorWindow.CloseAnswerForTest = MessageBoxResult.Cancel;
        var kept = await Typed(null, "");
        kept.Close();
        await Task.Delay(300);
        check("cancelling keeps the window", kept.IsVisible, "");
        check("cancelling keeps the text", (await kept.CurrentTextAsync()).StartsWith("쓴글"), "");
        kept.DiscardAndClose();

        Directory.Delete(folder, recursive: true);
    }

    static async Task RunSettingsChecks(EditorWindow window, Action<string, bool, string> check)
    {
        var folder = Directory.CreateTempSubdirectory("jena-selftest-settings-").FullName;
        void Report(JsonElement steps)
        {
            foreach (var step in steps.GetProperty("checks").EnumerateArray())
                check("settings: " + step.GetProperty("name").GetString(), step.GetProperty("ok").GetBoolean(), step.GetProperty("detail").ToString());
        }

        // Stored values stay within what the app can use.
        var path = Path.Combine(folder, "settings.json");
        File.WriteAllText(path, "not json");
        check("a damaged settings file gives defaults", AppSettings.Read(path).AutosaveSeconds == 60, "");
        File.WriteAllText(path, "{\"Language\":\"xx\",\"AutosaveSeconds\":7,\"ColorMode\":\"neon\",\"PaperColor\":\"red\",\"BodySize\":999,\"LetterSpacing\":-3.6}");
        var odd = AppSettings.Read(path);
        check("odd stored values are corrected", odd.Language == "ko" && odd.AutosaveSeconds == 60 && odd.ColorMode == "system"
            && odd.PaperColor == null && odd.BodySize == 30 && odd.LetterSpacing == -4,
            $"{odd.Language} {odd.AutosaveSeconds} {odd.ColorMode} {odd.PaperColor} {odd.BodySize} {odd.LetterSpacing}");
        check("the stepper reads numbers", SettingsWindow.ParseStep(" 12.5 ", 15, 8, 30) == 12.5, "");
        check("the stepper keeps its range", SettingsWindow.ParseStep("99", 15, 8, 30) == 30, "");
        check("the stepper ignores other text", SettingsWindow.ParseStep("abc", 15, 8, 30) == 15 && SettingsWindow.ParseStep("NaN", 15, 8, 30) == 15, "");

        // Text sizes reach the open document at once.
        AppSettings.Update(settings =>
        {
            settings.BodySize = 11;
            settings.LetterSpacing = 10;
            settings.PaperColor = "#102030";
        });
        await Task.Delay(100);
        Report(await ProofStep(window, "styleApplied"));

        // ...and the exported file.
        var docx = Path.Combine(folder, "a.docx");
        var hwpx = Path.Combine(folder, "a.hwpx");
        var document = WriteFixture(folder, "a.md", "본문\n");
        EditorWindow.Open(document, window);
        await Task.Delay(150);
        await window.ExportAsync("docx", docx);
        await window.ExportAsync("hwpx", hwpx);
        static string Entry(string file, string name)
        {
            using var zip = ZipFile.OpenRead(file);
            using var reader = new StreamReader(zip.GetEntry(name)!.Open(), Encoding.UTF8);
            return reader.ReadToEnd();
        }
        var word = Entry(docx, "word/document.xml");
        check("docx uses the body size", word.Contains("w:sz w:val=\"22\""), word.Length.ToString());
        check("docx uses the letter spacing", word.Contains("w:spacing w:val=\"22\""), word.Length.ToString());
        var hangul = Entry(hwpx, "Contents/header.xml");
        check("hwpx uses the body size", hangul.Contains("height=\"1100\""), hangul.Length.ToString());

        // Autosave follows the setting without reopening anything.
        AppSettings.Update(settings =>
        {
            settings.AutosaveEnabled = false;
            settings.AutosaveSeconds = 30;
        });
        check("autosave off reaches the windows", !EditorWindow.AutosaveEnabled && EditorWindow.AutosaveDelay == TimeSpan.FromSeconds(30), "");
        var settingsFile = AppSettings.Read(Path.Combine(AppSettings.Folder, "settings.json"));
        check("changes are saved", !settingsFile.AutosaveEnabled && settingsFile.AutosaveSeconds == 30 && settingsFile.BodySize == 11, "");

        // Language follows at once, in the menu and the page.
        AppSettings.Update(settings => settings.Language = "en");
        check("language reaches the translations", NativeCore.Tr("menu.file") == "File", NativeCore.Tr("menu.file"));
        check("language reaches the menu", window.FirstMenuHeader == "File", window.FirstMenuHeader);
        await Task.Delay(100);
        Report(await ProofStep(window, "toolbarEnglish"));
        AppSettings.Update(settings => settings.Language = "ko");
        check("language returns", window.FirstMenuHeader == NativeCore.Tr("menu.file") && NativeCore.Tr("menu.file") != "File", window.FirstMenuHeader);

        // Dark mode reaches the page.
        AppSettings.Update(settings => settings.ColorMode = "dark");
        await Task.Delay(150);
        Report(await ProofStep(window, "dark"));
        AppSettings.Update(settings => settings.ColorMode = "light");
        await Task.Delay(150);
        Report(await ProofStep(window, "light"));

        // The window itself builds in every language without failing.
        var settingsWindow = SettingsWindow.Present(window);
        check("the settings window opens", settingsWindow.IsVisible, "");
        check("opening it twice reuses it", ReferenceEquals(SettingsWindow.Present(window), settingsWindow), "");
        settingsWindow.Close();

        AppSettings.Update(settings =>
        {
            settings.AutosaveEnabled = true;
            settings.AutosaveSeconds = 60;
            settings.BodySize = NativeCore.DefaultBodySize;
            settings.LetterSpacing = 0;
            settings.PaperColor = null;
            settings.ColorMode = "system";
        });
        EditorWindow.Open(WriteFixture(folder, "끝.md", "끝\n"), window);
        await Task.Delay(150);
        Directory.Delete(folder, recursive: true);
    }

    static bool HistoryContains(string path, string text)
    {
        using var list = JsonDocument.Parse(NativeCore.BackupList(path));
        return list.RootElement.EnumerateArray().Any(item => NativeCore.BackupText(path, item.GetProperty("id").GetString()!) == text);
    }

    static async Task RunExportChecks(EditorWindow window, Action<string, bool, string> check)
    {
        var folder = Directory.CreateTempSubdirectory("jena-selftest-export-").FullName;
        var image = Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAE0lEQVR4nGP4z8DwnwGM/zMwAAAf7gP9NRsAMwAAAABJRU5ErkJggg==");
        File.WriteAllBytes(Path.Combine(folder, "점.png"), image);
        var document = WriteFixture(folder, "문서.md", "# 제목\n\n본문 **굵게**\n\n![점](점.png)\n\n![없음](없음.png)\n");
        EditorWindow.Open(document, window);
        await Task.Delay(200);
        var titleBefore = window.Title;

        static string Entry(string path, string name)
        {
            using var zip = ZipFile.OpenRead(path);
            using var reader = new StreamReader(zip.GetEntry(name)!.Open(), Encoding.UTF8);
            return reader.ReadToEnd();
        }

        var docx = Path.Combine(folder, "결과.docx");
        var skipped = await window.ExportAsync("docx", docx);
        check("docx reports the one missing image", skipped == 1, skipped?.ToString() ?? "null");
        check("docx holds the text", File.Exists(docx) && Entry(docx, "word/document.xml").Contains("제목"), "");
        using (var zip = ZipFile.OpenRead(docx))
            check("docx embeds the image", zip.GetEntry("word/media/image1.png")?.Length == image.Length, "");

        var hwpx = Path.Combine(folder, "결과.hwpx");
        var skippedHwpx = await window.ExportAsync("hwpx", hwpx);
        check("hwpx counts images it leaves out", skippedHwpx == 1, skippedHwpx?.ToString() ?? "null");
        check("hwpx holds the text", File.Exists(hwpx) && Entry(hwpx, "Contents/section0.xml").Contains("제목"), "");

        check("export leaves the document alone", window.Title == titleBefore, window.Title);
        check("export leaves the source file alone", File.ReadAllText(document).StartsWith("# 제목"), "");
        check("export to an impossible path fails quietly", await window.ExportAsync("docx", Path.Combine(folder, "없는폴더", "a.docx")) == null, "");
        Directory.Delete(folder, recursive: true);
    }

    static string WriteFixture(string folder, string name, string text)
    {
        var path = Path.Combine(folder, name);
        File.WriteAllText(path, text, new UTF8Encoding(false));
        return path;
    }

    static int RunFileChecks(Action<string, bool, string> check)
    {
        var count = 0;
        void Check(string name, bool ok, string detail = "")
        {
            check(name, ok, detail);
            count++;
        }

        Check("decode strips a BOM", DocumentFile.Decode([0xEF, 0xBB, 0xBF, (byte)'a']) == "a");
        Check("decode normalizes line endings", DocumentFile.Decode(Encoding.UTF8.GetBytes("a\r\nb\rc\n")) == "a\nb\nc\n");
        var rejected = false;
        try { DocumentFile.Decode([0xFF, 0xFE, 0x41]); } catch (DocumentFile.NotUtf8Exception) { rejected = true; }
        Check("decode refuses data that is not UTF-8", rejected);
        Check("txt is plain text", DocumentFile.IsPlainText(@"C:\a\B.TXT") && !DocumentFile.IsPlainText(@"C:\a\b.md"));

        var folder = Directory.CreateTempSubdirectory("jena-selftest-").FullName;
        var path = Path.Combine(folder, "한글 이름.md");
        File.WriteAllText(path, "old");
        DocumentFile.Write(path, "새 내용\n");
        Check("write replaces the file without a BOM", File.ReadAllBytes(path).SequenceEqual(new UTF8Encoding(false).GetBytes("새 내용\n")));
        Check("write leaves no temporary file", Directory.GetFiles(folder).Length == 1);

        var failedWrite = false;
        File.WriteAllText(path, "keep");
        var locked = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None);
        try { DocumentFile.Write(path, "new"); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { failedWrite = true; }
        locked.Dispose();
        Check("a failed write keeps the original", failedWrite && File.ReadAllText(path) == "keep" && Directory.GetFiles(folder).Length == 1);
        Directory.Delete(folder, recursive: true);

        Check("web links can open", EditorView.IsExternallyOpenable("https://a.b") && EditorView.IsExternallyOpenable("mailto:a@b.c"));
        Check("file and script links cannot open", !EditorView.IsExternallyOpenable("file:///C:/x.exe")
            && !EditorView.IsExternallyOpenable("javascript:alert(1)") && !EditorView.IsExternallyOpenable(@"C:\x.exe")
            && !EditorView.IsExternallyOpenable(null));

        Check("native translation works", NativeCore.Tr("no.such.key") == "no.such.key" && NativeCore.Tr("menu.file") != "menu.file");
        Check("native round trip", NativeCore.JsonToMarkdown(NativeCore.MarkdownToJson("한글 😀 **b**")) == "한글 😀 **b**\n");
        var invalid = false;
        try { NativeCore.JsonToMarkdown("not json"); } catch (InvalidOperationException) { invalid = true; }
        Check("native errors become exceptions", invalid);
        return count;
    }
}
