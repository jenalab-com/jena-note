using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows.Threading;

namespace JenaNote;

/// <summary>
/// The local (llama.cpp) provider, as on macOS: the app talks to an OpenAI compatible server over
/// HTTP instead of running a CLI for each request.
/// </summary>
static class LocalAi
{
    public const string DefaultAddress = "http://127.0.0.1:8080";
    /// <summary>A small model on a slow machine reads a long document for minutes before it answers.</summary>
    public static TimeSpan RequestTimeout { get; set; } = TimeSpan.FromSeconds(600);

    static readonly HttpClient Http = new() { Timeout = Timeout.InfiniteTimeSpan };

    /// <summary>The configured server, or null when the address is not an http(s) address.</summary>
    public static Uri? ServerUri()
    {
        var address = AppSettings.Current.AiLocalAddress.Trim();
        if (!Uri.TryCreate(address, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https") || uri.Host.Length == 0) return null;
        return new Uri(uri.GetLeftPart(UriPartial.Path).TrimEnd('/') + "/");
    }

    public static async Task<AiAnswer> SendAsync(string prompt, string? model, TimeSpan timeout, CancellationToken cancel)
    {
        var server = ServerUri() ?? throw new AiFailure(NativeCore.Tr("ai.local.invalidAddress"));
        var body = new JsonObject
        {
            ["messages"] = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = prompt }),
            ["stream"] = false,
        };
        if (!string.IsNullOrWhiteSpace(model)) body["model"] = model.Trim();

        using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        limit.CancelAfter(timeout > RequestTimeout ? timeout : RequestTimeout);
        try
        {
            using var content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
            using var response = await Http.PostAsync(new Uri(server, "v1/chat/completions"), content, limit.Token).ConfigureAwait(false);
            var data = await response.Content.ReadAsStringAsync(limit.Token).ConfigureAwait(false);
            return Reply(data, (int)response.StatusCode);
        }
        catch (OperationCanceledException) when (cancel.IsCancellationRequested)
        {
            throw new AiFailure(NativeCore.Tr("ai.cancelled"));
        }
        catch (OperationCanceledException)
        {
            throw new AiFailure(NativeCore.Tr("ai.local.timeout"));
        }
        catch (HttpRequestException)
        {
            throw new AiFailure(NativeCore.Tr("ai.local.notRunning"));
        }
    }

    /// <summary>Only the final answer belongs in the chat. Reasoning arrives in its own field.</summary>
    public static AiAnswer Reply(string data, int status)
    {
        JsonNode? root = null;
        try
        {
            root = JsonNode.Parse(data);
        }
        catch (JsonException)
        {
            // A proxy or a crashed server can answer with anything.
        }
        if (status != 200)
        {
            var detail = root?["error"]?["message"]?.GetValue<string>() ?? (data.Length > 1800 ? data[..1800] : data);
            throw new AiFailure(NativeCore.Tr("ai.local.requestFailed") + "\n" + detail);
        }
        var text = root?["choices"]?[0]?["message"]?["content"] is JsonValue value && value.TryGetValue<string>(out var said) ? said : null;
        if (string.IsNullOrWhiteSpace(text)) throw new AiFailure(NativeCore.Tr("ai.invalidResponse"));
        var tokens = root?["usage"]?["total_tokens"] is JsonValue used && used.TryGetValue<int>(out var total) ? total : (int?)null;
        return new AiAnswer(text, tokens);
    }

    /// <summary>llama-server answers 503 until the model has finished loading.</summary>
    public static async Task<bool> IsHealthyAsync()
    {
        var server = ServerUri();
        if (server == null) return false;
        try
        {
            using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            using var response = await Http.GetAsync(new Uri(server, "health"), limit.Token).ConfigureAwait(false);
            return (int)response.StatusCode == 200;
        }
        catch (Exception error) when (error is HttpRequestException or OperationCanceledException)
        {
            return false;
        }
    }
}

/// <summary>
/// Owns the author's local model server while the app runs. Unlike a CLI request it outlives any one
/// prompt, so its output goes to a log file. A job holds the launcher and what it starts, so stopping
/// it, or the app ending in any way, takes the model out of memory.
/// </summary>
static class LocalAiServer
{
    public enum Kind { Stopped, Starting, Running, Failed }

