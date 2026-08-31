using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
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
        SourceInitialized += (_, _) =>
        {
            ThemeHost.Register(this);
            KeepOutOfAltTab();
        };

        Deactivated += (_, _) => HideIfAllowed();
        Bind();
    }

    /// <summary>
    /// Puts the caret in the search box with whatever is there selected.
    ///
    /// <para>Called every time the window is shown, not once when it is built:
    /// this window is hidden and shown again rather than recreated, and someone
    /// who opens it expects to start typing, not to find last time's search
    /// still in the way.</para>
    /// </summary>
    public void ReadyToType()
    {
        FilterBox.Focus();
        FilterBox.SelectAll();
    }

    /// <summary>
    /// Whether clicking away closes the window.
    ///
    /// <para>True for the shortcut, which is the way most people will open this:
    /// a floating list that stays behind whatever you switch to is litter. Tests
    /// that want to look at the window after opening another one turn it
    /// off.</para>
    /// </summary>
    public bool HideWhenDeactivated { get; set; } = true;

    private void HideIfAllowed()
    {
        if (HideWhenDeactivated && IsVisible)
        {
            Hide();
        }
    }

    /// <summary>
    /// Keeps the window out of Alt+Tab.
    ///
    /// <para>It is a popup that a keystroke summons, not a place to switch to,
    /// and a clipboard history sitting in the Alt+Tab order is one more thing
    /// between someone and the window they actually want.</para>
    /// </summary>
    private void KeepOutOfAltTab()
    {
        const int GwlExStyle = -20;
        const int WsExToolWindow = 0x00000080;

        var handle = new WindowInteropHelper(this).Handle;
        if (handle == 0)
        {
            return;
        }

        var style = GetWindowLongPtrW(handle, GwlExStyle);
        SetWindowLongPtrW(handle, GwlExStyle, style | WsExToolWindow);
    }

    /// <summary>
    /// Escape closes it, and Enter takes the selected entry.
    ///
    /// <para>Without these the shortcut is half a feature: it opens the window
    /// and then asks for the mouse, which is slower than the thing it replaced.</para>
    /// </summary>
    private async void OnWindowKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key is Key.Escape)
        {
            e.Handled = true;
            Hide();
            EntryUsed?.Invoke(this, EventArgs.Empty);
            return;
        }

        if (e.Key is Key.Enter)
        {
            e.Handled = true;
            await UseSelectedAsync();
        }
    }

    /// <summary>
    /// Moves the selection from inside the search box.
    ///
    /// <para>The box has focus the moment the window opens, so without this the
    /// arrow keys move the caret and there is no way to reach the second entry
    /// without the mouse.</para>
    /// </summary>
    private void OnFilterKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key is not (Key.Down or Key.Up) || Rows.Items.Count == 0)
        {
            return;
        }

        e.Handled = true;

        var next = Rows.SelectedIndex + (e.Key is Key.Down ? 1 : -1);
        Rows.SelectedIndex = Math.Clamp(next, 0, Rows.Items.Count - 1);
        Rows.ScrollIntoView(Rows.SelectedItem);
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

    private async void OnUseSelected(object sender, MouseButtonEventArgs e) =>
        await UseSelectedAsync();

    private async Task UseSelectedAsync()
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

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW", SetLastError = true)]
    private static extern nint GetWindowLongPtrW(nint hwnd, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
    private static extern nint SetWindowLongPtrW(nint hwnd, int index, nint value);
}
