using System.Text.Json;
using System.Windows;
using System.Windows.Controls;

namespace JenaNote;

/// <summary>Words the author allows: names and terms that proofreading should leave alone.</summary>
sealed class DictionaryWindow : Window
{
    /// <summary>Raised after the dictionary changes, so open documents can check again.</summary>
    public static event Action? Changed;

    static DictionaryWindow? open;

    readonly string? documentPath;
    readonly ListBox list = new() { SelectionMode = SelectionMode.Extended };
    readonly TextBox termBox = new() { MinWidth = 220, Margin = new Thickness(0, 0, 6, 0) };
    readonly ComboBox scopeBox = new() { Margin = new Thickness(0, 0, 6, 0) };

    sealed record Row(string Id, string Label)
    {
        public override string ToString() => Label;
    }

    public static void Present(Window owner, string? documentPath, string term)
    {
        if (open != null)
        {
            open.termBox.Text = term;
            open.Activate();
            return;
        }
        open = new DictionaryWindow(documentPath, term) { Owner = owner };
        open.Closed += (_, _) => open = null;
        open.Show();
    }

    DictionaryWindow(string? documentPath, string term)
    {
        this.documentPath = documentPath;
        Title = NativeCore.Tr("dictionary.title").TrimEnd('…', '.');
        Width = 520;
        Height = 480;
        MinWidth = 420;
        MinHeight = 320;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        var layout = new DockPanel { Margin = new Thickness(14) };

        var purpose = new TextBlock
        {
            Text = NativeCore.Tr("dictionary.purpose"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 10),
        };
        DockPanel.SetDock(purpose, Dock.Top);
        layout.Children.Add(purpose);

        var addRow = new DockPanel { Margin = new Thickness(0, 0, 0, 10) };
        var addButton = new Button { Content = NativeCore.Tr("dictionary.registerAction"), Padding = new Thickness(12, 2, 12, 2), IsDefault = true };
        addButton.Click += (_, _) => Add();
        DockPanel.SetDock(addButton, Dock.Right);
        DockPanel.SetDock(scopeBox, Dock.Right);
        addRow.Children.Add(addButton);
        addRow.Children.Add(scopeBox);
        addRow.Children.Add(termBox);
        DockPanel.SetDock(addRow, Dock.Top);
        layout.Children.Add(addRow);

        var removeButton = new Button
        {
            Content = NativeCore.Tr("dictionary.deleteSelected"),
            Padding = new Thickness(12, 2, 12, 2),
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 10, 0, 0),
        };
        removeButton.Click += (_, _) => Remove();
        DockPanel.SetDock(removeButton, Dock.Bottom);
        layout.Children.Add(removeButton);

        layout.Children.Add(list);
        Content = layout;

        termBox.Text = term;
        Reload();
        Loaded += (_, _) => termBox.Focus();
    }

    void Reload()
    {
        try
        {
            using var document = JsonDocument.Parse(NativeCore.DictionaryList(documentPath));
            var root = document.RootElement;

            var currentWork = root.GetProperty("currentWork").ValueKind == JsonValueKind.String
                ? root.GetProperty("currentWork").GetString()
                : null;
            scopeBox.Items.Clear();
            if (currentWork != null) scopeBox.Items.Add(currentWork);
            scopeBox.Items.Add(NativeCore.Tr("dictionary.allShort"));
            scopeBox.SelectedIndex = 0;

            list.Items.Clear();
            foreach (var entry in root.GetProperty("entries").EnumerateArray())
            {
                var scope = entry.GetProperty("allWorks").GetBoolean()
                    ? NativeCore.Tr("dictionary.allShort")
                    : string.Join(", ", entry.GetProperty("works").EnumerateArray().Select(work => work.GetString()));
                var suffix = entry.GetProperty("enabled").GetBoolean() ? "" : $" ({NativeCore.Tr("dictionary.off")})";
                list.Items.Add(new Row(entry.GetProperty("id").GetString()!, $"{entry.GetProperty("term").GetString()}  ·  {scope}{suffix}"));
            }
        }
        catch (InvalidOperationException error)
        {
            Show(error.Message);
        }
    }

    void Add()
    {
        var term = termBox.Text;
        if (string.IsNullOrWhiteSpace(term)) return;
        var useCurrentWork = scopeBox.Items.Count > 1 && scopeBox.SelectedIndex == 0;
        try
        {
            NativeCore.DictionaryAdd(term, documentPath, useCurrentWork);
        }
        catch (InvalidOperationException error)
        {
            Show(error.Message);
            return;
        }
        termBox.Clear();
        Reload();
        Changed?.Invoke();
    }

    void Remove()
    {
        var ids = list.SelectedItems.Cast<Row>().Select(row => row.Id).ToList();
        if (ids.Count == 0) return;
        try
        {
            NativeCore.DictionaryRemove(ids);
        }
        catch (InvalidOperationException error)
        {
            Show(error.Message);
            return;
        }
        Reload();
        Changed?.Invoke();
    }

    void Show(string message) =>
        MessageBox.Show(this, message, "Jena Note", MessageBoxButton.OK, MessageBoxImage.Warning);
}
