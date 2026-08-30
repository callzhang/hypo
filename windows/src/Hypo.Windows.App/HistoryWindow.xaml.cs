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

    public HistoryWindow(HistoryViewModel model)
    {
        _model = model;
        InitializeComponent();
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
            // Closing is the point: the user picked something to paste, and
            // leaving the window over their work makes them dismiss it every time.
            Hide();
        }
        catch (Exception ex)
        {
            System.Windows.MessageBox.Show(
                $"Could not put that on the clipboard.\n\n{ex.Message}",
                "Hypo", System.Windows.MessageBoxButton.OK, System.Windows.MessageBoxImage.Warning);
        }
    }
}
