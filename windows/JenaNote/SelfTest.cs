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
