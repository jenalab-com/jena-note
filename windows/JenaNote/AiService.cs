using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace JenaNote;

/// <summary>A failure to show the author. Its message is already in their language.</summary>
sealed class AiFailure(string message) : Exception(message);

sealed record AiOutput(int Status, string Stdout, string Stderr);

/// <summary>Finds a CLI and works out how to start it.</summary>
static partial class AiExecutable
{
    /// <summary>Everywhere a CLI installer on Windows puts things, after the PATH.</summary>
    static IEnumerable<string> SearchDirectories()
    {
        // An installer run while the app is open only changes the stored PATH, not this process's.
        foreach (var target in new[] { EnvironmentVariableTarget.Process, EnvironmentVariableTarget.User, EnvironmentVariableTarget.Machine })
        {
            foreach (var part in (Environment.GetEnvironmentVariable("PATH", target) ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries))
                yield return part.Trim().Trim('"');
        }
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        yield return Path.Combine(home, ".local", "bin");
        yield return Path.Combine(appData, "npm");
        yield return Path.Combine(home, ".grok", "bin");
        yield return Path.Combine(home, ".cargo", "bin");
        yield return Path.Combine(home, ".volta", "bin");
        yield return Path.Combine(home, ".bun", "bin");
        var symlink = Environment.GetEnvironmentVariable("NVM_SYMLINK");
        if (!string.IsNullOrEmpty(symlink)) yield return symlink;
    }

    public static string SearchPath() => string.Join(';', SearchDirectories().Distinct(StringComparer.OrdinalIgnoreCase));

    static string? Find(string name)
    {
        foreach (var directory in SearchDirectories())
        {
            // A PATH entry can be anything. Only a usable file in a real folder counts.
            foreach (var extension in new[] { ".exe", ".cmd", ".bat" })
            {
                try
                {
                    var candidate = Path.Combine(directory, name + extension);
                    if (Path.IsPathFullyQualified(candidate) && File.Exists(candidate)) return candidate;
                }
                catch (ArgumentException)
                {
                    break;
                }
            }
        }
        return null;
    }

    public static string? Locate(string provider)
    {
        var custom = AppSettings.Current.AiPaths.GetValueOrDefault(provider, "").Trim();
        if (custom.Length > 0)
        {
            var expanded = Environment.ExpandEnvironmentVariables(custom);
            return File.Exists(expanded) ? Path.GetFullPath(expanded) : null;
        }
        return Find(provider);
    }

    [GeneratedRegex("\"%~?dp0%?\\\\?([^\"]+)\"\\s+%\\*")]
    private static partial Regex ShimTarget();

    /// <summary>
    /// A batch file would go through cmd.exe, which reads its own meaning into the arguments. npm's
    /// launcher names the real program, so that is started directly instead.
    /// </summary>
    public static (string File, string[] Prefix) Resolve(string executable)
    {
        var extension = Path.GetExtension(executable).ToLowerInvariant();
        if (extension == ".exe") return (executable, Array.Empty<string>());
        if (extension is not (".cmd" or ".bat")) throw new AiFailure(NativeCore.Tr("doc.aiShimUnsupported"));

        var folder = Path.GetDirectoryName(executable)!;
        var matches = ShimTarget().Matches(File.ReadAllText(executable));
        if (matches.Count == 0) throw new AiFailure(NativeCore.Tr("doc.aiShimUnsupported"));
        var target = Path.GetFullPath(Path.Combine(folder, matches[^1].Groups[1].Value));
        if (!File.Exists(target)) throw new AiFailure(NativeCore.Tr("doc.aiShimUnsupported"));
        if (Path.GetExtension(target).Equals(".exe", StringComparison.OrdinalIgnoreCase)) return (target, Array.Empty<string>());

        var beside = Path.Combine(folder, "node.exe");
        var node = File.Exists(beside) ? beside : Find("node");
        if (node == null || !node.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) throw new AiFailure(NativeCore.Tr("doc.aiNeedNode"));
        return (node, new[] { target });
    }
}

/// <summary>
/// Runs one CLI request. A job holds the CLI and everything it starts, so stopping a request stops
/// all of it, and a descendant keeping a pipe open cannot hold the request. It also ends with the
/// app if the app is killed. A CLI the author started in a terminal is never in the job.
/// </summary>
static class AiProcess
{
    const int MaxOutputBytes = 4 * 1024 * 1024;

