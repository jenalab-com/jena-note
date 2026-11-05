using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using JenaSpike;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

// Usage: EditorWpf wpf|web [--chars N] [--out FILE]
static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        var candidate = args.Length > 0 ? args[0] : "wpf";
        var options = SpikeArgs.Parse(args);
        var app = new Application();
        var window = new Window { Title = $"jena-note spike: {candidate}", Width = 1100, Height = 800 };
        window.Loaded += async (_, _) =>
        {
            var report = new Report { Candidate = candidate, Chars = options.Chars };
            try
            {
                if (candidate == "web") await WebCandidate.Run(window, options, report);
                else await WpfCandidate.Run(window, options, report);
            }
            catch (Exception error) { report.Add("fatal", error.ToString()); }
            if (options.OutputPath != null)
            {
                report.Save(options.OutputPath);
                await Task.Delay(2500); // Leaves time for an outside screenshot.
                app.Shutdown();
            }
        };
        app.Run(window);
    }
}

static class WpfCandidate
{
    static Task Idle() => Application.Current.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle).Task;

    static FlowDocument Build(List<string> paragraphs)
    {
        var document = new FlowDocument { FontFamily = new FontFamily("Malgun Gothic"), FontSize = 16, PagePadding = new Thickness(48) };
        foreach (var text in paragraphs) document.Blocks.Add(new Paragraph(new Run(text)));
        return document;
    }

    /// A short wavy line as a tiled brush: WPF has no built-in wavy decoration.
    static TextDecorationCollection Wavy()
    {
        var geometry = Geometry.Parse("M0,2 Q1.5,0 3,2 T6,2");
        var drawing = new GeometryDrawing(null, new Pen(Brushes.Red, 0.8), geometry);
        var brush = new DrawingBrush(drawing)
        {
            TileMode = TileMode.Tile, Viewport = new Rect(0, 0, 6, 3), ViewportUnits = BrushMappingMode.Absolute,
            Viewbox = new Rect(0, 0, 6, 3), ViewboxUnits = BrushMappingMode.Absolute, Stretch = Stretch.None,
        };
        return new TextDecorationCollection { new TextDecoration(TextDecorationLocation.Underline, new Pen(brush, 3), 1, TextDecorationUnit.Pixel, TextDecorationUnit.Pixel) };
    }

    public static async Task Run(Window window, SpikeArgs options, Report report)
    {
        var paragraphs = TestDoc.Paragraphs(options.Chars);
        report.ParagraphCount = paragraphs.Count;
        var editor = new RichTextBox { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        window.Content = editor;
        await Idle();

        var watch = Stopwatch.StartNew();
        var document = Build(paragraphs);
        editor.Document = document;
        editor.UpdateLayout();
        await Idle();
        report.Add("open_ms", Timing.Ms(watch));
        report.Add("working_set_mb", Timing.WorkingSetMb());
        if (options.OutputPath == null) return; // Manual mode: leave the editor for Korean IME testing.

        var blocks = document.Blocks.OfType<Paragraph>().ToList();
        var wavy = Wavy();
        watch.Restart();
        for (var i = 0; i < 200; i++)
        {
            var paragraph = blocks[i * blocks.Count / 200];
            var start = paragraph.ContentStart.GetPositionAtOffset(1)!;
            new TextRange(start, start.GetPositionAtOffset(6)!).ApplyPropertyValue(Inline.TextDecorationsProperty, wavy);
        }
        editor.UpdateLayout();
        await Idle();
        report.Add("underline_200_ms", Timing.Ms(watch));
        report.Add("wavy_underline", "custom brush");

        var middle = blocks[blocks.Count / 2];
        editor.CaretPosition = middle.ContentStart.GetPositionAtOffset(1)!;
        editor.Focus();
        var edits = new List<double>();
        for (var i = 0; i < 50; i++)
        {
            watch.Restart();
            editor.CaretPosition.InsertTextInRun("가");
            editor.UpdateLayout();
            edits.Add(watch.Elapsed.TotalMilliseconds);
            await Dispatcher.Yield(DispatcherPriority.Background);
        }
        report.Add("edit_median_ms", Timing.Median(edits));

        watch.Restart();
        var table = new Table();
        table.Columns.Add(new TableColumn());
        table.Columns.Add(new TableColumn());
        var group = new TableRowGroup();
        var row = new TableRow();
        row.Cells.Add(new TableCell(new Paragraph(new Run("셀 1"))) { BorderBrush = Brushes.Gray, BorderThickness = new Thickness(1) });
        row.Cells.Add(new TableCell(new Paragraph(new Run("셀 2"))) { BorderBrush = Brushes.Gray, BorderThickness = new Thickness(1) });
        group.Rows.Add(row);
        table.RowGroups.Add(group);
        document.Blocks.InsertAfter(blocks[0], table);
        var bitmap = BitmapSource.Create(64, 64, 96, 96, PixelFormats.Bgr32, null, new byte[64 * 64 * 4], 64 * 4);
        document.Blocks.InsertAfter(blocks[1], new BlockUIContainer(new Image { Source = bitmap, Width = 64 }));
        editor.UpdateLayout();
        await Idle();
        report.Add("table_image_ms", Timing.Ms(watch));

        // FlowDocument paginates on its own. Use a second copy because the first one belongs to the editor.
        watch.Restart();
        var paged = Build(paragraphs);
        var paginator = ((IDocumentPaginatorSource)paged).DocumentPaginator;
        paginator.PageSize = new Size(794, 1123); // A4 at 96 dpi
        paginator.ComputePageCount();
        report.Add("paginate_ms", Timing.Ms(watch));
        report.Add("page_count", paginator.PageCount);
        report.Add("working_set_end_mb", Timing.WorkingSetMb());
        editor.ScrollToHome();
    }
}

static class WebCandidate
{
    public static async Task Run(Window window, SpikeArgs options, Report report)
    {
        var paragraphs = TestDoc.Paragraphs(options.Chars);
        report.ParagraphCount = paragraphs.Count;
        var view = new WebView2();
        window.Content = view;
        var folder = Path.Combine(Path.GetTempPath(), "jena-note-spike-webview2");
        var environment = await CoreWebView2Environment.CreateAsync(userDataFolder: folder);
        await view.EnsureCoreWebView2Async(environment);
        var web = view.CoreWebView2;
        web.SetVirtualHostNameToFolderMapping("spike.local", Path.Combine(AppContext.BaseDirectory, "web"), CoreWebView2HostResourceAccessKind.Allow);

        var navigated = new TaskCompletionSource();
        view.NavigationCompleted += (_, _) => navigated.TrySetResult();
        web.Navigate("https://spike.local/editor.html");
        await navigated.Task;

        var answer = new TaskCompletionSource<string>();
        web.WebMessageReceived += (_, e) => answer.TrySetResult(e.TryGetWebMessageAsString());
        var mode = options.OutputPath == null ? "open" : "all";
        web.PostWebMessageAsJson(JsonSerializer.Serialize(new { mode, paragraphs }));
        var results = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(await answer.Task)!;
        foreach (var (name, value) in results) report.Add(name, value);

        // Whole browser process tree, since most memory lives outside this process.
        var total = 0L;
        foreach (var id in web.Environment.GetProcessInfos().Select(p => p.ProcessId))
        {
            try { using var process = Process.GetProcessById(id); total += process.WorkingSet64; }
            catch (ArgumentException) { }
        }
        report.Add("webview_processes_mb", Math.Round(total / 1048576.0, 1));
        report.Add("working_set_host_mb", Timing.WorkingSetMb());
    }
}
