using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Windows.Media;

namespace JenaNote;

/// <summary>Saved versions of one document: read them, compare with the current text, restore.</summary>
sealed class HistoryWindow : Window
{
    sealed record Version(string Id, string Label)
    {
        public override string ToString() => Label;
    }

    /// <summary>One aligned line of the comparison. Bound from the XAML template below.</summary>
    public sealed record Row(string Left, string Right, Brush LeftBackground, Brush RightBackground);

    static readonly Brush Plain = Brushes.Transparent;
    static readonly Brush Added = Tint(0x2E, 0xA0, 0x43);
    static readonly Brush Removed = Tint(0xD9, 0x30, 0x25);
    static readonly Brush Modified = Tint(0xE8, 0x86, 0x0C);

    const string RowTemplate = """
        <DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*" SharedSizeGroup="" />
              <ColumnDefinition Width="*" />
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="{Binding Left}" Background="{Binding LeftBackground}" TextWrapping="Wrap" Padding="4,1" />
            <TextBlock Grid.Column="1" Text="{Binding Right}" Background="{Binding RightBackground}" TextWrapping="Wrap" Padding="4,1" />
          </Grid>
        </DataTemplate>
        """;

    readonly EditorWindow document;
    readonly string path;
    readonly ListBox versions = new();
    readonly CheckBox compare = new() { Content = NativeCore.Tr("history.compare"), IsChecked = true, Margin = new Thickness(0, 0, 0, 6) };
    readonly ItemsControl rows = new();
    readonly TextBlock message = new() { TextWrapping = TextWrapping.Wrap };
    readonly Button restore = new() { Content = NativeCore.Tr("backup.restore"), Padding = new Thickness(12, 2, 12, 2), Margin = new Thickness(6, 0, 0, 0), IsEnabled = false };
    readonly TextBox versionName = new() { MinWidth = 200, Margin = new Thickness(0, 0, 6, 0) };

    static SolidColorBrush Tint(byte red, byte green, byte blue)
    {
        var brush = new SolidColorBrush(Color.FromArgb(0x40, red, green, blue));
        brush.Freeze();
        return brush;
    }

