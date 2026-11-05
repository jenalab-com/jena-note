using System.IO;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
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
            if (ok) return;
            failures++;
            report.AppendLine($"FAIL  {name}{(detail.Length > 0 ? "\n      " + detail.Replace("\n", "\\n") : "")}");
        }

        var dictionaryFolder = Directory.CreateTempSubdirectory("jena-selftest-dictionary-").FullName;
        NativeCore.UseDictionaryFile(Path.Combine(dictionaryFolder, "dictionary.json"));
        EditorWindow.IsSelfTesting = true;
        NativeCore.UseBackupDirectory(Path.Combine(dictionaryFolder, "backups"));
        RecoveryStore.Folder = Path.Combine(dictionaryFolder, "recovery");

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

            var longDocument = results.GetProperty("longDocument");
            Check("a long document survives a round trip", longDocument.GetProperty("ok").GetBoolean());
            report.AppendLine($"long document: render {longDocument.GetProperty("renderMs").GetInt32()} ms, read {longDocument.GetProperty("readMs").GetInt32()} ms");

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
        check("recovered text opens as unsaved", restored.Title.StartsWith(dirtyMark) && (await restored.CurrentTextAsync()) == "복구할 글\n", restored.Title);
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