    public sealed record State(Kind Kind, DateTime Since = default, bool Owned = false, string Message = "");

    /// <summary>A multi-gigabyte model on a slow disk took minutes to load on macOS.</summary>
    public static TimeSpan StartupLimit { get; set; } = TimeSpan.FromSeconds(900);
    public static TimeSpan PollInterval { get; set; } = TimeSpan.FromSeconds(1);
    const long MaxLogBytes = 4 * 1024 * 1024;

    public static State Current { get; private set; } = new(Kind.Stopped);
    /// <summary>Raised on the UI thread when the state changes, and every second while the model loads.</summary>
    public static event Action? Changed;

    public static string LogPath => Path.Combine(AppSettings.Folder, "local-server.log");

    static Process? process;
    static AiProcess.ProcessJob? job;
    static DispatcherTimer? poll;
    static bool stopRequested;

    static void Set(State state)
    {
        Current = state;
        Changed?.Invoke();
    }

    /// <summary>Finds a server another tool left running, without taking ownership of it.</summary>
    public static async Task RefreshAsync()
    {
        if (process != null) return;
        var healthy = await LocalAi.IsHealthyAsync();
        if (process != null) return;
        if (healthy) Set(new State(Kind.Running, Owned: false));
        else if (Current.Kind == Kind.Running) Set(new State(Kind.Stopped));
    }

    public static async Task StartAsync()
    {
        if (process != null) return;
        if (LocalAi.ServerUri() == null)
        {
            Set(new State(Kind.Failed, Message: NativeCore.Tr("ai.local.invalidAddress")));
            return;
        }
        if (await LocalAi.IsHealthyAsync())
        {
            if (process == null) Set(new State(Kind.Running, Owned: false));
            return;
        }
        if (process != null) return;
        Launch();
    }

    public static void Stop()
    {
        if (process == null) return;
        stopRequested = true;
        EndPolling();
        job?.Terminate();
    }

    static string? Launcher()
    {
        var configured = AppSettings.Current.AiPaths.GetValueOrDefault("local", "").Trim();
        if (configured.Length == 0) return null;
        var path = Environment.ExpandEnvironmentVariables(configured);
        return File.Exists(path) ? Path.GetFullPath(path) : null;
    }

