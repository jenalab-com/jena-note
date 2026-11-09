using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using Microsoft.Win32;

namespace JenaNote;

/// <summary>
/// The window's own colors, matched to the editor page (editor.css) so the toolbar, sidebar and
/// status bar read as one surface. Controls refer to them by resource key, so a change of color
/// mode reaches every open window at once.
/// </summary>
static class Palette
{
    public const string Bar = "Jena.Bar";
    public const string Sidebar = "Jena.Sidebar";
    public const string Line = "Jena.Line";
    public const string Muted = "Jena.Muted";
    public const string Hover = "Jena.Hover";
    public const string Field = "Jena.Field";
    /// <summary>Segoe Fluent Icons ships with Windows 11. Windows 10 has the same glyphs in MDL2.</summary>
    public static readonly FontFamily Icons = new("Segoe Fluent Icons, Segoe MDL2 Assets");

    static bool listening;

    public static bool IsDark => AppSettings.Current.ColorMode switch
    {
        "dark" => true,
        "light" => false,
        _ => SystemIsDark(),
    };

    static bool SystemIsDark() =>
        Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1) is int light && light == 0;

    public static void Apply()
    {
        if (Application.Current == null) return;
        var dark = IsDark;
        var resources = Application.Current.Resources;
        resources[Bar] = Brush(dark ? "#252527" : "#F7F7F8");
        resources[Sidebar] = Brush(dark ? "#202022" : "#F0F0F2");
        resources[Line] = Brush(dark ? "#3A3A3D" : "#E1E1E3");
        resources[Muted] = Brush(dark ? "#A1A1A6" : "#6E6E73");
        resources[Hover] = Brush(dark ? "#333336" : "#E4E4E7");
        resources[Field] = Brush(dark ? "#2B2B2E" : "#FFFFFF");
        foreach (Window window in Application.Current.Windows) PaintTitleBar(window);
        if (listening) return;
        listening = true;
        // Settings, history and the other windows get the same title bar as they open.
        EventManager.RegisterClassHandler(typeof(Window), FrameworkElement.LoadedEvent, new RoutedEventHandler((sender, _) => PaintTitleBar((Window)sender)));
        // Following the system means following it while the app runs, too.
        SystemEvents.UserPreferenceChanged += (_, e) =>
        {
            if (e.Category == UserPreferenceCategory.General) Application.Current?.Dispatcher.BeginInvoke(Apply);
        };
    }

    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(nint window, int attribute, ref int value, int size);
    const int UseImmersiveDarkMode = 20;
    const int CaptionColor = 35;
    const int TextColor = 36;

    /// <summary>
    /// Gives the title bar the toolbar's color, so the window reads as one surface. Windows 10
    /// ignores the colors and keeps its own title bar.
    /// </summary>
    public static void PaintTitleBar(Window window)
    {
        var handle = new WindowInteropHelper(window).Handle;
        if (handle == 0)
        {
            window.SourceInitialized -= Paint;
            window.SourceInitialized += Paint;
            return;
        }
        var dark = IsDark ? 1 : 0;
        DwmSetWindowAttribute(handle, UseImmersiveDarkMode, ref dark, sizeof(int));
        var caption = IsDark ? 0x00272525 : 0x00F8F7F7;
        DwmSetWindowAttribute(handle, CaptionColor, ref caption, sizeof(int));
        var text = IsDark ? 0x00F7F5F5 : 0x001F1D1D;
        DwmSetWindowAttribute(handle, TextColor, ref text, sizeof(int));
    }

    static void Paint(object? sender, EventArgs e)
    {
        if (sender is Window window) PaintTitleBar(window);
    }

    static SolidColorBrush Brush(string hex)
    {
        var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
        brush.Freeze();
        return brush;
    }

    /// <summary>A flat button showing one icon glyph, as in Windows 11's own toolbars.</summary>
    public static Button IconButton(string glyph, string tooltip, RoutedEventHandler click)
    {
        var button = new Button
        {
            Content = new TextBlock { Text = glyph, FontFamily = Icons, FontSize = 14 },
            ToolTip = tooltip,
            Width = 28,
            Height = 28,
            Padding = new Thickness(0),
            Margin = new Thickness(1, 0, 0, 0),
            BorderThickness = new Thickness(0),
            Background = Brushes.Transparent,
            Cursor = System.Windows.Input.Cursors.Arrow,
        };
        System.Windows.Automation.AutomationProperties.SetName(button, tooltip);
        button.Click += click;
        return button;
    }
}
