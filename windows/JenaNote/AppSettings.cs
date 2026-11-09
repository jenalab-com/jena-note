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
    public List<string> SidebarFolders { get; set; } = new();
    public HashSet<string> SidebarExpanded { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public string SidebarSortKey { get; set; } = "name";
    public bool SidebarAscending { get; set; } = true;
    public bool SidebarVisible { get; set; } = true;
    public double SidebarWidth { get; set; } = 240;
    public string ReadingMode { get; set; } = "scroll";
    public double ReadingFontScale { get; set; } = 1.3;
    public string ReadingFont { get; set; } = "serif";
    public string ReadingWeight { get; set; } = "regular";
    public double ReadingLineSpacing { get; set; } = 1.5;
    public int ReadingLineLength { get; set; } = 35;
    public double ReadingPageWidth { get; set; }
    public double ReadingMarginLeft { get; set; }
    public double ReadingMarginRight { get; set; }
    public string PaperSize { get; set; } = "automatic";
    public string AiProvider { get; set; } = "claude";
    /// <summary>Executable chosen by hand, by provider. Credentials stay with each CLI.</summary>
    public Dictionary<string, string> AiPaths { get; set; } = new();
    public Dictionary<string, string> AiModels { get; set; } = new();
    /// <summary>Where the local (llama.cpp) server listens.</summary>
    public string AiLocalAddress { get; set; } = LocalAi.DefaultAddress;
    /// <summary>Marks by kind: "dialogue", "quotation" and "thought".</summary>
    public Dictionary<string, PunctuationStyle> Punctuation { get; set; } = new();
    public bool PunctuationTriggersEnabled { get; set; }
    public bool PunctuationClosesOnReturn { get; set; }
    /// <summary>The kind that double Shift toggles, or null when it is off.</summary>
    public string? PunctuationShiftTarget { get; set; }

    /// <summary>The style for a kind, adding the default when settings were never saved.</summary>
    public PunctuationStyle PunctuationFor(string kind)
    {
        Punctuation ??= new Dictionary<string, PunctuationStyle>();
        if (!Punctuation.TryGetValue(kind, out var style) || style == null) Punctuation[kind] = style = DefaultPunctuation(kind);
        return style;
    }

    public static readonly string[] PunctuationKinds = { "dialogue", "quotation", "thought" };
    public const int MaxLeadingSpaces = 2;

    /// <summary>Each author sets their own marks. These match the macOS defaults.</summary>
    public static PunctuationStyle DefaultPunctuation(string kind) => kind switch
    {
        "dialogue" => new PunctuationStyle { Opening = "\"", Closing = "\"", Trigger = ";;;" },
        "quotation" => new PunctuationStyle { Opening = "'", Closing = "'", Trigger = "'''" },
        _ => new PunctuationStyle { Opening = "'", Closing = "'", Trigger = "///" },
    };

    public static string Folder { get; set; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "JenaNote");

    static string FilePath => Path.Combine(Folder, "settings.json");

    public static AppSettings Current { get; private set; } = new();

    /// <summary>Raised after settings change, so every open window can follow at once.</summary>
    public static event Action? Changed;

    public static void Load()
    {
        ReadingStore.Unload();
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
        SaveQuietly();
        Changed?.Invoke();
    }

    /// <summary>Raised after a punctuation setting changes. Windows only pass it to their page.</summary>
    public static event Action? PunctuationChanged;

    /// <summary>
    /// Saves a punctuation change, typed one character at a time in the settings window, without
    /// rebuilding the menus and the page layout of every window as `Update` does.
    /// </summary>
    public static void UpdatePunctuation(Action<AppSettings> change)
    {
        change(Current);
        Current.Normalized();
        SaveQuietly();
        PunctuationChanged?.Invoke();
    }

    /// <summary>A change made in the page. Only the named values change, and only known names count.</summary>
    public static void ApplyFromPage(JsonElement values)
    {
        Update(settings =>
        {
            foreach (var value in values.EnumerateObject())
            {
                switch (value.Name)
                {
                    case "mode": settings.ReadingMode = value.Value.GetString() ?? "scroll"; break;
                    case "fontScale": settings.ReadingFontScale = value.Value.GetDouble(); break;
                    case "font": settings.ReadingFont = value.Value.GetString() ?? "serif"; break;
                    case "weight": settings.ReadingWeight = value.Value.GetString() ?? "regular"; break;
                    case "lineSpacing": settings.ReadingLineSpacing = value.Value.GetDouble(); break;
                    case "pageWidth": settings.ReadingPageWidth = value.Value.GetDouble(); break;
                    case "marginLeft": settings.ReadingMarginLeft = value.Value.GetDouble(); break;
                    case "marginRight": settings.ReadingMarginRight = value.Value.GetDouble(); break;
                    case "paper": settings.PaperSize = value.Value.GetString() ?? "automatic"; break;
                    case "bodySize": settings.BodySize = value.Value.GetDouble(); break;
                    case "letterSpacing": settings.LetterSpacing = value.Value.GetDouble(); break;
                    case "aiModel": settings.AiModels[settings.AiProvider] = (value.Value.GetString() ?? "").Trim(); break;
                }
            }
        });
    }

    /// <summary>Saves small state, like which folders are open, without refreshing any window.</summary>
    public static void SaveQuietly()
    {
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
    }

    /// <summary>Brings every value inside what the app can use.</summary>
    public AppSettings Normalized()
    {
        if (!NativeCore.LanguageCodes().Contains(Language)) Language = "ko";
        if (!AutosaveIntervals.Contains(AutosaveSeconds)) AutosaveSeconds = 60;
        if (!ColorModes.Contains(ColorMode)) ColorMode = "system";
        if (PaperColor != null && !HexColor().IsMatch(PaperColor)) PaperColor = null;
        BodySize = ClampNumber(BodySize, MinBodySize, MaxBodySize, NativeCore.DefaultBodySize);
        SidebarFolders ??= new List<string>();
        SidebarExpanded = new HashSet<string>(SidebarExpanded ?? new HashSet<string>(), StringComparer.OrdinalIgnoreCase);
        if (SidebarSortKey != "date") SidebarSortKey = "name";
        SidebarWidth = ClampNumber(SidebarWidth, 140, 600, 240);
        if (ReadingMode != "paged") ReadingMode = "scroll";
        // The display zoom moves in tens of percents, as on macOS.
        ReadingFontScale = Math.Round(ClampNumber(ReadingFontScale, 0.8, 2, 1.3), 1);
        ReadingFont ??= "serif";
        if (ReadingWeight is not ("light" or "regular" or "bold")) ReadingWeight = "regular";
        ReadingLineSpacing = ClampNumber(ReadingLineSpacing, 1, 2.5, 1.5);
        if (ReadingLineLength <= 0) ReadingLineLength = 35;
        ReadingPageWidth = ClampNumber(ReadingPageWidth, 0, 5000, 0);
        ReadingMarginLeft = ClampNumber(ReadingMarginLeft, 0, 5000, 0);
        ReadingMarginRight = ClampNumber(ReadingMarginRight, 0, 5000, 0);
        if (PaperSize == null || !ReadingFaces.IsPaper(PaperSize)) PaperSize = "automatic";
        if (AiProvider is not ("claude" or "codex" or "gemini" or "grok" or "local")) AiProvider = "claude";
        AiLocalAddress = string.IsNullOrWhiteSpace(AiLocalAddress) ? LocalAi.DefaultAddress : AiLocalAddress.Trim();
        AiPaths ??= new Dictionary<string, string>();
        AiModels ??= new Dictionary<string, string>();
        var punctuation = Punctuation ?? new Dictionary<string, PunctuationStyle>();
        Punctuation = PunctuationKinds.ToDictionary(kind => kind, kind =>
        {
            if (!punctuation.TryGetValue(kind, out var style) || style == null) return DefaultPunctuation(kind);
            style.Opening ??= "";
            style.Closing ??= "";
            style.Trigger ??= "";
            style.LeadingSpaces = Math.Clamp(style.LeadingSpaces, 0, MaxLeadingSpaces);
            return style;
        });
        if (PunctuationShiftTarget != null && !PunctuationKinds.Contains(PunctuationShiftTarget)) PunctuationShiftTarget = null;
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
        Palette.Apply();
    }
}

/// <summary>One kind of mark. With no closing mark, turning it off inserts nothing, as with a dash.</summary>
sealed class PunctuationStyle
{
    public string Opening { get; set; } = "";
    public string Closing { get; set; } = "";
    /// <summary>Spaces before the opening mark only, from 0 to 2.</summary>
    public int LeadingSpaces { get; set; }
    /// <summary>Characters that toggle the mark when typed. Fewer than two do nothing.</summary>
    public string Trigger { get; set; } = "";
}
