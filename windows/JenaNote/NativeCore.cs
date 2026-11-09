using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace JenaNote;

/// <summary>The shared Swift library, through the C ABI in windows/bridge.</summary>
static class NativeCore
{
    const string Library = "JenaNoteBridge";

    [DllImport(Library)] static extern void jena_free(IntPtr pointer);
    [DllImport(Library)] static extern int jena_markdown_to_json(byte[] markdown, out IntPtr result, out IntPtr error);
    [DllImport(Library)] static extern int jena_json_to_markdown(byte[] json, out IntPtr result, out IntPtr error);
    [DllImport(Library)] static extern IntPtr jena_tr(byte[] key);
    [DllImport(Library)] static extern void jena_proofreading_configure(byte[] modelDirectory);
    [DllImport(Library)] static extern void jena_proofread(byte[] items, byte[] terms, ResultCallback callback, nuint context);
    [DllImport(Library)] static extern void jena_proofread_selection(byte[] text, byte[] terms, ResultCallback callback, nuint context);
    [DllImport(Library)] static extern int jena_work_status(byte[] path, out IntPtr result, out IntPtr error);
    [DllImport(Library)] static extern int jena_work_prepare(byte[] path, out IntPtr result, out IntPtr error);
    [DllImport(Library)] static extern int jena_work_session_open(byte[] request, out IntPtr handle, out IntPtr error);
    [DllImport(Library)] static extern int jena_work_session_start(IntPtr handle, out IntPtr result, out IntPtr error);
    [DllImport(Library)] static extern int jena_work_session_receive(IntPtr handle, byte[] answer, out IntPtr result, out IntPtr error);
    [DllImport(Library)] static extern int jena_work_session_prompt(IntPtr handle, byte[] request, out IntPtr result, out IntPtr error);
    [DllImport(Library)] static extern void jena_work_session_close(IntPtr handle);
    [DllImport(Library)] static extern int jena_work_window_open(byte[] path, out IntPtr result, out IntPtr error);
    [DllImport(Library)] static extern int jena_work_window_describe(byte[] root, byte[] config, byte[] current, out IntPtr result, out IntPtr error);
    [DllImport(Library)] static extern int jena_work_window_edit(byte[] root, byte[] config, int provisional, byte[] edit, out IntPtr result, out IntPtr error);
    [DllImport(Library)] static extern int jena_work_set_corrupt_aside(byte[] path, out IntPtr error);
    [DllImport(Library)] static extern IntPtr jena_ai_providers();
    [DllImport(Library)] static extern int jena_ai_command(byte[] provider, byte[] policy, byte[] promptFile, byte[]? model, out IntPtr result, out IntPtr error);
    [DllImport(Library)] static extern int jena_ai_answer(byte[] provider, int status, byte[] stdout, byte[] stderr, out IntPtr result, out IntPtr error);
    [DllImport(Library)] static extern int jena_ai_prompt(byte[] request, out IntPtr result, out IntPtr error);
    [DllImport(Library)] static extern int jena_ai_parse_edit(byte[] answer, out IntPtr result, out IntPtr error);
    [DllImport(Library)] static extern IntPtr jena_ai_metadata_arguments(byte[] provider);
    [DllImport(Library)] static extern IntPtr jena_ai_metadata_open(byte[] provider);
    [DllImport(Library)] static extern IntPtr jena_ai_metadata_initial(IntPtr handle);
    [DllImport(Library)] static extern IntPtr jena_ai_metadata_receive(IntPtr handle, byte[] line, out int complete);
    [DllImport(Library)] static extern IntPtr jena_ai_metadata_result(IntPtr handle);
    [DllImport(Library)] static extern void jena_ai_metadata_close(IntPtr handle);
    [DllImport(Library)] static extern IntPtr jena_ai_metadata_plain(byte[] provider, byte[] output);
    [DllImport(Library)] static extern void jena_search_files(byte[] query, byte[] folders, ResultCallback callback, nuint context);
    [DllImport(Library)] static extern void jena_dictionary_use_file(byte[] path);
    [DllImport(Library)] static extern int jena_dictionary_terms(byte[]? documentPath, out IntPtr result, out IntPtr error);
    [DllImport(Library)] static extern int jena_dictionary_list(byte[]? documentPath, out IntPtr result, out IntPtr error);
    [DllImport(Library)] static extern int jena_dictionary_add(byte[] term, byte[]? documentPath, int useCurrentWork, out IntPtr error);
    [DllImport(Library)] static extern int jena_dictionary_remove(byte[] ids, out IntPtr error);
    [DllImport(Library)] static extern int jena_export(byte[] blocks, byte[] format, byte[]? baseFolder, double bodySize, double letterSpacing,
        out IntPtr data, out nint length, out int skipped, out IntPtr error);
    [DllImport(Library)] static extern void jena_free_bytes(IntPtr pointer);
    [DllImport(Library)] static extern double jena_default_body_size();
    [DllImport(Library)] static extern IntPtr jena_languages();
    [DllImport(Library)] static extern void jena_set_language(byte[] code);
    [DllImport(Library)] static extern void jena_backup_use_directory(byte[] path);
    [DllImport(Library)] static extern int jena_backup_documents_moved(byte[] source, byte[] destination, out IntPtr error);
    [DllImport(Library)] static extern int jena_backup_has_snapshots(byte[] path, out int has, out IntPtr error);
    [DllImport(Library)] static extern int jena_backup_record(byte[] path, byte[] bytes, nint length, int automatic, byte[]? name, int force, out IntPtr error);
    [DllImport(Library)] static extern int jena_backup_list(byte[] path, out IntPtr result, out IntPtr error);
    [DllImport(Library)] static extern int jena_backup_text(byte[] path, byte[] id, out IntPtr result, out IntPtr error);
    [DllImport(Library)] static extern IntPtr jena_history_rows(byte[] previous, byte[] current);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate void ResultCallback(IntPtr result, IntPtr error, nuint context);

