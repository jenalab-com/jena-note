using System.Globalization;
using System.IO;
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
        Width = 600;
        Height = 500;
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
        // The default style gives each tab a wide minimum, and three of them would need two rows.
        tabs.Items.Add(new TabItem { Header = NativeCore.Tr("settings.tab.general"), Content = BuildGeneral(), MinWidth = 72 });
        tabs.Items.Add(new TabItem { Header = NativeCore.Tr("settings.tab.ui"), Content = BuildAppearance(), MinWidth = 72 });
        tabs.Items.Add(new TabItem { Header = "AI", MinWidth = 72, Content = new ScrollViewer { Content = BuildAi(), VerticalScrollBarVisibility = ScrollBarVisibility.Auto } });
        Content = tabs;
    }

    public void ShowAi()
    {
        if (Content is TabControl tabs) tabs.SelectedIndex = tabs.Items.Count - 1;
    }

    CancellationTokenSource? aiCheck;

    UIElement BuildAi()
    {
        var form = NewForm();
        using var providers = JsonDocument.Parse(NativeCore.AiProviders());
        var list = providers.RootElement.EnumerateArray().Select(item => (
            Id: item.GetProperty("id").GetString()!,
            Title: item.GetProperty("title").GetString()!,
            Docs: item.GetProperty("documentation").GetString()!)).ToList();

        var path = new TextBox { MinWidth = 260, ToolTip = NativeCore.Tr("ai.pathPlaceholder") };
        var status = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0) };
        var detail = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 11, Opacity = 0.7, Margin = new Thickness(0, 8, 0, 0) };
        var install = new Button { Content = NativeCore.Tr("ai.install"), Padding = new Thickness(10, 2, 10, 2) };
        var login = new Button { Content = NativeCore.Tr("ai.login"), Padding = new Thickness(10, 2, 10, 2), Margin = new Thickness(6, 0, 0, 0) };
        var check = new Button { Content = NativeCore.Tr("ai.recheck"), Padding = new Thickness(10, 2, 10, 2), Margin = new Thickness(6, 0, 0, 0) };
        var docs = new Button { Content = NativeCore.Tr("ai.instructions"), Padding = new Thickness(10, 2, 10, 2), Margin = new Thickness(6, 0, 0, 0) };

        string Current() => AppSettings.Current.AiProvider;

        void ShowState()
        {
            var executable = AiExecutable.Locate(Current());
            var verified = executable != null && AiService.IsVerified(Current(), executable);
            status.Text = executable == null
                ? NativeCore.Tr("ai.notInstalled")
                : NativeCore.Tr(verified ? "ai.connected" : "ai.installed") + "\n" + executable;
            install.IsEnabled = executable == null && AiService.InstallCommand(Current()) != null;
            login.Content = NativeCore.Tr(verified ? "ai.loggedIn" : "ai.login");
            login.IsEnabled = executable != null && !verified;
            detail.Text = NativeCore.Tr("ai.setupHelp")
                + (Current() == "grok" ? "\n" + NativeCore.Tr("ai.grokProfile") : "")
                + (AiService.InstallCommand(Current()) == null ? "\n" + NativeCore.Tr("doc.aiNoInstaller") : "");
        }

        void Reset()
        {
            aiCheck?.Cancel();
            check.IsEnabled = true;
        }

        void SavePath()
        {
            var value = path.Text.Trim();
            if (AppSettings.Current.AiPaths.GetValueOrDefault(Current(), "") == value) return;
            Reset();
            AppSettings.Update(current => current.AiPaths[current.AiProvider] = value);
            ShowState();
        }

        void Fill()
        {
            path.Text = AppSettings.Current.AiPaths.GetValueOrDefault(Current(), "");
            ShowState();
        }

        AddRow(form, NativeCore.Tr("ai.settings"), Choice(list.Select(item => (item.Id, item.Title)), Current(), value =>
        {
            Reset();
            AppSettings.Update(current => current.AiProvider = value);
            Fill();
        }));

        path.LostFocus += (_, _) => SavePath();
        var browse = new Button { Content = NativeCore.Tr("ai.browse"), Padding = new Thickness(10, 2, 10, 2), Margin = new Thickness(6, 0, 0, 0) };
        browse.Click += (_, _) =>
        {
            var dialog = new Microsoft.Win32.OpenFileDialog { Filter = "CLI (*.exe;*.cmd;*.bat)|*.exe;*.cmd;*.bat" };
            if (dialog.ShowDialog(this) != true) return;
            path.Text = dialog.FileName;
            SavePath();
        };
        var pathRow = new DockPanel();
        DockPanel.SetDock(browse, Dock.Right);
        pathRow.Children.Add(browse);
        pathRow.Children.Add(path);
        AddRow(form, NativeCore.Tr("ai.path"), pathRow);

        void OpenTerminal(bool installing, string opened)
        {
            SavePath();
            try
            {
                AiService.OpenTerminal(Current(), installing);
                status.Text = NativeCore.Tr(opened);
            }
            catch (Exception error) when (error is AiFailure or IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
            {
                status.Text = error.Message;
            }
        }
        install.Click += (_, _) => OpenTerminal(true, "ai.installOpened");
        login.Click += (_, _) => OpenTerminal(false, "ai.loginOpened");
        docs.Click += (_, _) =>
        {
            var address = list.First(item => item.Id == Current()).Docs;
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(address) { UseShellExecute = true });
        };
        check.Click += async (_, _) =>
        {
            SavePath();
            Reset();
            var cancel = aiCheck = new CancellationTokenSource();
            status.Text = NativeCore.Tr("ai.checking");
            check.IsEnabled = false;
            login.IsEnabled = false;
            try
            {
                var (_, message) = await AiService.CheckAsync(Current(), cancel.Token);
                if (cancel.IsCancellationRequested) return;
                ShowState();
                status.Text = message;
            }
            catch (Exception error) when (error is AiFailure or AiFailureWithTokens or IOException or UnauthorizedAccessException or InvalidOperationException)
            {
                if (cancel.IsCancellationRequested) return;
                ShowState();
                status.Text = error.Message.Length > 2000 ? error.Message[..2000] : error.Message;
            }
            check.IsEnabled = true;
        };
        Closed += (_, _) => aiCheck?.Cancel();

        var actions = new StackPanel { Orientation = Orientation.Horizontal };
        actions.Children.Add(install);
        actions.Children.Add(login);
        actions.Children.Add(check);
        actions.Children.Add(docs);
        AddRow(form, null, actions);
        AddRow(form, null, status);
        AddRow(form, null, detail);
        Fill();
        return form;
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
