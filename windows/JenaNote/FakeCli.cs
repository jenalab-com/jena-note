using System.Diagnostics;
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