    // Held in a static so the GC never collects it while Swift holds the pointer.
    static readonly ResultCallback Completion = Complete;

    static byte[] Utf8(string text) => Encoding.UTF8.GetBytes(text + "\0");

    static string Take(IntPtr pointer)
    {
        var text = Marshal.PtrToStringUTF8(pointer) ?? "";
        jena_free(pointer);
        return text;
    }

    /// <summary>Markdown text to the JSON block list described in MarkdownJSON.swift.</summary>
    public static string MarkdownToJson(string markdown)
    {
        if (jena_markdown_to_json(Utf8(markdown), out var result, out var error) != 0)
            throw new InvalidOperationException(Take(error));
        return Take(result);
    }

    public static string JsonToMarkdown(string json)
    {
        if (jena_json_to_markdown(Utf8(json), out var result, out var error) != 0)
            throw new InvalidOperationException(Take(error));
        return Take(result);
    }

    static byte[]? OptionalUtf8(string? text) => text == null ? null : Utf8(text);

    static void Complete(IntPtr result, IntPtr error, nuint context)
    {
        var handle = GCHandle.FromIntPtr((nint)context);
        var completion = (TaskCompletionSource<string>)handle.Target!;
        handle.Free();
        // These strings belong to Swift and last only for this call.
        if (error != IntPtr.Zero) completion.SetException(new InvalidOperationException(Marshal.PtrToStringUTF8(error)));
        else completion.SetResult(Marshal.PtrToStringUTF8(result) ?? "");
    }

    static Task<string> Pending(out nuint context)
    {
        // Continuations leave the Swift thread, which must not run app code.
        var completion = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        context = (nuint)(nint)GCHandle.ToIntPtr(GCHandle.Alloc(completion));
        return completion.Task;
    }

    public static void ConfigureProofreading(string modelDirectory) => jena_proofreading_configure(Utf8(modelDirectory));

    /// <summary>Checks `[{"id", "text"}]` and returns `[{"id", "suggestions"}]` as JSON.</summary>
    public static Task<string> Proofread(string itemsJson, string termsJson)
    {
        var task = Pending(out var context);
        jena_proofread(Utf8(itemsJson), Utf8(termsJson), Completion, context);
        return task;
    }

    /// <summary>Checks one selected passage and returns the corrected text.</summary>
    public static Task<string> ProofreadSelection(string text, string termsJson)
    {
        var task = Pending(out var context);
        jena_proofread_selection(Utf8(text), Utf8(termsJson), Completion, context);
        return task;
    }

    public static string WorkStatus(string path)
    {
        var status = jena_work_status(Utf8(path), out var result, out var error);
        return Checked(status, result, error);
    }

