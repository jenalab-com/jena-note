using System.Globalization;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Forms = System.Windows.Forms;

namespace JenaNote;

/// <summary>Changes apply as they are made. There is nothing to confirm.</summary>
sealed class SettingsWindow : Window
{
    static SettingsWindow? open;
    bool populating;

    public static SettingsWindow Present(Window owner)
    {
        if (open != null)
        {
            open.Activate();
            return open;
        }
        open = new SettingsWindow { Owner = owner };
        open.Closed += (_, _) => open = null;
        open.Show();
        return open;
    }

    SettingsWindow()
    {
        Width = 560;
        Height = 420;
        MinWidth = 480;
        MinHeight = 360;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Build();
    }

    /// <summary>Everything is rebuilt after a language change, so all text follows it.</summary>
    void Build()
    {
        Title = NativeCore.Tr("settings.title");
        var tabs = new TabControl { Margin = new Thickness(10) };
        tabs.Items.Add(new TabItem { Header = NativeCore.Tr("settings.tab.general"), Content = BuildGeneral() });
        tabs.Items.Add(new TabItem { Header = NativeCore.Tr("settings.tab.ui"), Content = BuildAppearance() });
        Content = tabs;
    }

    static Grid NewForm()
    {
        var form = new Grid { Margin = new Thickness(16) };
        form.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(130) });
        form.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        return form;
    }

    static void AddRow(Grid form, string? label, UIElement control)
    {
        var row = form.RowDefinitions.Count;
        form.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        if (label != null)
        {
            var text = new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 12) };
            Grid.SetRow(text, row);
            form.Children.Add(text);
        }
        if (control is FrameworkElement element) element.Margin = new Thickness(0, 0, 0, 12);
        Grid.SetRow(control, row);
        Grid.SetColumn(control, 1);
        form.Children.Add(control);
    }

    /// <summary>A choice list whose items carry the stored value.</summary>
    ComboBox Choice(IEnumerable<(string Value, string Label)> items, string selected, Action<string> changed)
    {
        var box = new ComboBox { HorizontalAlignment = HorizontalAlignment.Left, MinWidth = 220 };
        populating = true;
        foreach (var (value, label) in items)
        {
            var item = new ComboBoxItem { Content = label, Tag = value };
            box.Items.Add(item);
            if (value == selected) box.SelectedItem = item;
        }
        populating = false;
        box.SelectionChanged += (_, _) =>
        {
            if (!populating && box.SelectedItem is ComboBoxItem { Tag: string value }) changed(value);
        };
        return box;
    }

    UIElement BuildGeneral()
    {
        var settings = AppSettings.Current;
        var form = NewForm();

        using var languages = JsonDocument.Parse(NativeCore.Languages());
        var languageChoices = languages.RootElement.EnumerateArray()
            .Select(item => (item.GetProperty("code").GetString()!, item.GetProperty("name").GetString()!)).ToList();
        AddRow(form, NativeCore.Tr("settings.language"), Choice(languageChoices, settings.Language, code =>
        {
            AppSettings.Update(current => current.Language = code);
            // The list that raised this event is about to be replaced, so wait until it finishes.
            Dispatcher.BeginInvoke(Build);
        }));

        var interval = Choice(AppSettings.AutosaveIntervals.Select(seconds => (seconds.ToString(), NativeCore.Tr($"autosave.seconds.{seconds}"))),
            settings.AutosaveSeconds.ToString(),
            value => AppSettings.Update(current => current.AutosaveSeconds = int.Parse(value, CultureInfo.InvariantCulture)));
        interval.IsEnabled = settings.AutosaveEnabled;

        var enabled = new CheckBox { Content = NativeCore.Tr("autosave.enabled"), IsChecked = settings.AutosaveEnabled };
        enabled.Click += (_, _) =>
        {
            var on = enabled.IsChecked == true;
            interval.IsEnabled = on;
            AppSettings.Update(current => current.AutosaveEnabled = on);
        };
        AddRow(form, null, enabled);
        AddRow(form, NativeCore.Tr("autosave.interval"), interval);
        AddRow(form, null, new TextBlock { Text = NativeCore.Tr("doc.autosaveHint"), TextWrapping = TextWrapping.Wrap, Opacity = 0.7 });
        return form;
    }

    UIElement BuildAppearance()
    {
        var settings = AppSettings.Current;
        var form = NewForm();

        AddRow(form, NativeCore.Tr("settings.colorMode"), Choice(
            new[] { "system", "light", "dark" }.Select(mode => (mode, NativeCore.Tr($"appearance.{mode}"))),
            settings.ColorMode,
            mode => AppSettings.Update(current => current.ColorMode = mode)));

        var swatch = new Border { Width = 28, Height = 22, BorderThickness = new Thickness(1), BorderBrush = Brushes.Gray, Margin = new Thickness(0, 0, 8, 0) };
        void ShowPaper()
        {
            swatch.Background = AppSettings.Current.PaperColor is { } color
                ? (Brush)new BrushConverter().ConvertFromString(color)!
                : Brushes.Transparent;
        }
        ShowPaper();
        var choose = new Button { Content = NativeCore.Tr("doc.paperChoose"), Padding = new Thickness(10, 2, 10, 2), Margin = new Thickness(0, 0, 8, 0) };
        choose.Click += (_, _) =>
        {
            using var dialog = new Forms.ColorDialog { FullOpen = true };
            if (AppSettings.Current.PaperColor is { } color)
                dialog.Color = System.Drawing.ColorTranslator.FromHtml(color);
            if (dialog.ShowDialog() != Forms.DialogResult.OK) return;
            var chosen = $"#{dialog.Color.R:X2}{dialog.Color.G:X2}{dialog.Color.B:X2}";
            AppSettings.Update(current => current.PaperColor = chosen);
            ShowPaper();
        };
        var reset = new Button { Content = NativeCore.Tr("paper.resetColor"), Padding = new Thickness(10, 2, 10, 2) };
        reset.Click += (_, _) =>
        {
            AppSettings.Update(current => current.PaperColor = null);
            ShowPaper();
        };
        var paper = new StackPanel { Orientation = Orientation.Horizontal };
        paper.Children.Add(swatch);
        paper.Children.Add(choose);
        paper.Children.Add(reset);
        AddRow(form, NativeCore.Tr("paper.title"), paper);

        AddRow(form, NativeCore.Tr("reader.fontSize"), Stepper(settings.BodySize, AppSettings.MinBodySize, AppSettings.MaxBodySize, "pt",
            value => AppSettings.Update(current => current.BodySize = value)));
        AddRow(form, NativeCore.Tr("reader.letterSpacing"), Stepper(settings.LetterSpacing, AppSettings.MinLetterSpacing, AppSettings.MaxLetterSpacing, "%",
            value => AppSettings.Update(current => current.LetterSpacing = value)));
        return form;
    }

    /// <summary>Reads what the author typed. Anything but a number leaves the value as it was.</summary>
    public static double ParseStep(string text, double current, double minimum, double maximum) =>
        double.TryParse(text.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var value) && double.IsFinite(value)
            ? Math.Clamp(value, minimum, maximum)
            : current;

    static UIElement Stepper(double initial, double minimum, double maximum, string unit, Action<double> changed)
    {
        var value = initial;
        var box = new TextBox { Width = 64, TextAlignment = TextAlignment.Center, VerticalContentAlignment = VerticalAlignment.Center };
        void Show() => box.Text = value.ToString("0.##", CultureInfo.InvariantCulture);
        void Set(double next)
        {
            next = Math.Clamp(next, minimum, maximum);
            var different = next != value;
            value = next;
            Show();
            if (different) changed(value);
        }
        Show();
        box.LostFocus += (_, _) => Set(ParseStep(box.Text, value, minimum, maximum));
        box.KeyDown += (_, e) =>
        {
            if (e.Key == System.Windows.Input.Key.Enter) Set(ParseStep(box.Text, value, minimum, maximum));
        };
        var less = new Button { Content = "−", Width = 30, Margin = new Thickness(0, 0, 4, 0) };
        less.Click += (_, _) => Set(value - 1);
        var more = new Button { Content = "+", Width = 30, Margin = new Thickness(4, 0, 6, 0) };
        more.Click += (_, _) => Set(value + 1);
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        panel.Children.Add(less);
        panel.Children.Add(box);
        panel.Children.Add(more);
        panel.Children.Add(new TextBlock { Text = unit, VerticalAlignment = VerticalAlignment.Center });
        return panel;
    }
}
