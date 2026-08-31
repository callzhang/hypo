using System.Windows;
using System.Windows.Controls;
using Hypo.Windows.App;

namespace Hypo.Windows.App.Shell;

/// <summary>
/// Shows <see cref="HistoryViewModel"/>. Every decision it displays -- previews,
/// filtering, what happens when an entry is chosen -- belongs to the view model
/// and is tested there.
/// </summary>
public partial class HistoryWindow : Window
{
    private readonly HistoryViewModel _model;

    /// <summary>
    /// Raised after an entry has been put on the clipboard and this window has
    /// hidden itself, so whoever showed it can hand focus back.
    /// </summary>
    public event EventHandler? EntryUsed;

    public HistoryWindow(HistoryViewModel model)
    {
        _model = model;
        InitializeComponent();

        // The dark title bar and the Mica backdrop go through
        // DwmSetWindowAttribute, which needs a handle -- which this window does
        // not have until it is shown.
        SourceInitialized += (_, _) => ThemeHost.Register(this);
        Bind();
    }

    private void Bind()
    {
        Rows.ItemsSource = _model.Rows;
        Hint.Visibility = _model.IsEmpty ? Visibility.Visible : Visibility.Collapsed;
        FilterHint.Visibility = FilterBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnFilterChanged(object sender, TextChangedEventArgs e)
    {
        _model.SetFilter(FilterBox.Text);
        Bind();
    }

    private async void OnUseSelected(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (Rows.SelectedItem is not HistoryRow row)
        {
            return;
        }

        try
        {
            await _model.UseAsync(row);

            // Hidden, then focus goes back to wherever they were. Without the
            // second half the feature is inert: the point of a clipboard history
            // is the paste immediately after choosing something.
            Hide();
            EntryUsed?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception ex)
        {
            System.Windows.MessageBox.Show(
                $"Could not put that on the clipboard.\n\n{ex.Message}",
                "Hypo", System.Windows.MessageBoxButton.OK, System.Windows.MessageBoxImage.Warning);
        }
    }
}
