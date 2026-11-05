using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;

namespace JenaSpike;

// Same document and same report format for every candidate.
public static class TestDoc
{
    static readonly string[] Sentences =
    {
        "그제야 리에느가 빵을 받아 들고 조용히 고개를 끄덕였다. ",
        "창밖으로 내리는 비는 멈출 기미가 보이지 않았고, 거리의 불빛은 물에 번져 흔들렸다. ",
        "서준은 오래된 편지를 다시 펼쳐 첫 문장부터 천천히 읽어 내려갔다. ",
        "\"정말로 그렇게 생각해?\" 하연이 낮은 목소리로 물었다. ",
        "아무도 대답하지 않았지만, 방 안의 공기는 이미 조금 달라져 있었다. ",
    };

    /// Paragraphs of about 300 characters until the total reaches targetChars.
    public static List<string> Paragraphs(int targetChars)
    {
        var result = new List<string>();
        var total = 0;
        var index = 0;
        while (total < targetChars)
        {
            var paragraph = new StringBuilder();
            while (paragraph.Length < 300) paragraph.Append(Sentences[index++ % Sentences.Length]);
            result.Add(paragraph.ToString());
            total += paragraph.Length;
        }
        return result;
    }
}

public sealed class Report
{
    public string Candidate { get; set; } = "";
    public int Chars { get; set; }
    public int ParagraphCount { get; set; }
    public Dictionary<string, object?> Results { get; } = new();

    public void Add(string name, object? value)
    {
        Results[name] = value;
        Console.WriteLine($"{name}: {value}");
    }

    public void Save(string path) =>
        File.WriteAllText(path, JsonSerializer.Serialize(this, new JsonSerializerOptions
        {
            WriteIndented = true,
            Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        }));
}

public sealed record SpikeArgs(int Chars, string? OutputPath)
{
    /// --chars N sets the size. --out FILE runs the measurements, saves and exits.
    public static SpikeArgs Parse(string[] args)
    {
        var chars = 100_000;
        string? output = null;
        for (var i = 0; i + 1 < args.Length; i++)
        {
            if (args[i] == "--chars") chars = int.Parse(args[i + 1]);
            if (args[i] == "--out") output = args[i + 1];
        }
        return new SpikeArgs(chars, output);
    }
}

public static class Timing
{
    public static double Median(List<double> values)
    {
        var sorted = values.OrderBy(v => v).ToList();
        return Math.Round(sorted[sorted.Count / 2], 2);
    }

    public static double Ms(Stopwatch watch) => Math.Round(watch.Elapsed.TotalMilliseconds, 1);

    public static double WorkingSetMb()
    {
        using var process = Process.GetCurrentProcess();
        process.Refresh();
        return Math.Round(process.WorkingSet64 / 1048576.0, 1);
    }
}
