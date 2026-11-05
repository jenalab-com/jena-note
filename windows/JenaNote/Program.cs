using System.IO;
using System.Windows;

namespace JenaNote;

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        var app = new Application { ShutdownMode = ShutdownMode.OnLastWindowClose };
        NativeCore.ConfigureProofreading(Path.Combine(AppContext.BaseDirectory, "KiwiModel"));

        if (args.Length == 3 && args[0] == "--selftest")
        {
            app.ShutdownMode = ShutdownMode.OnExplicitShutdown;
            app.Startup += (_, _) => SelfTest.Run(app, args[1], args[2]);
            return app.Run();
        }

        app.Startup += (_, _) =>
        {
            var opened = false;
            foreach (var path in args)
            {
                if (EditorWindow.Open(path, target: null) != null) opened = true;
            }
            if (!opened) new EditorWindow().Show();
        };
        return app.Run();
    }
}