    public static async Task<AiOutput> RunAsync(string executable, IEnumerable<string> arguments, string input, string directory, TimeSpan timeout,
        IReadOnlyDictionary<string, string> environment, IEnumerable<string> removedEnvironment, AiExchange? exchange, CancellationToken cancel)
    {
        cancel.ThrowIfCancellationRequested();
        var (file, prefix) = AiExecutable.Resolve(executable);
        var start = new ProcessStartInfo(file)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = directory,
        };
        foreach (var argument in prefix.Concat(arguments)) start.ArgumentList.Add(argument);
        start.Environment["PATH"] = Path.GetDirectoryName(file) + ";" + AiExecutable.SearchPath();
        foreach (var (key, value) in environment) start.Environment[key] = value;
        foreach (var key in removedEnvironment) start.Environment.Remove(key);

        using var job = new ProcessJob();
        using var process = new Process { StartInfo = start };
        try
        {
            process.Start();
        }
        catch (System.ComponentModel.Win32Exception error)
        {
            throw new AiFailure(NativeCore.Tr("ai.versionFailed") + "\n" + error.Message);
        }
        job.Add(process);

        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        var exceeded = false;
        var complete = new TaskCompletionSource();
        var stdout = new MemoryStream();
        var stderr = new MemoryStream();

        async Task ReadAsync(Stream source, MemoryStream target, bool lines)
        {
            var buffer = new byte[8192];
            var processed = 0;
            while (true)
            {
                var count = await source.ReadAsync(buffer, stop.Token).ConfigureAwait(false);
                if (count <= 0) return;
                if (target.Length + count > MaxOutputBytes)
                {
                    exceeded = true;
                    stop.Cancel();
                    return;
                }
                target.Write(buffer, 0, count);
                if (!lines || exchange == null) continue;
                var bytes = target.GetBuffer();
                for (var index = processed; index < target.Length; index++)
                {
                    if (bytes[index] != (byte)'\n') continue;
                    var reply = exchange.Receive(Encoding.UTF8.GetString(bytes, processed, index - processed).TrimEnd('\r'));
                    processed = index + 1;
                    if (reply != null)
                    {
                        await WriteAsync(process.StandardInput.BaseStream, reply, stop.Token).ConfigureAwait(false);
                    }
                    if (exchange.IsComplete)
                    {
                        complete.TrySetResult();
                        return;
                    }
                }
            }
        }

        var reading = Task.WhenAll(
            ReadAsync(process.StandardOutput.BaseStream, stdout, lines: true),
            ReadAsync(process.StandardError.BaseStream, stderr, lines: false));
        var writing = WriteInputAsync(process, exchange != null ? exchange.Initial : input, closeAfter: exchange == null, stop.Token);

        using var timer = new CancellationTokenSource(timeout);
        var cancelled = new TaskCompletionSource();
        using var onCancel = cancel.Register(() => cancelled.TrySetResult());
        using var onTimeout = timer.Token.Register(() => cancelled.TrySetResult());
        using var onStop = stop.Token.Register(() => cancelled.TrySetResult());
        await Task.WhenAny(process.WaitForExitAsync(CancellationToken.None), complete.Task, cancelled.Task).ConfigureAwait(false);

        var exited = process.HasExited;
        if (exited && !stop.IsCancellationRequested)
        {
            // Normally the output ends right after the process. A descendant may keep the pipe open.
            await Task.WhenAny(reading, Task.Delay(500, CancellationToken.None)).ConfigureAwait(false);
        }
        job.Terminate();
        stop.Cancel();
        await IgnoreFailures(Task.WhenAny(Task.WhenAll(reading, writing), Task.Delay(1000, CancellationToken.None))).ConfigureAwait(false);

        if (cancel.IsCancellationRequested) throw new AiFailure(NativeCore.Tr("ai.cancelled"));
        if (exceeded) throw new AiFailure(NativeCore.Tr("ai.outputTooLarge"));
        if (timer.IsCancellationRequested && !exited && !complete.Task.IsCompleted) throw new AiFailure(NativeCore.Tr("ai.timeout"));