    public static string WorkPrepare(string path)
    {
        var status = jena_work_prepare(Utf8(path), out var result, out var error);
        return Checked(status, result, error);
    }

    /// <summary>Zero when the document is not in a work that is switched on.</summary>
    public static IntPtr WorkSessionOpen(string requestJson)
    {
        if (jena_work_session_open(Utf8(requestJson), out var handle, out var error) != 0) throw new InvalidOperationException(Take(error));
        return handle;
    }

    public static string WorkSessionStart(IntPtr handle)
    {
        var status = jena_work_session_start(handle, out var result, out var error);
        return Checked(status, result, error);
    }

    public static string WorkSessionReceive(IntPtr handle, string answer)
    {
        var status = jena_work_session_receive(handle, Utf8(answer), out var result, out var error);
        return Checked(status, result, error);
    }

    public static string WorkSessionPrompt(IntPtr handle, string requestJson)
    {
        var status = jena_work_session_prompt(handle, Utf8(requestJson), out var result, out var error);
        return Checked(status, result, error);
    }

    public static void WorkSessionClose(IntPtr handle) => jena_work_session_close(handle);

    public static string WorkWindowOpen(string path)
    {
        var status = jena_work_window_open(Utf8(path), out var result, out var error);
        return Checked(status, result, error);
    }

    public static string WorkWindowDescribe(string root, string config, string current)
    {
        var status = jena_work_window_describe(Utf8(root), Utf8(config), Utf8(current), out var result, out var error);
        return Checked(status, result, error);
    }

    public static string WorkWindowEdit(string root, string config, bool provisional, string edit)
    {
        var status = jena_work_window_edit(Utf8(root), Utf8(config), provisional ? 1 : 0, Utf8(edit), out var result, out var error);
        return Checked(status, result, error);
    }

    public static void WorkSetCorruptAside(string path)
    {
        if (jena_work_set_corrupt_aside(Utf8(path), out var error) != 0) throw new InvalidOperationException(Take(error));
    }

    public static string AiProviders() => Take(jena_ai_providers());

    static string Checked(int status, IntPtr result, IntPtr error) =>
        status == 0 ? Take(result) : throw new InvalidOperationException(Take(error));

    public static string AiCommand(string provider, string policy, string promptFile, string? model)
    {
        var status = jena_ai_command(Utf8(provider), Utf8(policy), Utf8(promptFile), OptionalUtf8(model), out var result, out var error);
        return Checked(status, result, error);
    }

    public static string AiAnswer(string provider, int exitCode, string stdout, string stderr)
    {
        var status = jena_ai_answer(Utf8(provider), exitCode, Utf8(stdout), Utf8(stderr), out var result, out var error);
        return Checked(status, result, error);
    }

    public static string AiPrompt(string requestJson)
    {
        var status = jena_ai_prompt(Utf8(requestJson), out var result, out var error);
        return Checked(status, result, error);
    }

    public static string AiParseEdit(string answer)
    {
        var status = jena_ai_parse_edit(Utf8(answer), out var result, out var error);
        return Checked(status, result, error);
    }

    public static string[] AiMetadataArguments(string provider) =>
        System.Text.Json.JsonSerializer.Deserialize<string[]>(Take(jena_ai_metadata_arguments(Utf8(provider)))) ?? Array.Empty<string>();

    public static IntPtr AiMetadataOpen(string provider) => jena_ai_metadata_open(Utf8(provider));
    public static string AiMetadataInitial(IntPtr handle) => Take(jena_ai_metadata_initial(handle));

    public static string? AiMetadataReceive(IntPtr handle, string line, out bool complete)
    {
        var reply = jena_ai_metadata_receive(handle, Utf8(line), out var done);
        complete = done != 0;
        return reply == IntPtr.Zero ? null : Take(reply);
    }

    public static string AiMetadataResult(IntPtr handle) => Take(jena_ai_metadata_result(handle));
    public static void AiMetadataClose(IntPtr handle) => jena_ai_metadata_close(handle);
    public static string AiMetadataPlain(string provider, string output) => Take(jena_ai_metadata_plain(Utf8(provider), Utf8(output)));