    /// <summary>A program starts as it is. A script starts through the shell that runs it.</summary>
    static ProcessStartInfo StartInfo(string launcher)
    {
        var extension = Path.GetExtension(launcher).ToLowerInvariant();
        var start = extension switch
        {
            ".cmd" or ".bat" => new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "cmd.exe")) { ArgumentList = { "/d", "/c", launcher } },
            ".ps1" => new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"))
            {
                ArgumentList = { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", launcher },
            },
            _ => new ProcessStartInfo(launcher),
        };
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        start.RedirectStandardOutput = true;
        start.RedirectStandardError = true;
        start.RedirectStandardInput = true;
        // Relative model paths in a launcher script mean the script's own folder.
        start.WorkingDirectory = Path.GetDirectoryName(launcher)!;
        start.Environment["PATH"] = Path.GetDirectoryName(launcher) + ";" + AiExecutable.SearchPath();
        if (LocalAi.ServerUri() is { } server) start.Environment["PORT"] = server.Port.ToString();
        return start;
    }

    static void Launch()
    {
        var launcher = Launcher();
        if (launcher == null)
        {
            Set(new State(Kind.Failed, Message: NativeCore.Tr("ai.local.noExecutable")));
            return;
        }
        var started = new Process { StartInfo = StartInfo(launcher), EnableRaisingEvents = true };
        var holder = new AiProcess.ProcessJob();
        try
        {
            Directory.CreateDirectory(AppSettings.Folder);
            File.WriteAllText(LogPath, "");
            started.Start();
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or IOException or UnauthorizedAccessException)
        {
            holder.Dispose();
            started.Dispose();
            Set(new State(Kind.Failed, Message: NativeCore.Tr("ai.local.exited") + "\n" + error.Message));
            return;
        }
        holder.Add(started);
        started.StandardInput.Close();
        process = started;
        job = holder;
        stopRequested = false;
        var logPath = LogPath;
        var writing = Task.WhenAll(CopyAsync(started.StandardOutput.BaseStream, logPath), CopyAsync(started.StandardError.BaseStream, logPath));
        var dispatcher = System.Windows.Application.Current?.Dispatcher ?? Dispatcher.CurrentDispatcher;
        started.Exited += (_, _) => dispatcher.BeginInvoke(async () =>
        {
            // The last lines usually say why it ended.
            await Task.WhenAny(writing, Task.Delay(500));
            Exited(started);
        });
        var since = DateTime.Now;
        Set(new State(Kind.Starting, since));
        poll = new DispatcherTimer { Interval = PollInterval };
        poll.Tick += async (_, _) =>
        {
            if (process != started || Current.Kind != Kind.Starting) return;
            if (DateTime.Now - since >= StartupLimit)
            {
                EndPolling();
                job?.Terminate();
                Set(new State(Kind.Failed, Message: NativeCore.Tr("ai.local.startTimeout")));
                return;
            }
            var healthy = await LocalAi.IsHealthyAsync();
            if (process != started || stopRequested || Current.Kind != Kind.Starting) return;
            if (healthy)
            {
                EndPolling();
                Set(new State(Kind.Running, Owned: true));
            }
            else
            {
                // The ticks drive the elapsed time shown while the model loads.
                Changed?.Invoke();
            }
        };
        poll.Start();
    }

    static readonly object LogLock = new();

    /// <summary>The log is opened for each write, so nothing holds it while the server is quiet.</summary>
    static async Task CopyAsync(Stream source, string logPath)
    {
        var buffer = new byte[8192];
        try
        {
            while (true)
            {
                var count = await source.ReadAsync(buffer).ConfigureAwait(false);
                if (count <= 0) return;
                lock (LogLock)
                {
                    using var log = new FileStream(logPath, FileMode.OpenOrCreate, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
                    // The server logs every request. Only the latest part matters for a failure.
                    if (log.Length + count > MaxLogBytes) log.SetLength(0);
                    log.Seek(0, SeekOrigin.End);
                    log.Write(buffer, 0, count);
                }
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ObjectDisposedException)
        {
            // The server is gone, or its log cannot be written. Neither stops the server.
        }
    }

    static void Exited(Process exited)
    {
        if (process != exited) return;
        EndPolling();
        // Anything the launcher left behind must not keep the model in memory.
        job?.Terminate();
        job?.Dispose();
        job = null;
        process = null;
        exited.Dispose();
        if (Current.Kind == Kind.Failed && !stopRequested) return;
        Set(stopRequested ? new State(Kind.Stopped) : new State(Kind.Failed, Message: NativeCore.Tr("ai.local.exited") + "\n" + LogTail()));
    }

    static void EndPolling()
    {
        poll?.Stop();
        poll = null;
    }

    public static string LogTail()
    {
        try
        {
            using var stream = new FileStream(LogPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            var length = (int)Math.Min(stream.Length, 600);
            stream.Seek(-length, SeekOrigin.End);
            var bytes = new byte[length];
            stream.ReadExactly(bytes);
            return Encoding.UTF8.GetString(bytes).Trim();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return "";
        }
    }

    /// <summary>The status line for the settings window.</summary>
    public static string Describe()
    {
        var state = Current;
        switch (state.Kind)
        {
            case Kind.Starting:
                var elapsed = DateTime.Now - state.Since;
                return NativeCore.Tr("ai.local.starting").Replace("%@", $"{(int)elapsed.TotalMinutes}:{elapsed.Seconds:00}");
            case Kind.Running:
                return NativeCore.Tr(state.Owned ? "ai.local.running" : "ai.local.external");
            case Kind.Failed:
                return state.Message.Length > 2000 ? state.Message[..2000] : state.Message;
            default:
                return NativeCore.Tr("ai.local.stopped");
        }
    }

    /// <summary>For tests: whether this app holds a server process.</summary>
    public static bool OwnsProcess => process != null;
}
