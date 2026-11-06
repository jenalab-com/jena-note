using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows;

namespace JenaNote;

/// <summary>User preferences, with the same choices and limits as the macOS settings.</summary>
sealed partial class AppSettings
{
    public static readonly int[] AutosaveIntervals = { 30, 60, 180, 300, 600 };
    public const double MinBodySize = 8;
    public const double MaxBodySize = 30;
    public const double MinLetterSpacing = -10;
    public const double MaxLetterSpacing = 20;
    static readonly string[] ColorModes = { "system", "light", "dark" };

    public string Language { get; set; } = "ko";
    public bool AutosaveEnabled { get; set; } = true;
    public int AutosaveSeconds { get; set; } = 60;
    public string ColorMode { get; set; } = "system";
    /// <summary>"#RRGGBB", or null for the standard background of the color mode.</summary>
    public string? PaperColor { get; set; }
    public double BodySize { get; set; } = NativeCore.DefaultBodySize;
    public double LetterSpacing { get; set; }

    public static string Folder { get; set; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "JenaNote");

    static string FilePath => Path.Combine(Folder, "settings.json");

    public static AppSettings Current { get; private set; } = new();

    /// <summary>Raised after settings change, so every open window can follow at once.</summary>
    public static event Action? Changed;

    public static void Load()
    {
        Current = Read(FilePath);
        ApplyToApp();
    }

    /// <summary>A missing or damaged file falls back to the defaults. Settings must not stop the app.</summary>
    public static AppSettings Read(string path)
    {
        try
        {
            if (File.Exists(path))
                return (JsonSerializer.Deserialize<AppSettings>(File.ReadAllBytes(path)) ?? new AppSettings()).Normalized();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            Trace.TraceWarning("Settings ignored: {0}", error.Message);
        }
        return new AppSettings();
    }

    /// <summary>Applies a change, saves it and tells every window.</summary>
    public static void Update(Action<AppSettings> change)
    {
        change(Current);
        Current.Normalized();
        ApplyToApp();
        try
        {
            Directory.CreateDirectory(Folder);
            DocumentFile.Write(FilePath, JsonSerializer.Serialize(Current, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // The change still applies to this session.
            Trace.TraceWarning("Settings not saved: {0}", error.Message);
        }
        Changed?.Invoke();
    }

    /// <summary>Brings every value inside what the app can use.</summary>
    public AppSettings Normalized()
    {
        if (!NativeCore.LanguageCodes().Contains(Language)) Language = "ko";
        if (!AutosaveIntervals.Contains(AutosaveSeconds)) AutosaveSeconds = 60;
        if (!ColorModes.Contains(ColorMode)) ColorMode = "system";
        if (PaperColor != null && !HexColor().IsMatch(PaperColor)) PaperColor = null;
        BodySize = ClampNumber(BodySize, MinBodySize, MaxBodySize, NativeCore.DefaultBodySize);
        // As on macOS, letter spacing moves in whole percents.
        LetterSpacing = Math.Round(ClampNumber(LetterSpacing, MinLetterSpacing, MaxLetterSpacing, 0));
        return this;
    }

    static double ClampNumber(double value, double minimum, double maximum, double fallback) =>
        double.IsFinite(value) ? Math.Clamp(value, minimum, maximum) : fallback;

    [GeneratedRegex("^#[0-9A-Fa-f]{6}$")]
    private static partial Regex HexColor();

    static void ApplyToApp()
    {
        NativeCore.SetLanguage(Current.Language);
        EditorWindow.AutosaveEnabled = Current.AutosaveEnabled;
        EditorWindow.AutosaveDelay = TimeSpan.FromSeconds(Current.AutosaveSeconds);
        ApplyTheme();
    }

    static void ApplyTheme()
    {
        if (Application.Current == null) return;
#pragma warning disable WPF0001 // ThemeMode is the supported way to follow the Windows dark mode.
        Application.Current.ThemeMode = Current.ColorMode switch
        {
            "light" => ThemeMode.Light,
            "dark" => ThemeMode.Dark,
            _ => ThemeMode.System,
        };
#pragma warning restore WPF0001
    }
}