    /// <summary>Searches every Markdown file in the folders, off the UI thread.</summary>
    public static Task<string> SearchFiles(string query, string foldersJson)
    {
        var task = Pending(out var context);
        jena_search_files(Utf8(query), Utf8(foldersJson), Completion, context);
        return task;
    }

    /// <summary>Keeps tests away from the author's real dictionary.</summary>
    public static void UseDictionaryFile(string path) => jena_dictionary_use_file(Utf8(path));

    public static string DictionaryTerms(string? documentPath)
    {
        if (jena_dictionary_terms(OptionalUtf8(documentPath), out var result, out var error) != 0)
            throw new InvalidOperationException(Take(error));
        return Take(result);
    }

    public static string DictionaryList(string? documentPath)
    {
        if (jena_dictionary_list(OptionalUtf8(documentPath), out var result, out var error) != 0)
            throw new InvalidOperationException(Take(error));
        return Take(result);
    }

    public static void DictionaryAdd(string term, string? documentPath, bool useCurrentWork)
    {
        if (jena_dictionary_add(Utf8(term), OptionalUtf8(documentPath), useCurrentWork ? 1 : 0, out var error) != 0)
            throw new InvalidOperationException(Take(error));
    }

    public static void DictionaryRemove(IEnumerable<string> ids)
    {
        if (jena_dictionary_remove(Utf8(JsonSerializer.Serialize(ids)), out var error) != 0)
            throw new InvalidOperationException(Take(error));
    }

    /// <summary>Builds a docx or hwpx file. `Skipped` counts images left out of it.</summary>
    public static (byte[] Data, int Skipped) Export(string blocksJson, string format, string? baseFolder, double bodySize, double letterSpacing)
    {
        if (jena_export(Utf8(blocksJson), Utf8(format), OptionalUtf8(baseFolder), bodySize, letterSpacing,
                out var data, out var length, out var skipped, out var error) != 0)
            throw new InvalidOperationException(Take(error));
        var bytes = new byte[(int)length];
        Marshal.Copy(data, bytes, 0, bytes.Length);
        jena_free_bytes(data);
        return (bytes, skipped);
    }

    public static double DefaultBodySize => jena_default_body_size();

    /// <summary>`[{"code", "name"}]`.</summary>
    public static string Languages() => Take(jena_languages());

    public static IReadOnlyList<string> LanguageCodes()
    {
        using var list = JsonDocument.Parse(Languages());
        return list.RootElement.EnumerateArray().Select(item => item.GetProperty("code").GetString()!).ToList();
    }

    public static void SetLanguage(string code) => jena_set_language(Utf8(code));

    /// <summary>Keeps tests away from the author's real history.</summary>
    public static void UseBackupDirectory(string path) => jena_backup_use_directory(Utf8(path));

    public static void BackupDocumentsMoved(string source, string destination)
    {
        if (jena_backup_documents_moved(Utf8(source), Utf8(destination), out var error) != 0)
            throw new InvalidOperationException(Take(error));
    }

    public static bool BackupHasSnapshots(string path)
    {
        if (jena_backup_has_snapshots(Utf8(path), out var has, out var error) != 0)
            throw new InvalidOperationException(Take(error));
        return has != 0;
    }

    public static void BackupRecord(string path, byte[] bytes, bool automatic = false, string? name = null, bool force = false)
    {
        if (jena_backup_record(Utf8(path), bytes, bytes.Length, automatic ? 1 : 0, OptionalUtf8(name), force ? 1 : 0, out var error) != 0)
            throw new InvalidOperationException(Take(error));
    }

    /// <summary>Versions, newest first, as `[{"id", "createdAt", "name"}]`.</summary>
    public static string BackupList(string path)
    {
        if (jena_backup_list(Utf8(path), out var result, out var error) != 0)
            throw new InvalidOperationException(Take(error));
        return Take(result);
    }

    public static string BackupText(string path, string id)
    {
        if (jena_backup_text(Utf8(path), Utf8(id), out var result, out var error) != 0)
            throw new InvalidOperationException(Take(error));
        return Take(result);
    }

    /// <summary>Aligned comparison rows as JSON, or `null` when the texts are too large.</summary>
    public static string HistoryRows(string previous, string current) => Take(jena_history_rows(Utf8(previous), Utf8(current)));

    /// <summary>Translated text. Unknown keys come back unchanged.</summary>
    public static string Tr(string key) => Take(jena_tr(Utf8(key)));
}