    public HistoryWindow(EditorWindow document, string path)
    {
        this.document = document;
        this.path = path;
        Title = $"{NativeCore.Tr("backup.title").TrimEnd('…', '.')} · {Path.GetFileName(path)}";
        Width = 980;
        Height = 640;
        MinWidth = 640;
        MinHeight = 380;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Owner = document;

        var layout = new DockPanel { Margin = new Thickness(14) };

        var hint = new TextBlock { Text = NativeCore.Tr("doc.backupHint"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 10) };
        DockPanel.SetDock(hint, Dock.Top);
        layout.Children.Add(hint);

        var actions = new DockPanel { Margin = new Thickness(0, 10, 0, 0), LastChildFill = false };
        var create = new Button { Content = NativeCore.Tr("history.create"), Padding = new Thickness(12, 2, 12, 2) };
        create.Click += async (_, _) => await CreateVersionAsync();
        var refresh = new Button { Content = NativeCore.Tr("history.refresh"), Padding = new Thickness(12, 2, 12, 2), Margin = new Thickness(6, 0, 0, 0) };
        refresh.Click += (_, _) => Reload();
        restore.Click += async (_, _) => await RestoreAsync();
        var nameLabel = new TextBlock { Text = NativeCore.Tr("history.name"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 6, 0) };
        foreach (UIElement item in new UIElement[] { nameLabel, versionName, create })
        {
            DockPanel.SetDock(item, Dock.Left);
            actions.Children.Add(item);
        }
        DockPanel.SetDock(restore, Dock.Right);
        DockPanel.SetDock(refresh, Dock.Right);
        actions.Children.Add(restore);
        actions.Children.Add(refresh);
        DockPanel.SetDock(actions, Dock.Bottom);
        layout.Children.Add(actions);

        var body = new Grid();
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(240) });
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        versions.Margin = new Thickness(0, 0, 10, 0);
        versions.SelectionChanged += async (_, _) => await ShowSelectionAsync();
        Grid.SetColumn(versions, 0);
        body.Children.Add(versions);

        var detail = new DockPanel();
        compare.Click += async (_, _) => await ShowSelectionAsync();
        DockPanel.SetDock(compare, Dock.Top);
        detail.Children.Add(compare);
        DockPanel.SetDock(message, Dock.Top);
        detail.Children.Add(message);

        rows.ItemTemplate = (DataTemplate)XamlReader.Parse(RowTemplate);
        rows.ItemsPanel = new ItemsPanelTemplate(new FrameworkElementFactory(typeof(VirtualizingStackPanel)));
        rows.FontFamily = new FontFamily("Malgun Gothic");
        rows.Template = (ControlTemplate)XamlReader.Parse("""
            <ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="ItemsControl">
              <ScrollViewer CanContentScroll="True" HorizontalScrollBarVisibility="Disabled" VerticalScrollBarVisibility="Auto">
                <ItemsPresenter />
              </ScrollViewer>
            </ControlTemplate>
            """);
        VirtualizingPanel.SetIsVirtualizing(rows, true);
        detail.Children.Add(rows);
        Grid.SetColumn(detail, 1);
        body.Children.Add(detail);
        layout.Children.Add(body);

        Content = layout;
        Reload();
    }

    void Reload()
    {
        var selected = (versions.SelectedItem as Version)?.Id;
        versions.Items.Clear();
        try
        {
            using var list = JsonDocument.Parse(NativeCore.BackupList(path));
            foreach (var item in list.RootElement.EnumerateArray())
            {
                var date = DateTimeOffset.FromUnixTimeMilliseconds((long)(item.GetProperty("createdAt").GetDouble() * 1000)).LocalDateTime.ToString("g");
                var name = item.TryGetProperty("name", out var value) && value.ValueKind == JsonValueKind.String ? $"{value.GetString()}  ·  " : "";
                versions.Items.Add(new Version(item.GetProperty("id").GetString()!, name + date));
            }
        }
        catch (InvalidOperationException error)
        {
            message.Text = error.Message;
            return;
        }
        message.Text = versions.Items.Count == 0 ? NativeCore.Tr("backup.empty") : "";
        versions.SelectedItem = versions.Items.Cast<Version>().FirstOrDefault(item => item.Id == selected)
            ?? versions.Items.Cast<Version>().FirstOrDefault();
    }

    async Task ShowSelectionAsync()
    {
        restore.IsEnabled = versions.SelectedItem != null;
        rows.ItemsSource = null;
        if (versions.SelectedItem is not Version version) return;
        string previous;
        try
        {
            previous = NativeCore.BackupText(path, version.Id);
        }
        catch (InvalidOperationException error)
        {
            restore.IsEnabled = false;
            message.Text = error.Message;
            return;
        }

        if (compare.IsChecked != true)
        {
            message.Text = "";
            rows.ItemsSource = previous.Split('\n').Select(line => new Row(line, "", Plain, Plain)).ToList();
            return;
        }

        var current = await document.CurrentTextAsync();
        if (!ReferenceEquals(versions.SelectedItem, version)) return;
        if (previous == current)
        {
            message.Text = NativeCore.Tr("history.identical");
            return;
        }
        using var parsed = JsonDocument.Parse(NativeCore.HistoryRows(previous, current));
        if (parsed.RootElement.ValueKind != JsonValueKind.Array)
        {
            message.Text = NativeCore.Tr("history.tooLarge");
            return;
        }
        message.Text = $"{NativeCore.Tr("history.previousVersion")}  |  {NativeCore.Tr("history.currentVersion")}";
        rows.ItemsSource = parsed.RootElement.EnumerateArray().Select(item =>
        {
            var kind = item.GetProperty("kind").GetString();
            var left = item.TryGetProperty("previous", out var a) && a.ValueKind == JsonValueKind.String ? a.GetString()! : "";
            var right = item.TryGetProperty("current", out var b) && b.ValueKind == JsonValueKind.String ? b.GetString()! : "";
            return kind switch
            {
                "added" => new Row(left, right, Plain, Added),
                "removed" => new Row(left, right, Removed, Plain),
                "modified" => new Row(left, right, Modified, Modified),
                _ => new Row(left, right, Plain, Plain),
            };
        }).ToList();
    }

    async Task CreateVersionAsync()
    {
        var name = versionName.Text.Trim();
        if (name.Length == 0)
        {
            versionName.Focus();
            return;
        }
        try
        {
            await document.CreateNamedVersionAsync(name.Length > 120 ? name[..120] : name);
            versionName.Clear();
            Reload();
        }
        catch (InvalidOperationException error)
        {
            MessageBox.Show(this, error.Message, "Jena Note", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    async Task RestoreAsync()
    {
        if (versions.SelectedItem is not Version version) return;
        var answer = MessageBox.Show(this, $"{NativeCore.Tr("backup.confirm")}\n\n{NativeCore.Tr("backup.confirmHint")}", "Jena Note",
            MessageBoxButton.OKCancel, MessageBoxImage.Question);
        if (answer != MessageBoxResult.OK) return;
        try
        {
            await document.RestoreVersionAsync(version.Id);
            Close();
        }
        catch (InvalidOperationException error)
        {
            MessageBox.Show(this, error.Message, "Jena Note", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }
}
