using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.IO;
using System.Text;
using System.Text.Json;

namespace JenaNote;

/// <summary>
/// Stands in for a real CLI in the self test, so no test uses an account or the network. The app
/// starts itself with JENANOTE_FAKE_CLI set, and that decides how this copy behaves.
/// </summary>
static class FakeCli
{
    public static int? Run(string[] args)
    {
        var mode = Environment.GetEnvironmentVariable("JENANOTE_FAKE_CLI");
        if (string.IsNullOrEmpty(mode)) return null;

        var output = Console.OpenStandardOutput();
        void Write(string text)
        {
            var bytes = Encoding.UTF8.GetBytes(text);
            output.Write(bytes);
            output.Flush();
        }
        string Result(string text) => JsonSerializer.Serialize(new { result = text, usage = new { input_tokens = 3, output_tokens = 4 } });
        string ReadAll()
        {
            using var reader = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false));
            return reader.ReadToEnd();
        }
        void SpawnSleeper()
        {
            // Inherits the pipes, which is what a CLI launcher's child does.
            var child = Process.Start(new ProcessStartInfo(Environment.ProcessPath!)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                Environment = { ["JENANOTE_FAKE_CLI"] = "sleep" },
            })!;
            File.WriteAllText(Environment.GetEnvironmentVariable("JENANOTE_FAKE_PID")!, child.Id.ToString());
        }

        if (mode == "llamaServer")
        {
            // Loads for a moment, then answers like llama-server, until the test stops it.
            var listener = new TcpListener(IPAddress.Loopback, int.Parse(Environment.GetEnvironmentVariable("PORT") ?? "8080"));
            listener.Start();
            var ready = DateTime.Now.AddSeconds(1);
            Console.Error.WriteLine("fake llama-server listening");
            FakeHttp.Serve(listener, (method, target, body) => target switch
            {
                "/health" => DateTime.Now < ready ? (503, "{\"error\":{\"message\":\"Loading model\"}}") : (200, "{\"status\":\"ok\"}"),
                "/v1/chat/completions" => (200, JsonSerializer.Serialize(new
                {
                    choices = new[] { new { message = new { role = "assistant", content = "LOCAL_OK " + body.Length } } },
                    usage = new { total_tokens = 9 },
                })),
                _ => (404, "{}"),
            }, TimeSpan.FromSeconds(120));
            return 0;
        }
        if (mode == "llamaExit")
        {
            Console.Error.Write("error: failed to load model 'missing.gguf'");
            return 1;
        }
        if (mode == "sleep")
        {
            Thread.Sleep(60_000);
            return 0;
        }
        if (args.Contains("--version"))
        {
            Write("fake 1.0\n");
            return 0;
        }
        switch (mode)
        {
            case "echo":
                Write(Result(ReadAll()));
                return 0;
            case "args":
                ReadAll();
                Write(Result(JsonSerializer.Serialize(args)));
                return 0;
            case "probe":
                ReadAll();
                Write(Result("JENANOTE_OK"));
                return 0;
            case "reply":
                ReadAll();
                Write(Result(Environment.GetEnvironmentVariable("JENANOTE_FAKE_REPLY") ?? ""));
                return 0;
            case "fail":
                ReadAll();
                Console.Error.Write("bad login");
                return 3;
            case "hang":
                Thread.Sleep(60_000);
                return 0;
            case "childHolds":
                // Answers and ends, while a child keeps the output pipe open.
                ReadAll();
                SpawnSleeper();
                Write(Result("done"));
                return 0;
            case "childHangs":
                SpawnSleeper();
                Thread.Sleep(60_000);
                return 0;
            case "flood":
                var chunk = new string('x', 1024 * 1024);
                for (var index = 0; index < 8; index++) Write(chunk);
                Thread.Sleep(60_000);
                return 0;
            case "metadata":
                using (var reader = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false)))
                {
                    while (reader.ReadLine() is { } line)
                    {
                        if (line.Contains("\"initialize\""))
                            Write("{\"type\":\"control_response\",\"response\":{\"request_id\":\"init\",\"response\":{\"models\":[{\"value\":\"opus\",\"displayName\":\"Opus\"}]}}}\n");
                        else if (line.Contains("get_usage"))
                            Write("{\"type\":\"control_response\",\"response\":{\"request_id\":\"usage\",\"response\":{\"rate_limits\":{\"limits\":[{\"group\":\"session\",\"percent\":25}]}}}}\n");
                    }
                }
                return 0;
        }
        return 2;
    }
}

/// <summary>Just enough HTTP for the tests: one request per connection, then the connection closes.</summary>
static class FakeHttp
{
    public static void Serve(TcpListener listener, Func<string, string, string, (int Status, string Json)> handle, TimeSpan lifetime)
    {
        var end = DateTime.Now + lifetime;
        while (DateTime.Now < end)
        {
            TcpClient client;
            try
            {
                client = listener.AcceptTcpClient();
            }
            catch (Exception error) when (error is SocketException or ObjectDisposedException or InvalidOperationException)
            {
                return;
            }
            using (client)
            {
                try
                {
                    Answer(client.GetStream(), handle);
                }
                catch (Exception error) when (error is IOException or SocketException)
                {
                    // The client gave up, for example on a timeout.
                }
            }
        }
    }

    static void Answer(NetworkStream stream, Func<string, string, string, (int Status, string Json)> handle)
    {
        var buffer = new MemoryStream();
        var chunk = new byte[8192];
        int headerEnd;
        while ((headerEnd = IndexOf(buffer, "\r\n\r\n"u8)) < 0)
        {
            var count = stream.Read(chunk);
            if (count <= 0) return;
            buffer.Write(chunk, 0, count);
        }
        var head = Encoding.ASCII.GetString(buffer.GetBuffer(), 0, headerEnd).Split("\r\n");
        var parts = head[0].Split(' ');
        var length = head.Skip(1).Select(line => line.Split(':', 2))
            .Where(pair => pair.Length == 2 && pair[0].Trim().Equals("Content-Length", StringComparison.OrdinalIgnoreCase))
            .Select(pair => int.Parse(pair[1].Trim())).FirstOrDefault();
        while (buffer.Length < headerEnd + 4 + length)
        {
            var count = stream.Read(chunk);
            if (count <= 0) return;
            buffer.Write(chunk, 0, count);
        }
        var body = Encoding.UTF8.GetString(buffer.GetBuffer(), headerEnd + 4, length);
        var (status, json) = handle(parts[0], parts.Length > 1 ? parts[1] : "/", body);
        var payload = Encoding.UTF8.GetBytes(json);
        var header = $"HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {payload.Length}\r\nConnection: close\r\n\r\n";
        stream.Write(Encoding.ASCII.GetBytes(header));
        stream.Write(payload);
        stream.Flush();
    }

    static int IndexOf(MemoryStream stream, ReadOnlySpan<byte> pattern) =>
        stream.GetBuffer().AsSpan(0, (int)stream.Length).IndexOf(pattern);
}