        var status = 0;
        if (process.WaitForExit(2000)) status = process.ExitCode;
        return new AiOutput(status, Text(stdout), Text(stderr));
    }

    static string Text(MemoryStream stream) => Encoding.UTF8.GetString(stream.GetBuffer(), 0, (int)stream.Length);

    static async Task IgnoreFailures(Task task)
    {
        try
        {
            await task.ConfigureAwait(false);
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or ObjectDisposedException or InvalidOperationException)
        {
            // The process is gone. Its pipes have nothing left to say.
        }
    }

    static async Task WriteAsync(Stream stream, string text, CancellationToken cancel)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        await stream.WriteAsync(bytes, cancel).ConfigureAwait(false);
        await stream.FlushAsync(cancel).ConfigureAwait(false);
    }

    static async Task WriteInputAsync(Process process, string input, bool closeAfter, CancellationToken cancel)
    {
        try
        {
            await WriteAsync(process.StandardInput.BaseStream, input, cancel).ConfigureAwait(false);
            if (closeAfter) process.StandardInput.Close();
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or ObjectDisposedException or InvalidOperationException)
        {
            // A CLI may exit without reading everything. Its exit status tells the rest.
        }
    }

    sealed class ProcessJob : IDisposable
    {
        const int ExtendedLimitInformation = 9;
        const uint KillOnJobClose = 0x2000;

        [StructLayout(LayoutKind.Sequential)]
        struct BasicLimits
        {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public uint LimitFlags;
            public nuint MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public nuint Affinity;
            public uint PriorityClass, SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct IoCounters
        {
            public ulong A, B, C, D, E, F;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct ExtendedLimits
        {
            public BasicLimits Basic;
            public IoCounters Io;
            public nuint ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", SetLastError = true)] static extern nint CreateJobObjectW(nint attributes, nint name);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(nint job, int kind, ref ExtendedLimits information, uint length);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(nint job, nint process);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateJobObject(nint job, uint exitCode);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(nint handle);

        readonly nint job;

        public ProcessJob()
        {
            job = CreateJobObjectW(0, 0);
            var limits = new ExtendedLimits { Basic = new BasicLimits { LimitFlags = KillOnJobClose } };
            SetInformationJobObject(job, ExtendedLimitInformation, ref limits, (uint)Marshal.SizeOf<ExtendedLimits>());
        }

        public void Add(Process process)
        {
            if (!AssignProcessToJobObject(job, process.Handle)) Trace.TraceWarning("Could not hold the CLI in a job: {0}", Marshal.GetLastWin32Error());
        }

        public void Terminate() => TerminateJobObject(job, 1);

        public void Dispose() => CloseHandle(job);
    }
}

/// <summary>A CLI's control protocol for models and usage. No prompt is sent.</summary>
sealed class AiExchange(string provider) : IDisposable
{
    readonly nint handle = NativeCore.AiMetadataOpen(provider);

    public string Initial => NativeCore.AiMetadataInitial(handle);
    public bool IsComplete { get; private set; }

    public string? Receive(string line)
    {
        var reply = NativeCore.AiMetadataReceive(handle, line, out var complete);
        IsComplete = complete;
        // Control messages are small. Never let a reply block on a full pipe.
        if (reply != null && Encoding.UTF8.GetByteCount(reply) > 4096) throw new IOException("reply too large");
        return reply;
    }

    public string Result() => NativeCore.AiMetadataResult(handle);

    public void Dispose() => NativeCore.AiMetadataClose(handle);
}

sealed record AiAnswer(string Text, int? Tokens);

/// <summary>Requests as the app makes them. Credentials stay with the CLI.</summary>
static class AiService
{
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(120);

    /// <summary>Connections that really answered this session, by provider and file.</summary>
    static readonly HashSet<string> Verified = new(StringComparer.OrdinalIgnoreCase);

    public static string Current => AppSettings.Current.AiProvider;

    static string GrokProfile => Path.Combine(AppSettings.Folder, "GrokCLI");

    static Dictionary<string, string> Environment(string provider, JsonElement shared)
    {
        var result = new Dictionary<string, string>();
        foreach (var item in shared.EnumerateObject()) result[item.Name] = item.Value.GetString() ?? "";
        if (provider == "grok")
        {
            Directory.CreateDirectory(GrokProfile);
            result["GROK_HOME"] = GrokProfile;
        }
        return result;
    }

    /// <summary>Sends one prompt from a private, empty folder, never the author's note folder.</summary>
    public static async Task<AiAnswer> SendAsync(string provider, string prompt, string? model, TimeSpan timeout, CancellationToken cancel)
    {
        var executable = AiExecutable.Locate(provider) ?? throw new AiFailure(NativeCore.Tr("ai.notInstalled"));
        var directory = Path.Combine(Path.GetTempPath(), "JenaNote-AI-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var policy = Path.Combine(directory, "deny-tools.toml");
            var promptFile = Path.Combine(directory, "prompt.txt");
            using var command = JsonDocument.Parse(NativeCore.AiCommand(provider, policy, promptFile, string.IsNullOrWhiteSpace(model) ? null : model));
            var root = command.RootElement;
            File.WriteAllText(policy, root.GetProperty("denyPolicy").GetString());
            var gemini = Path.Combine(directory, ".gemini");
            Directory.CreateDirectory(gemini);
            File.WriteAllText(Path.Combine(gemini, "settings.json"), root.GetProperty("geminiSettings").GetString());
            // Grok reads a prompt file. There is no /dev/stdin here to hand it.
            if (provider == "grok") File.WriteAllText(promptFile, prompt, new UTF8Encoding(false));

            var output = await AiProcess.RunAsync(executable,
                root.GetProperty("arguments").EnumerateArray().Select(item => item.GetString()!).ToList(),
                prompt, directory, timeout, Environment(provider, root.GetProperty("environment")),
                root.GetProperty("removedEnvironment").EnumerateArray().Select(item => item.GetString()!).ToList(),
                null, cancel).ConfigureAwait(false);

            using var answer = JsonDocument.Parse(NativeCore.AiAnswer(provider, output.Status, output.Stdout, output.Stderr));
            var tokens = answer.RootElement.TryGetProperty("tokens", out var used) ? used.GetInt32() : (int?)null;
            if (answer.RootElement.TryGetProperty("error", out var failure))
                throw new AiFailureWithTokens(failure.GetString() ?? "", tokens);
            return new AiAnswer(answer.RootElement.GetProperty("text").GetString() ?? "", tokens);
        }
        finally
        {
            await RemoveFolderAsync(directory).ConfigureAwait(false);
        }
    }

    /// <summary>A killed process keeps the folder for a moment, and Grok's copy of the prompt is in it.</summary>
    static async Task RemoveFolderAsync(string directory)
    {
        for (var attempt = 0; attempt < 40; attempt++)
        {
            try
            {
                Directory.Delete(directory, recursive: true);
                return;
            }
            catch (DirectoryNotFoundException)
            {
                return;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                if (attempt == 39) Trace.TraceWarning("Could not remove the request folder: {0}", error.Message);
            }
            await Task.Delay(100).ConfigureAwait(false);
        }
    }

    public static async Task<string> LoadMetadataAsync(string provider, CancellationToken cancel)
    {
        var executable = AiExecutable.Locate(provider) ?? throw new AiFailure(NativeCore.Tr("ai.notInstalled"));
        var folder = Path.GetTempPath();
        if (provider == "grok")
        {
            var output = await AiProcess.RunAsync(executable, new[] { "models" }, "", folder, TimeSpan.FromSeconds(15),
                Environment(provider, EmptyEnvironment()), Array.Empty<string>(), null, cancel).ConfigureAwait(false);
            return NativeCore.AiMetadataPlain(provider, output.Status == 0 ? output.Stdout : "");
        }
        if (provider != "claude" && provider != "codex") return NativeCore.AiMetadataPlain(provider, "");

        using var exchange = new AiExchange(provider);
        var result = await AiProcess.RunAsync(executable, NativeCore.AiMetadataArguments(provider), "", folder, TimeSpan.FromSeconds(25),
            Environment(provider, EmptyEnvironment()), new[] { "CLAUDECODE" }, exchange, cancel).ConfigureAwait(false);
        if (!exchange.IsComplete) throw new AiFailure(NativeCore.Tr("ai.metadataUnavailable"));
        return exchange.Result();
    }

    static JsonElement EmptyEnvironment() => JsonDocument.Parse("{}").RootElement;

    /// <summary>Asks for a version, then for a real answer without any document.</summary>
    public static async Task<(bool Connected, string Message)> CheckAsync(string provider, CancellationToken cancel)
    {
        var executable = AiExecutable.Locate(provider) ?? throw new AiFailure(NativeCore.Tr("ai.notInstalled"));
        var key = provider + ":" + executable;
        Verified.Remove(key);
        var version = await AiProcess.RunAsync(executable, new[] { "--version" }, "", Path.GetTempPath(), TimeSpan.FromSeconds(15),
            Environment(provider, EmptyEnvironment()), Array.Empty<string>(), null, cancel).ConfigureAwait(false);
        if (version.Status != 0) return (false, NativeCore.Tr("ai.versionFailed"));
        var answer = await SendAsync(provider, "Reply with exactly JENANOTE_OK. Do not use any tools.", null, DefaultTimeout, cancel).ConfigureAwait(false);
        if (answer.Text.Trim() != "JENANOTE_OK") return (false, NativeCore.Tr("ai.unexpectedProbe"));
        Verified.Add(key);
        return (true, NativeCore.Tr("ai.connected") + "\n" + version.Stdout.Trim());
    }

    public static bool IsVerified(string provider, string executable) => Verified.Contains(provider + ":" + executable);

    /// <summary>A CLI's own installer, or null when no Windows command could be confirmed.</summary>
    public static string? InstallCommand(string provider) => provider switch
    {
        "claude" => "irm https://claude.ai/install.ps1 | iex",
        "codex" => "npm install -g @openai/codex",
        "gemini" => "npm install -g @google/gemini-cli",
        _ => null,
    };

    static string Quote(string value) => "'" + value.Replace("'", "''") + "'";

    /// <summary>Install and login need the author at a terminal, so they get a console of their own.</summary>
    public static void OpenTerminal(string provider, bool install)
    {
        string command;
        if (install)
        {
            command = InstallCommand(provider) ?? throw new AiFailure(NativeCore.Tr("doc.aiNoInstaller"));
            if (command.StartsWith("npm ", StringComparison.Ordinal))
            {
                command = $"if (Get-Command npm -ErrorAction SilentlyContinue) {{ {command} }} else {{ Write-Output {Quote(NativeCore.Tr("doc.aiNeedNode"))}; cmd /c exit 1 }}";
            }
        }
        else
        {
            var executable = AiExecutable.Locate(provider) ?? throw new AiFailure(NativeCore.Tr("ai.notInstalled"));
            using var providers = JsonDocument.Parse(NativeCore.AiProviders());
            var login = providers.RootElement.EnumerateArray().First(item => item.GetProperty("id").GetString() == provider)
                .GetProperty("loginArguments").EnumerateArray().Select(item => Quote(item.GetString()!));
            command = "& " + Quote(executable) + " " + string.Join(' ', login);
        }

        var folder = Path.Combine(Path.GetTempPath(), "JenaNote-CLI-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        if (provider == "grok" && !install) Directory.CreateDirectory(GrokProfile);
        var script = new StringBuilder();
        script.AppendLine("$env:Path = " + Quote(AiExecutable.SearchPath()));
        if (provider == "grok" && !install) script.AppendLine("$env:GROK_HOME = " + Quote(GrokProfile));
        script.AppendLine("Set-Location " + Quote(folder));
        script.AppendLine("Write-Output " + Quote("JenaNote - " + provider));
        script.AppendLine(command);
        script.AppendLine("if ($?) { Write-Output " + Quote(NativeCore.Tr("ai.terminalDone")) + " } else { Write-Output " + Quote(NativeCore.Tr("ai.terminalFailed")) + " }");
        script.AppendLine("Write-Output " + Quote(NativeCore.Tr("ai.terminalReturn")));
        var path = Path.Combine(folder, (install ? "Install-" : "Login-") + provider + ".ps1");
        // Windows PowerShell reads a script without a BOM as the system code page.
        File.WriteAllText(path, script.ToString(), new UTF8Encoding(true));
        Process.Start(new ProcessStartInfo("powershell.exe")
        {
            UseShellExecute = true,
            ArgumentList = { "-NoExit", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", path },
        });
    }
}

/// <summary>An unusable answer that still cost tokens.</summary>
sealed class AiFailureWithTokens(string message, int? tokens) : Exception(message)
{
    public int? Tokens { get; } = tokens;
}

/// <summary>The AI panel's requests from one page. Each document's request runs on its own.</summary>
sealed class AiChatHost(EditorView view)
{
    readonly Dictionary<int, CancellationTokenSource> running = new();
    CancellationTokenSource? metadata;

    public void Handle(string type, JsonElement message)
    {
        switch (type)
        {
            case "aiSend":
                _ = SendAsync(message);
                break;
            case "aiCancel":
                if (running.Remove(message.GetProperty("id").GetInt32(), out var request)) request.Cancel();
                break;
            case "aiMetadata":
                _ = LoadMetadataAsync(message.GetProperty("id").GetInt32());
                break;
            case "aiWorkRefresh":
                SendWorkStatus();
                break;
        }
    }

    int workStatusRequest;

    /// <summary>
    /// Tells the panel what the row under the document name should say. A long work's index can take
    /// seconds to read the first time, so this never runs on the UI thread.
    /// </summary>
    public async void SendWorkStatus()
    {
        var request = ++workStatusRequest;
        var path = view.DocumentPath;
        if (path == null)
        {
            view.Post(new { type = "aiWork", kind = "unsaved" });
            return;
        }
        try
        {
            var json = await Task.Run(() => NativeCore.WorkStatus(path));
            // The author moved on to another document, or the status was asked for again.
            if (request != workStatusRequest) return;
            using var status = JsonDocument.Parse(json);
            var root = status.RootElement;
            var kind = root.GetProperty("kind").GetString();
            var running = WorkIndex.IsRunning(path);
            var text = running ? NativeCore.Tr("ai.index.waiting")
                : WorkIndex.LastError is { } failed && kind == "indexed" ? NativeCore.Tr("ai.index.failed") + " " + failed
                : root.TryGetProperty("text", out var said) ? said.GetString() : null;
            view.Post(new { type = "aiWork", kind, text, running, failed = !running && WorkIndex.LastError != null && kind == "indexed" });
        }
        catch (InvalidOperationException error)
        {
            Trace.TraceWarning("Could not read the work status: {0}", error.Message);
        }
    }

    public void CancelAll()
    {
        foreach (var request in running.Values) request.Cancel();
        running.Clear();
        metadata?.Cancel();
    }

    /// <summary>
    /// A document in a work first gathers what it needs from the work: the app searches, the CLI only
    /// chooses. Null means this is not a work-aware request. Spent tokens count even if this fails.
    /// </summary>
    async Task<(string Prompt, string[] Consulted)?> PrepareWorkAsync(JsonElement message, int id, string provider, string? model, Action<int> spent, CancellationToken cancel)
    {
        var path = view.DocumentPath;
        if (path == null) return null;
        using var status = JsonDocument.Parse(await Task.Run(() => NativeCore.WorkStatus(path), cancel));
        if (status.RootElement.GetProperty("kind").GetString() != "indexed") return null;

        view.Post(new { type = "aiProgress", id, text = NativeCore.Tr("ai.index.waiting") });
        var open = await EditorWindow.OpenDocumentTextsAsync();
        var request = JsonNode.Parse(message.GetRawText())!.AsObject();
        request["path"] = path;
        request["open"] = JsonSerializer.SerializeToNode(open);
        var requestJson = request.ToJsonString();
        var handle = await Task.Run(() => NativeCore.WorkSessionOpen(requestJson), cancel);
        if (handle == IntPtr.Zero) return null;
        try
        {
            view.Post(new { type = "aiProgress", id, text = NativeCore.Tr("ai.index.searching") });
            using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancel);
            limit.CancelAfter(TimeSpan.FromSeconds(240));
            var step = await Task.Run(() => NativeCore.WorkSessionStart(handle), cancel);
            while (true)
            {
                using var current = JsonDocument.Parse(step);
                if (!current.RootElement.TryGetProperty("prompt", out var ask)) break;
                AiAnswer answer;
                try
                {
                    answer = await AiService.SendAsync(provider, ask.GetString()!, model, AiService.DefaultTimeout, limit.Token);
                }
                catch (AiFailure) when (limit.IsCancellationRequested && !cancel.IsCancellationRequested)
                {
                    throw new AiFailure(NativeCore.Tr("ai.timeout"));
                }
                spent(answer.Tokens ?? 0);
                var text = answer.Text;
                step = await Task.Run(() => NativeCore.WorkSessionReceive(handle, text), cancel);
            }
            using var final = JsonDocument.Parse(NativeCore.WorkSessionPrompt(handle, requestJson));
            return (final.RootElement.GetProperty("prompt").GetString()!,
                final.RootElement.GetProperty("consulted").EnumerateArray().Select(item => item.GetString()!).ToArray());
        }
        finally
        {
            NativeCore.WorkSessionClose(handle);
        }
    }

    async Task SendAsync(JsonElement message)
    {
        var id = message.GetProperty("id").GetInt32();
        var edit = message.GetProperty("mode").GetString() == "edit";
        var cancel = new CancellationTokenSource();
        running[id] = cancel;
        var provider = AiService.Current;
        var model = AppSettings.Current.AiModels.GetValueOrDefault(provider);
        var searchTokens = 0;
        string prompt;
        string[] consulted = Array.Empty<string>();
        try
        {
            var work = await PrepareWorkAsync(message, id, provider, model, used => searchTokens += used, cancel.Token);
            if (work != null) (prompt, consulted) = work.Value;
            else prompt = NativeCore.AiPrompt(message.GetRawText());
        }
        catch (Exception error) when (error is AiFailure or AiFailureWithTokens or InvalidOperationException or IOException or UnauthorizedAccessException or OperationCanceledException)
        {
            // The real request never went out, so the question goes back to the author.
            if (running.Remove(id))
            {
                var text = error is OperationCanceledException ? NativeCore.Tr("ai.cancelled") : error.Message;
                view.Post(new { type = "aiResult", id, provider, tokens = searchTokens, promptFailed = true, error = text });
            }
            return;
        }
        if (!running.ContainsKey(id)) return;
        var consultedJson = JsonSerializer.Serialize(consulted);

        try
        {
            var answer = await AiService.SendAsync(provider, prompt, model, AiService.DefaultTimeout, cancel.Token);
            answer = answer with { Tokens = (answer.Tokens ?? 0) + searchTokens };
            if (!running.Remove(id)) return;
            if (!edit)
            {
                view.PostRaw($"{{\"type\":\"aiResult\",\"id\":{id},\"provider\":{JsonSerializer.Serialize(provider)},\"tokens\":{Json(answer.Tokens)},\"consulted\":{consultedJson},\"text\":{JsonSerializer.Serialize(answer.Text)},\"blocks\":{Blocks(answer.Text)}}}");
                return;
            }
            string parsed;
            try
            {
                parsed = NativeCore.AiParseEdit(answer.Text);
            }
            catch (InvalidOperationException error)
            {
                // The raw answer stays visible, as the author may still want what it says.
                view.Post(new { type = "aiResult", id, provider, tokens = answer.Tokens, consulted, error = error.Message + "\n\n" + answer.Text });
                return;
            }
            using var document = JsonDocument.Parse(parsed);
            var explanation = document.RootElement.GetProperty("explanation").GetString() ?? "";
            view.PostRaw($"{{\"type\":\"aiResult\",\"id\":{id},\"provider\":{JsonSerializer.Serialize(provider)},\"tokens\":{Json(answer.Tokens)},\"consulted\":{consultedJson},\"text\":{JsonSerializer.Serialize(explanation)},\"blocks\":{Blocks(explanation)},\"replacement\":{document.RootElement.GetProperty("replacement").GetRawText()},\"raw\":{JsonSerializer.Serialize(answer.Text)}}}");
        }
        catch (AiFailureWithTokens error)
        {
            if (running.Remove(id)) view.Post(new { type = "aiResult", id, provider, tokens = (error.Tokens ?? 0) + searchTokens, error = error.Message });
        }
        catch (Exception error) when (error is AiFailure or IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            if (running.Remove(id)) view.Post(new { type = "aiResult", id, provider, tokens = searchTokens, error = error.Message });
        }
    }

    static string Json(int? value) => value?.ToString() ?? "null";

    static string Blocks(string text)
    {
        try
        {
            return NativeCore.MarkdownToJson(text);
        }
        catch (InvalidOperationException)
        {
            return "null";
        }
    }

    async Task LoadMetadataAsync(int id)
    {
        metadata?.Cancel();
        var cancel = metadata = new CancellationTokenSource();
        var provider = AiService.Current;
        try
        {
            var loaded = await AiService.LoadMetadataAsync(provider, cancel.Token);
            if (!cancel.IsCancellationRequested) view.PostRaw($"{{\"type\":\"aiMetadataResult\",\"id\":{id},\"provider\":{JsonSerializer.Serialize(provider)},\"metadata\":{loaded}}}");
        }
        catch (Exception error) when (error is AiFailure or IOException or UnauthorizedAccessException or InvalidOperationException or JsonException)
        {
            // Unknown usage stays unknown. The chat itself still works.
            if (!cancel.IsCancellationRequested) view.Post(new { type = "aiMetadataResult", id, provider, failed = true });
        }
    }
}
