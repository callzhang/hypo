using System.IO;
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
        FillFilters();
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

    /// <summary>
    /// Fills the two filter drop-downs.
    ///
    /// <para>Once, from the enums, so a filter added to the model appears here
    /// without anyone remembering to add it.</para>
    /// </summary>
    private void FillFilters()
    {
        TypeFilterBox.ItemsSource = new[]
        {
            new FilterChoice<TypeFilter>(TypeFilter.All, "All types"),
            new FilterChoice<TypeFilter>(TypeFilter.Text, "Text"),
            new FilterChoice<TypeFilter>(TypeFilter.Link, "Links"),
            new FilterChoice<TypeFilter>(TypeFilter.Image, "Images"),
            new FilterChoice<TypeFilter>(TypeFilter.File, "Files"),
        };
        TypeFilterBox.DisplayMemberPath = nameof(FilterChoice<TypeFilter>.Label);
        TypeFilterBox.SelectedIndex = 0;

        DateFilterBox.ItemsSource = new[]
        {
            new FilterChoice<DateFilter>(DateFilter.All, "Any time"),
            new FilterChoice<DateFilter>(DateFilter.Today, "Today"),
            new FilterChoice<DateFilter>(DateFilter.ThisWeek, "This week"),
        };
        DateFilterBox.DisplayMemberPath = nameof(FilterChoice<DateFilter>.Label);
        DateFilterBox.SelectedIndex = 0;
    }

    /// <summary>One entry in a filter drop-down.</summary>
    public sealed record FilterChoice<T>(T Value, string Label);

    private void OnTypeFilterChanged(object sender, SelectionChangedEventArgs e)
    {
        if (TypeFilterBox.SelectedItem is FilterChoice<TypeFilter> choice)
        {
            _model.SetType(choice.Value);
            Bind();
        }
    }

    private void OnDateFilterChanged(object sender, SelectionChangedEventArgs e)
    {
        if (DateFilterBox.SelectedItem is FilterChoice<DateFilter> choice)
        {
            _model.SetAge(choice.Value);
            Bind();
        }
    }

    /// <summary>
    /// Pins the selected row, or unpins it.
    ///
    /// <para>One item rather than two, reading as what it will do: a menu with
    /// both Pin and Unpin on it makes the reader work out which applies.</para>
    /// </summary>
    private void OnTogglePin(object sender, RoutedEventArgs e)
    {
        if (Rows.SelectedItem is not HistoryRow row)
        {
            return;
        }

        _model.SetPinned(row, !row.Pinned);
        Bind();
    }

    private void Bind()
    {
        Rows.ItemsSource = _model.Rows;
        Hint.Visibility = _model.IsEmpty ? Visibility.Visible : Visibility.Collapsed;
        FilterHint.Visibility = FilterBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;

        // The empty message has to say which emptiness this is. "Copy something"
        // is wrong advice for a list that is empty because of a filter.
        Hint.Text = _model.Rows.Count == 0 && _model.HasNarrowedList
            ? "Nothing matches. Try a different filter."
            : "Nothing here yet. Copy something.";

        PinItem.Header = Rows.SelectedItem is HistoryRow { Pinned: true }
            ? "Unpin"
            : "Pin to the top";
    }

    private void OnFilterChanged(object sender, TextChangedEventArgs e)
    {
        _model.SetFilter(FilterBox.Text);
        Bind();
    }

    private System.Windows.Point _dragFrom;

    private void OnRowMouseDown(object sender, MouseButtonEventArgs e) =>
        _dragFrom = e.GetPosition(this);

    /// <summary>
    /// Starts a drag once the pointer has moved far enough to mean it.
    ///
    /// <para>The threshold is Windows' own. Below it every click on a row would
    /// begin a drag, and selecting an entry would become a fight.</para>
    /// </summary>
    private void OnRowMouseMove(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (e.LeftButton is not MouseButtonState.Pressed || Rows.SelectedItem is not HistoryRow row)
        {
            return;
        }

        var moved = e.GetPosition(this) - _dragFrom;
        if (Math.Abs(moved.X) < SystemParameters.MinimumHorizontalDragDistance
            && Math.Abs(moved.Y) < SystemParameters.MinimumVerticalDragDistance)
        {
            return;
        }

        DragOut(row);
    }

    /// <summary>
    /// Hands the entry to whatever it is dropped on.
    ///
    /// <para>Dragging puts a history entry into another application without
    /// disturbing the clipboard, which matters when what is on the clipboard now
    /// is the thing you want to keep.</para>
    /// </summary>
    private void DragOut(HistoryRow row)
    {
        DragContent payload;

        try
        {
            payload = DragContent.For(row.Content, DragContent.DefaultTemporaryDirectory);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // A file that could not be written has nothing to drag. Failing
            // silently is right here: the alternative is a message box in the
            // middle of a mouse gesture.
            return;
        }

        if (!payload.HasAnything)
        {
            return;
        }

        var data = new System.Windows.DataObject();

        if (payload.Text is { } text)
        {
            data.SetData(System.Windows.DataFormats.UnicodeText, text);
        }

        if (payload.Png is { } png)
        {
            data.SetData("PNG", new MemoryStream(png));
        }

        if (payload.Files is { Count: > 0 } files)
        {
            data.SetData(System.Windows.DataFormats.FileDrop, files.ToArray());
        }

        // Copy, never Move: the entry stays in the history. A drag that emptied
        // the list would be a surprising way to lose something.
        System.Windows.DragDrop.DoDragDrop(Rows, data, System.Windows.DragDropEffects.Copy);
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
