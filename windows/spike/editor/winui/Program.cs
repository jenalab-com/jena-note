using System.Diagnostics;
using JenaSpike;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.UI;

namespace JenaSpike;

// Usage: EditorWinUI [--chars N] [--out FILE]
static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(_ =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            new SpikeApp(SpikeArgs.Parse(args));
        });
    }
}

public partial class SpikeApp : Application
{
    readonly SpikeArgs options;
    Window? window;

    public SpikeApp(SpikeArgs options)
    {
        this.options = options;
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        window = new Window { Title = "jena-note spike: winui" };
        var editor = new RichEditBox { AcceptsReturn = true };
        ScrollViewer.SetVerticalScrollBarVisibility(editor, ScrollBarVisibility.Auto);
        window.Content = editor;
        window.AppWindow.Resize(new Windows.Graphics.SizeInt32(1100, 800));
        window.Activate();
        editor.Loaded += async (_, _) =>
        {
            var report = new Report { Candidate = "winui", Chars = options.Chars };
            try { await Measure(editor, report); }
            catch (Exception error) { report.Add("fatal", error.ToString()); }
            if (options.OutputPath != null)
            {
                report.Save(options.OutputPath);
                await Task.Delay(2500); // Leaves time for an outside screenshot.
                Exit();
            }
        };
    }

    static Task Idle(RichEditBox editor)
    {
        var done = new TaskCompletionSource();
        editor.DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () => done.SetResult());
        return done.Task;
    }

    async Task Measure(RichEditBox editor, Report report)
    {
        var paragraphs = TestDoc.Paragraphs(options.Chars);
        report.ParagraphCount = paragraphs.Count;
        var text = string.Join("\r", paragraphs);
        await Idle(editor);

        var watch = Stopwatch.StartNew();
        editor.Document.SetText(TextSetOptions.None, text);
        editor.UpdateLayout();
        await Idle(editor);
        report.Add("open_ms", Timing.Ms(watch));
        report.Add("working_set_mb", Timing.WorkingSetMb());
        if (options.OutputPath == null) return; // Manual mode: leave the editor for Korean IME testing.

        var offsets = new List<int>();
        var position = 0;
        foreach (var paragraph in paragraphs) { offsets.Add(position); position += paragraph.Length + 1; }

        watch.Restart();
        for (var i = 0; i < 200; i++)
        {
            var start = offsets[i * offsets.Count / 200];
            var range = editor.Document.GetRange(start, start + 6);
            range.CharacterFormat.Underline = UnderlineType.Wave;
            range.CharacterFormat.ForegroundColor = Color.FromArgb(255, 200, 0, 0);
        }
        editor.UpdateLayout();
        await Idle(editor);
        report.Add("underline_200_ms", Timing.Ms(watch));
        report.Add("wavy_underline", "UnderlineType.Wave; underline color not separately tested");

        var middle = offsets[offsets.Count / 2];
        editor.Focus(FocusState.Programmatic);
        var edits = new List<double>();
        for (var i = 0; i < 50; i++)
        {
            watch.Restart();
            editor.Document.GetRange(middle, middle).SetText(TextSetOptions.None, "가");
            editor.UpdateLayout();
            edits.Add(watch.Elapsed.TotalMilliseconds);
            await Idle(editor);
        }
        report.Add("edit_median_ms", Timing.Median(edits));

        // No table or block API. RTF is the only way in, so check whether a table survives it.
        watch.Restart();
        var table = @"{\rtf1\ansi\trowd\cellx3000\cellx6000 A\intbl\cell B\intbl\cell\row}";
        editor.Document.GetRange(0, 0).SetText(TextSetOptions.FormatRtf, table);
        editor.UpdateLayout();
        await Idle(editor);
        report.Add("table_image_ms", Timing.Ms(watch));
        editor.Document.GetRange(0, 40).GetText(TextGetOptions.None, out var head);
        report.Add("table_rtf_text_head", head.Replace("\r", "\\r"));
        report.Add("table_api", "none (RTF import only)");

        report.Add("paginate_ms", null);
        report.Add("page_count", "no pagination API");
        report.Add("working_set_end_mb", Timing.WorkingSetMb());
        editor.Document.Selection.SetRange(0, 0);
    }
}
