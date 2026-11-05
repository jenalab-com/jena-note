using System.Diagnostics;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

// Spike harness: drives the Swift library from C# through its C ABI.
// Usage: Harness <kiwi-model-dir>. Exit code is the number of failed checks.

Console.OutputEncoding = Encoding.UTF8;
var modelDir = args.Length > 0 ? args[0] : throw new ArgumentException("kiwi model directory required");
var failures = 0;

void Check(string name, bool ok, string detail = "")
{
    Console.WriteLine($"{(ok ? "PASS" : "FAIL")}  {name}{(detail.Length > 0 ? "  (" + detail + ")" : "")}");
    if (!ok) failures++;
}

// 1. Strings across the boundary
var sample = "한글 + emoji 😀 + 漢字 + \"quote\"";
Check("UTF-8 round trip", Native.Echo(sample) == sample);

var watch = Stopwatch.StartNew();
const int calls = 100_000;
for (var i = 0; i < calls; i++) Native.Echo("안녕하세요");
watch.Stop();
Console.WriteLine($"INFO  {calls} echo calls: {watch.ElapsedMilliseconds} ms ({watch.Elapsed.TotalMicroseconds / calls:F2} us/call)");

// 2. Synchronous call that returns bytes: real HwpxWriter from the macOS sources
var blocks = JsonSerializer.Serialize(new object[]
{
    new { type = "heading", level = 1, inlines = new[] { new { text = "제목 <1>" } } },
    new { type = "paragraph", inlines = new object[] { new { text = "본문 " }, new { text = "굵게", bold = true } } },
    new { type = "horizontalRule" },
    new { type = "codeBlock", text = "let a = 1 & 2" },
});
var hwpx = Native.Hwpx(blocks, out var hwpxError);
Check("HWPX returned", hwpx != null, hwpxError ?? "");
if (hwpx != null)
{
    using var zip = new ZipArchive(new MemoryStream(hwpx));
    Check("HWPX mimetype is the first zip entry", zip.Entries[0].FullName == "mimetype");
    var section = zip.GetEntry("Contents/section0.xml");
    Check("HWPX has a section", section != null);
    if (section != null)
    {
        using var reader = new StreamReader(section.Open(), Encoding.UTF8);
        var xml = reader.ReadToEnd();
        Check("HWPX keeps Korean and escapes XML", xml.Contains("제목 &lt;1&gt;") && xml.Contains("1 &amp; 2"));
    }
}

// 3. Errors come back as values
Check("Bad JSON returns an error", Native.Hwpx("{not json", out var badJson) == null && badJson != null);
Check("Unknown block returns an error", Native.Hwpx("[{\"type\":\"nope\"}]", out var badBlock) == null && badBlock != null);

// 4. Async call with a callback from a Swift thread: real Kiwi engine
Native.Configure(modelDir);
watch.Restart();
var first = await Native.Proofread("오랫만에 친구를 만났다.");
Console.WriteLine($"INFO  first proofread with model load: {watch.ElapsedMilliseconds} ms");
Check("Proofread first call", first == "오랜만에 친구를 만났다.", first);

(string Source, string Expected)[] examples =
{
    ("나는 학교 에 갔다.", "나는 학교에 갔다."),
    ("몇일 동안 기다렸다.", "며칠 동안 기다렸다."),
    ("이건 않되요.", "이건 안 돼요."),
    ("😀 그제야 리에느가 빵을 받았다.", "😀 그제야 리에느가 빵을 받았다."),
    ("  오늘학교에갔다.  ", "  오늘 학교에 갔다.  "),
};
foreach (var (source, expected) in examples)
{
    watch.Restart();
    var result = await Native.Proofread(source);
    Check($"Proofread \"{source}\"", result == expected, $"{watch.ElapsedMilliseconds} ms, got \"{result}\"");
}

// 5. Concurrent requests must each get their own answer
var concurrent = await Task.WhenAll(Enumerable.Range(0, 32).Select(i =>
{
    var (source, expected) = examples[i % examples.Length];
    return Native.Proofread(source).ContinueWith(t => t.Result == expected);
}));
Check("32 concurrent proofreads", concurrent.All(ok => ok));

Console.WriteLine(failures == 0 ? "ALL PASSED" : $"{failures} FAILED");
return failures;

static class Native
{
    const string Lib = "JenaNoteKit";

    [DllImport(Lib)] static extern void jena_free(IntPtr pointer);
    [DllImport(Lib)] static extern IntPtr jena_echo(byte[] text);
    [DllImport(Lib)] static extern int jena_hwpx_from_json(byte[] json, out IntPtr data, out nint length, out IntPtr error);
    [DllImport(Lib)] static extern void jena_proofread_configure(byte[] modelDirectory);
    [DllImport(Lib)] static extern void jena_proofread(byte[] text, ResultCallback callback, nuint context);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate void ResultCallback(IntPtr result, IntPtr error, nuint context);

    // Held in a static so the GC never collects it while Swift owns the pointer.
    static readonly ResultCallback Callback = OnResult;

    static byte[] Utf8(string text) => Encoding.UTF8.GetBytes(text + "\0");

    public static string Echo(string text)
    {
        var pointer = jena_echo(Utf8(text));
        var result = Marshal.PtrToStringUTF8(pointer)!;
        jena_free(pointer);
        return result;
    }

    public static byte[]? Hwpx(string json, out string? error)
    {
        var status = jena_hwpx_from_json(Utf8(json), out var data, out var length, out var errorPointer);
        if (status != 0)
        {
            error = Marshal.PtrToStringUTF8(errorPointer);
            jena_free(errorPointer);
            return null;
        }
        error = null;
        var bytes = new byte[(int)length];
        Marshal.Copy(data, bytes, 0, bytes.Length);
        jena_free(data);
        return bytes;
    }

    public static void Configure(string modelDirectory) => jena_proofread_configure(Utf8(modelDirectory));

    public static Task<string> Proofread(string text)
    {
        var completion = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        var handle = GCHandle.Alloc(completion);
        jena_proofread(Utf8(text), Callback, (nuint)(nint)GCHandle.ToIntPtr(handle));
        return completion.Task;
    }

    static void OnResult(IntPtr result, IntPtr error, nuint context)
    {
        var handle = GCHandle.FromIntPtr((nint)context);
        var completion = (TaskCompletionSource<string>)handle.Target!;
        handle.Free();
        if (error != IntPtr.Zero) completion.SetException(new Exception(Marshal.PtrToStringUTF8(error)));
        else completion.SetResult(Marshal.PtrToStringUTF8(result)!);
    }
}
