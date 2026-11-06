using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;

namespace JenaNote;

static class Program
{
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr process, uint exitCode);

    /// <summary>
    /// Everything is on disk by now. Native libraries still hold worker threads and a large model,
    /// and a normal exit waits for their cleanup. One such process was seen staying alive with no
    /// windows, so the app ends here instead of depending on it.
    /// </summary>
    static int EndProcess(int exitCode)
    {
        Trace.Flush();
        using var current = Process.GetCurrentProcess();
        TerminateProcess(current.Handle, (uint)exitCode);
        return exitCode;
    }

    [STAThread]
    static int Main(string[] args)
    {
        var app = new Application { ShutdownMode = ShutdownMode.OnLastWindowClose };
        NativeCore.ConfigureProofreading(Path.Combine(AppContext.BaseDirectory, "KiwiModel"));

        // Automated tests run the real app without touching the author's history or dictionary.
        var testData = Environment.GetEnvironmentVariable("JENANOTE_TEST_DATA");
        if (!string.IsNullOrEmpty(testData))
        {
            NativeCore.UseBackupDirectory(Path.Combine(testData, "Backups"));
            NativeCore.UseDictionaryFile(Path.Combine(testData, "dictionary.json"));
            RecoveryStore.Folder = Path.Combine(testData, "Recovery");
            AppSettings.Folder = testData;
        }
        if (args.FirstOrDefault() != "--selftest") AppSettings.Load();

        if (args.Length == 3 && args[0] == "--selftest")
        {
            app.ShutdownMode = ShutdownMode.OnExplicitShutdown;
            app.Startup += (_, _) => SelfTest.Run(app, args[1], args[2]);
            return EndProcess(app.Run());
        }

        app.Startup += (_, _) =>
        {
            var opened = OfferRecovery();
            foreach (var path in args)
            {
                if (EditorWindow.Open(path, target: null) != null) opened = true;
            }
            if (!opened) new EditorWindow().Show();
        };
        return EndProcess(app.Run());
    }

    /// <summary>Offers documents left behind when the app last ended without closing them.</summary>
    static bool OfferRecovery()
    {
        var orphans = RecoveryStore.Orphans();
        if (orphans.Count == 0) return false;
        var answer = MessageBox.Show(NativeCore.Tr("doc.recover").Replace("%d", orphans.Count.ToString()), "Jena Note",
            MessageBoxButton.YesNoCancel, MessageBoxImage.Question);
        if (answer == MessageBoxResult.No)
        {
            foreach (var orphan in orphans) RecoveryStore.Delete(orphan.Id);
            return false;
        }
        if (answer != MessageBoxResult.Yes) return false;
        foreach (var orphan in orphans)
        {
            // The window keeps this copy until the text is saved, in case of another failure.
            RecoveryStore.Save(orphan.Id, orphan.Path, orphan.Plain, orphan.Text);
            new EditorWindow(orphan.Path, orphan.Text, orphan.Id).Show();
        }
        return true;
    }
}
